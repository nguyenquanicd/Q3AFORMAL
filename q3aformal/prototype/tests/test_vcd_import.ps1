param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-vcd-' + [Guid]::NewGuid()))).FullName
$stderr = Join-Path $root 'stderr.txt'
$vcd = Join-Path $root 'trace.vcd'
$bundle = Join-Path $root 'bundle'

function Import-Wave($File, [switch]$Roundtrip, $ExpectedError) {
    $options = @(if ($Roundtrip) { '--q3a-roundtrip' })
    $stdout = & $exe trace import-vcd $File @options 2> $stderr
    $status = $LASTEXITCODE
    if ($ExpectedError) {
        if ($status -ne 2 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch $ExpectedError) {
            throw "Expected input error matching '$ExpectedError'. Got $status. $(Get-Content $stderr -Raw)"
        }
    } else {
        if ($status -ne 0) { throw "Import returned $status. $(Get-Content $stderr -Raw)" }
        return $stdout | ConvertFrom-Json
    }
}

try {
    $manifest = Join-Path $prototype 'bmc-state-failure.q3a'
    $output = & $exe --bmc $manifest --property p_q_tracks_a --frames 1 --vcd $vcd --bundle-dir $bundle
    if ($LASTEXITCODE -ne 0 -or $output -cnotcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Could not generate a validated trace. $output"
    }
    $trace = Import-Wave $vcd -Roundtrip
    $segment = 'trace ' + ('x' * 110)
    $longRoot = (New-Item -ItemType Directory -Path (Join-Path $root "$segment/$segment") -Force).FullName
    $longVcd = Join-Path $longRoot 'trace.vcd'
    $longIndex = Join-Path $longRoot 'trace.q3atrace'
    Copy-Item -LiteralPath $vcd -Destination $longVcd
    Copy-Item -LiteralPath (Join-Path $bundle 'properties/p_q_tracks_a/trace.q3atrace') -Destination $longIndex
    if ($longVcd.Length -lt 260 -or $longIndex.Length -lt 260) { throw 'Expected long Windows paths.' }
    $longTrace = Import-Wave $longVcd -Roundtrip
    if (($longTrace | ConvertTo-Json -Depth 10 -Compress) -cne ($trace | ConvertTo-Json -Depth 10 -Compress)) {
        throw 'Long-path VCD import changed the waveform.'
    }
    $view = @(& $exe trace view-vcd $longVcd 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or ($view -join [char]10) -notmatch 'Q3A-VCD-IMPORT-1') {
        throw 'Could not open the long-path VCD viewer.'
    }
    $window = & $exe trace window $longIndex --first 0 --last 1 --signal q 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $window.property -cne 'p_q_tracks_a' -or $window.signals[0].name -cne 'q' -or
        $window.frame_count -ne 2) { throw 'Could not open the long-path indexed witness.' }
    $native = Get-Content (Join-Path $bundle 'properties/p_q_tracks_a/trace.json') -Raw | ConvertFrom-Json -AsHashtable
    $model = Get-Content (Join-Path $bundle 'model/model.json') -Raw | ConvertFrom-Json
    $widths = @{}
    foreach ($signal in $model.signals) { $widths[$signal.name] = $signal.width }
    if ($trace.schema -cne 'Q3A-VCD-IMPORT-1' -or $trace.provenance -cne 'q3a-roundtrip' -or
        $trace.timescale -cne '1ns' -or $trace.formal_evidence -or $trace.four_state -or
        $trace.samples.Count -ne $native.frames.Count -or $trace.signals.Count -ne $widths.Count + 1) {
        throw 'Unexpected round-trip metadata.'
    }
    $values = @{}
    foreach ($sample in $trace.samples) {
        $nativeFrame = $native.frames[[int]$sample.timestamp]
        if ([int]$sample.timestamp -ne $nativeFrame.index) { throw 'Frame timestamps changed.' }
        $events = 0
        foreach ($change in $sample.changes) {
            $signal = $trace.signals[$change[0]]
            if ($signal.type -ceq 'event') {
                if (($signal.scope -join '.') -cne "$($model.top_module).__q3a_sampling" -or
                    $signal.name -cne 'clk' -or $signal.width -ne 1 -or $change[1] -cne '1') {
                    throw 'Unexpected sampling event.'
                }
                $events++
                continue
            }
            if (($signal.scope -join '.') -cne $model.top_module) {
                throw "Top-level scope mismatch: $($signal.scope)"
            }
            if ($signal.width -ne $widths[$signal.name] -or $change[1].Length -ne $signal.width) {
                throw "Width mismatch for $($signal.name)."
            }
            $values[$signal.name] = '0x' + [Convert]::ToUInt64($change[1], 2).ToString('x')
        }
        if ($events -ne 1) { throw 'Expected one sampling event at every frame.' }
        foreach ($signal in ($trace.signals | Where-Object type -CNE 'event')) {
            if ($values[$signal.name] -cne $nativeFrame.signals[$signal.name]) {
                throw "Value mismatch at $($sample.timestamp) for $($signal.name)."
            }
        }
    }

    $nestedManifest = Join-Path $root 'nested.q3a'
    $nestedVcd = Join-Path $root 'nested.vcd'
    @'
