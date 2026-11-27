#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = Join-Path $root 'project.q3a'
$source = Join-Path $root 'trace_agreement.sv'
@('Q3AFORMAL_PROJECT 2','top trace_agreement','source systemverilog "trace_agreement.sv"') |
    Set-Content -LiteralPath $project -Encoding utf8
@'
module leaf(input logic clk, input logic rst, output logic [63:0] q);
    logic [0:63] ascending;
    always_ff @(posedge clk) begin
        if (rst) ascending <= 64'hfedcba9876543210;
    end
    assign q = ascending;
endmodule
module trace_agreement(input logic clk, input logic rst, output logic [63:0] q);
    leaf u_leaf(.clk(clk), .rst(rst), .q(q));
    env_reset: assume property (@(posedge clk) rst);
    p_fail: assert property (@(posedge clk) rst |=> q != 64'hfedcba9876543210);
    c_reset: cover property (@(posedge clk) rst ##1 q == 64'hfedcba9876543210);
endmodule
'@ | Set-Content -LiteralPath $source -Encoding utf8

function Run-Q3A([string]$Name,[int]$Code,[string[]]$CommandArguments) {
    $stdout = @(& $exe @CommandArguments 2> (Join-Path $root "$Name.stderr.txt"))
    if ($LASTEXITCODE -ne $Code) { throw "Unexpected exit code for $Name. $stdout $(Get-Content -LiteralPath (Join-Path $root "$Name.stderr.txt") -Raw)" }
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Name.stdout.txt") -Encoding utf8
    return $stdout -join [char]10
}
function Read-NativeFrames($Window) {
    $frames = @(@{},@{})
    foreach ($signal in $Window.signals) {
        $previous = 0
        $value = $null
        foreach ($change in $signal.changes) {
            if ($null -ne $value) {
                for ($i = $previous; $i -lt [int]$change[0]; ++$i) { $frames[$i][$signal.name] = $value }
            }
            $previous = [int]$change[0]
            $value = $change[1]
        }
        for ($i = $previous; $i -le 1; ++$i) { $frames[$i][$signal.name] = $value }
    }
    return ,$frames
}
function Assert-Agreement($Expected,$Actual,[string]$Label) {
    if ($Expected.Count -ne $Actual.Count -or ($Expected.Keys | Where-Object {
        !$Actual.Contains($_) -or $Expected[$_] -cne $Actual[$_]
    })) { throw "Trace signal values differ in $Label." }
}

$cases = @(
    @{id='bmc'; engine='bmc'; property='p_fail'; status='BOUNDED_FAIL'}
    @{id='pdr'; engine='pdr'; property='p_fail'; status='FAIL'}
    @{id='induction'; engine='induction'; property='p_fail'; status='FAIL'}
    @{id='cover'; engine='pdr'; property='c_reset'; status='COVERED'}
)
$results = foreach ($case in $cases) {
    $id = $case.id
    $bundle = Join-Path $root "$id-bundle"
    $vcd = Join-Path $root "$id.vcd"
    $options = @('prove',$project,'--engine',$case.engine,'--property',$case.property)
    switch ($case.engine) {
        bmc { $options += @('--frames','1','--vcd',$vcd) }
        pdr { $options += @('--max-depth','4','--evidence-dir',(Join-Path $root "$id-no-proof")) }
        induction { $options += @('--k','1','--output-prefix',(Join-Path $root "$id-proof")) }
    }
    $options += @('--bundle-dir',$bundle,'--trace-all')
    $proof = Run-Q3A "$id-prove" 0 $options | ConvertFrom-Json
    if ($proof.status -cne $case.status) { throw "Unexpected outcome for $id." }
    $verify = Run-Q3A "$id-reopen" 0 @('--verify-bundle',$bundle,'--require-source-model')
    if ($verify -notmatch '(?m)^Q3A_BUNDLE_SOURCE_MODEL VERIFIED$' -or
        $verify -notmatch '(?m)^Q3A_BUNDLE_STATUS REVALIDATED$') { throw "Source revalidation failed for $id." }
    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
    $index = @($manifest.artifacts | Where-Object role -cin 'indexed_witness_trace','indexed_induction_witness')
    if ($index.Count -ne 1) { throw "$id did not archive exactly one native trace." }
    $window = Run-Q3A "$id-native" 0 @('trace','window',(Join-Path $bundle $index[0].path),'--first','0','--last','1') |
        ConvertFrom-Json
    $frames = Read-NativeFrames $window
    $ascending = $window.signals | Where-Object name -CEQ 'u_leaf.ascending'
    $candidate = if ($case.engine -ceq 'induction') {0} else {1}
    if ($window.property -cne $case.property -or $window.candidate_frame -ne $candidate -or $window.frame_count -ne 2 -or
        $ascending.width -ne 64 -or $frames[0].rst -cne '0x1' -or $frames[1].rst -cne '0x1' -or
        $frames[0]['u_leaf.ascending'] -cne $frames[0].q -or $frames[1].q -cne '0xfedcba9876543210' -or
        $frames[1]['u_leaf.ascending'] -cne $frames[1].q) {
        throw "Native trace for $id disagrees with independent reset and hierarchy semantics."
    }
    $legacyFrames = @(@{},@{})
    $comparison = 'stored trace JSON'
    if ($case.engine -ceq 'induction') {
        $text = $manifest.artifacts | Where-Object role -CEQ 'replay_validated_witness'
        $sample = -1
        foreach ($line in (Get-Content -LiteralPath (Join-Path $bundle $text.path))) {
            if ($line -match '^frame (\d+)$') { $sample = [int]$Matches[1] }
            if ($line -match '^signal (\S+) width=(\d+) value=(0x[0-9a-f]+)$') {
                $legacyFrames[$sample][$Matches[1]] = $Matches[3]
            }
        }
        $comparison = 'stored induction witness text'
    } else {
        $trace = Get-ChildItem -LiteralPath $bundle -Recurse -Filter trace.json
        $stored = Get-Content -LiteralPath $trace.FullName -Raw | ConvertFrom-Json -AsHashtable
        if (!$stored.validated -or $stored.candidate_frame -ne 1 -or $stored.frames.Count -ne 2) {
            throw "$id stored trace is missing replay metadata."
        }
        $legacyFrames = @($stored.frames[0].signals,$stored.frames[1].signals)
    }
    foreach ($sample in 0,1) { Assert-Agreement $frames[$sample] $legacyFrames[$sample] "$id sample $sample" }
    if ($id -ceq 'bmc') {
        if ($verify -notmatch '(?m)^Q3A_BUNDLE_VCD VERIFIED$') { throw 'The archived VCD was not checked.' }
        $wave = Run-Q3A bmc-vcd 0 @('trace','import-vcd',$vcd,'--q3a-roundtrip') | ConvertFrom-Json
        $range = $wave.signals | Where-Object name -CEQ 'ascending'
        if ($wave.samples.Count -ne 2 -or ($range.scope -join '.') -cne 'trace_agreement.u_leaf' -or
            $range.range -cne '[0:63]' -or $range.width -ne 64 -or $wave.four_state) {
            throw 'VCD round-trip lost its frame, hierarchy or ascending range metadata.'
        }
        $values = @{}
        foreach ($sample in $wave.samples) {
            $events = 0
            foreach ($change in $sample.changes) {
                $signal = $wave.signals[[int]$change[0]]
                if ($signal.type -ceq 'event') {
                    if ($change[1] -cne '1') { throw 'Invalid abstract clock event in VCD.' }
                    ++$events
                    continue
                }
                $scope = @($signal.scope | Select-Object -Skip 1)
                $name = ($scope + $signal.name) -join '.'
                if ($signal.width -ne $change[1].Length) { throw "VCD width mismatch for $name." }
                $values[$name] = '0x' + [Convert]::ToUInt64($change[1],2).ToString('x')
            }
            if ($events -ne 1) { throw 'Missing abstract clock pulse in VCD.' }
            Assert-Agreement $frames[[int]$sample.timestamp] $values "VCD sample $($sample.timestamp)"
        }
    }
    [ordered]@{engine=$case.engine;id=$id;status=$proof.status;candidate_frame=$candidate;decision_sample=1;
        signals_checked=$window.signals.Count;frames_checked=2;comparison=$comparison;vcd_roundtrip=($id -ceq 'bmc')}
}
$bmcBundle = Join-Path $root 'bmc-bundle'
$waveCases = @(
    @{id='value'; old='(?m)^b1111111011011100101110101001100001110110010101000011001000010000 (v\d+)$'; new=('b' + ('0' * 64) + ' $1'); error='differs from replay witness at sample 1'}
    @{id='range'; old='\[0:63\]'; new='[63:0]'; error='declaration differs from the witness capture'; header=$true}
    @{id='time'; old='(?m)^#1$'; new='#2'; error='requires contiguous sample indices'}
    @{id='event'; old='(?m)^1e1\n?'; new=''; error='sampling event is missing'}
)
$waveResults = foreach ($case in $waveCases) {
    $copy = Join-Path $root "wave-$($case.id)-bundle"
    Copy-Item -LiteralPath $bmcBundle -Destination $copy -Recurse
    $manifestPath = Join-Path $copy 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $waveEntry = $manifest.artifacts | Where-Object role -CEQ 'vcd_export'
    $file = Join-Path $copy $waveEntry.path
    $original = [IO.File]::ReadAllText($file)
    $start = if ($case.header) { 0 } else { $original.IndexOf('#1') }
    $mutated = [regex]::new($case.old).Replace($original, $case.new, 1, $start)
    if ($original -ceq $mutated) { throw "VCD mutation $($case.id) did not change the waveform." }
    [IO.File]::WriteAllText($file, $mutated)
    $waveEntry.size_bytes = (Get-Item -LiteralPath $file).Length
    $waveEntry.sha256 = (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    (Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath (Join-Path $copy 'manifest.sha256') -Encoding ascii
    $name = "wave-$($case.id)-reopen"
    $null = Run-Q3A $name 1 @('--verify-bundle',$copy,'--require-source-model')
    $diagnostic = Get-Content -LiteralPath (Join-Path $root "$name.stderr.txt") -Raw
    if ($diagnostic -cnotmatch [regex]::Escape($case.error)) { throw "Wrong rejection for $name. $diagnostic" }
    [ordered]@{mutation=$case.id;hashes_updated=$true;rejected=$true;diagnostic=$diagnostic.Trim()}
}

$legacyBundle = Join-Path (Split-Path -Parent $prototype) (
    'evidence/benchmark/runs/phase0-final-gate-b-2026-11-24/B-02-counter4-fail-artifacts/bundle')
$legacyVerify = Run-Q3A legacy-vcd-reopen 0 @('--verify-bundle',$legacyBundle)
if ($legacyVerify -notmatch '(?m)^Q3A_BUNDLE_VCD VERIFIED$') {
    throw 'The original Gate B VCD did not match its stored JSON witness.'
}

[ordered]@{
    schema='Q3AFORMAL_CROSS_ENGINE_WITNESS_AGREEMENT_1'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    cases=@($results)
    vcd_mismatch_checks=@($waveResults)
    phase0_gate_b_vcd_verified=$true
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: four source-backed witnesses, exact trace agreement, hierarchical VCD round-trip and four rehashed VCD rejections.'