Q3AFORMAL_PROJECT 1
top trace_top
source "nested.sv"
'@ | Set-Content -LiteralPath $nestedManifest
    @'
module trace_leaf(input logic [3:0] a, output logic [3:0] y);
    logic [0:3] local_data;
    assign local_data = a;
    assign y = local_data;
endmodule
module trace_top(input logic clk, input logic [3:0] a, output logic [3:0] y);
    trace_leaf __q3a_sampling(.a(a), .y(y));
    p_bad: assert property (@(posedge clk) y != a);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'nested.sv')
    $output = & $exe --bmc $nestedManifest --property p_bad --frames 0 --vcd $nestedVcd
    if ($LASTEXITCODE -ne 0 -or $output -cnotcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Could not generate a validated hierarchical trace.'
    }
    $nested = Import-Wave $nestedVcd -Roundtrip
    $local = @($nested.signals | Where-Object name -CEQ 'local_data')
    if ($local.Count -ne 1 -or ($local[0].scope -join '.') -cne 'trace_top.__q3a_sampling' -or
        $local[0].width -ne 4 -or $local[0].range -cne '[0:3]') {
        throw 'Export/import lost the nested scope or declared packed range.'
    }
    $nestedClock = @($nested.signals | Where-Object type -CEQ 'event')
    if ($nestedClock.Count -ne 1 -or ($nestedClock[0].scope -join '.') -cne 'trace_top.__q3a_sampling_1') {
        throw 'Sampling events collided with a design scope.'
    }

    $external = Join-Path $root 'external.vcd'
    $fixture = @'
$timescale 10 ps $end
$scope module top $end
$scope module child $end
$var reg 4 ! data [0:3] $end
$var wire 1 " valid $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
bX1 !
z"
$end
#9007199254740993
b10 !
1"
'@
    $fixture | Set-Content -LiteralPath $external
    $parsed = Import-Wave $external
    if ($parsed.provenance -cne 'external-non-formal' -or $parsed.formal_evidence -or !$parsed.four_state -or
        $parsed.timescale -cne '10ps' -or ($parsed.signals[0].scope -join '.') -cne 'top.child' -or
        $parsed.signals[0].range -cne '[0:3]' -or $parsed.signals[0].width -ne 4 -or
        $parsed.samples[0].changes[0][1] -cne 'xxx1' -or $parsed.samples[0].changes[1][1] -cne 'z' -or
        $parsed.samples[1].timestamp -cne '9007199254740993' -or $parsed.samples[1].changes[0][1] -cne '0010') {
        throw 'External hierarchy, widths, four-state values, or exact timestamp were lost.'
    }
    $aliasedFixture = $fixture.Replace('$var wire 1 " valid $end',
        '$var wire 1 " valid $end' + [Environment]::NewLine +
        '$var wire 4 ! data_alias [3:0] $end')
    $aliasedFixture | Set-Content -LiteralPath $external
    $aliased = Import-Wave $external
    if ($aliased.signals.Count -ne 3 -or $aliased.signals[2].name -cne 'data_alias' -or
        $aliased.signals[2].range -cne '[3:0]' -or $aliased.formal_evidence -or
        $aliased.provenance -cne 'external-non-formal') {
        throw 'External alias did not retain its own display identity.'
    }
    foreach ($sample in $aliased.samples) {
        $value = @($sample.changes | Where-Object { $_[0] -eq 0 })
        $aliasValue = @($sample.changes | Where-Object { $_[0] -eq 2 })
        if ($value.Count -ne 1 -or $aliasValue.Count -ne 1 -or $value[0][1] -cne $aliasValue[0][1]) {
            throw 'Aliased change did not reach every declaration.'
        }
    }
    $fixture.Replace('$var wire 1 " valid $end', '$var wire 1 ! valid $end') |
        Set-Content -LiteralPath $external
    Import-Wave $external -ExpectedError 'incompatible alias width or event type'
    $fixture.Replace('$var wire 1 " valid $end', '$var event 1 " event_bit $end' +
        [Environment]::NewLine + '$var wire 1 " valid $end') | Set-Content -LiteralPath $external
    Import-Wave $external -ExpectedError 'incompatible alias width or event type'
    $fixture.Replace('$var wire 1 " valid $end', '$var wire 1 " valid $end' +
        [Environment]::NewLine + '$var wire 1 @ valid $end') | Set-Content -LiteralPath $external
    Import-Wave $external -ExpectedError 'duplicate signal declaration'
    $fixture.Replace('[0:3]', '[0:4]') | Set-Content -LiteralPath $external
    Import-Wave $external -ExpectedError 'invalid signal range'
    $fixture.Replace('b10 !', 'b10 @') | Set-Content -LiteralPath $external
    Import-Wave $external -ExpectedError 'unknown signal identifier'
    $fixture | Set-Content -LiteralPath $external
    Import-Wave $external -Roundtrip -ExpectedError 'exporter signature'

    $original = Get-Content -LiteralPath $vcd -Raw
    $clockDeclaration = [regex]::Match($original, '(?m)^\$var wire 1 (\S+) (\S+) \$end\r?$')
    if (!$clockDeclaration.Success) { throw 'Expected a scalar declaration in the round-trip trace.' }
    $duplicate = '$var wire 1 ' + $clockDeclaration.Groups[1].Value + ' alias_for_roundtrip_test $end'
    $original.Insert($clockDeclaration.Index, $duplicate + [Environment]::NewLine) |
        Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'duplicate identifier or alias in Q3A round-trip'
    ($original -replace '(?m)^[01](v\d+)', 'x$1') | Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'X/Z'
    $original.Replace('#1', '#2') | Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'contiguous sample indices'
    ($original -replace '(?m)^#0\r?\n', '') | Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'explicit timestamp'
    ($original -replace '1e1\r?\n\z', '') | Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'sampling event is missing'
    ($original -replace '(?m)^1e1$', '0e1') | Set-Content -LiteralPath $vcd
    Import-Wave $vcd -Roundtrip -ExpectedError 'occurrence value'
    $legacyPath = Join-Path (Split-Path -Parent $prototype) 'evidence/benchmark/runs/phase1-prove-cli-regression-2026-11-24/B-02-counter4-fail-artifacts/trace.vcd'
    $legacy = Import-Wave $legacyPath -Roundtrip
    if ($legacy.samples.Count -ne 2 -or @($legacy.signals | Where-Object type -CEQ 'event').Count) {
        throw 'Historical VCD should reopen with its original samples and signals.'
    }
    'PASS: VCD round-trip including sampled clock values, per-frame events, historical VCD, hierarchy, four-state fidelity, compatible external aliases, and twelve rejected cases.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), (Split-Path $root -Leaf))
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
