#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @'
module waveform_demo(input logic clk, input logic [1:0] d);
    logic [1:0] q;
    logic __q3a_diagnostic;
    assign __q3a_diagnostic = d[0];
    always_ff @(posedge clk) begin q <= d; end
    c_hit: cover property (@(posedge clk) (d === 2'bxz) |=> ((q === 2'bxz) && (d === 2'bzx)));
    c_miss: cover property (@(posedge clk) 1'b0);
    p_fail: assert property (@(posedge clk) (d === 2'bxz) |=> (q !== 2'bxz));
endmodule
'@
$rtl | Set-Content -LiteralPath "$root/dut.sv" -Encoding utf8NoBOM
$project = "$root/dut.q3a"
@('Q3AFORMAL_PROJECT 2','top waveform_demo','source systemverilog "dut.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath $project -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Captured($Name, [int]$Code, [string[]]$Arguments) {
    $raw = @(& $exe @Arguments 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    if ($actual -ne $Code) { throw "$Name expected $Code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)" }
    $raw
}
function Run-Property($Name, $Command, $Property, $ExpectedStatus, [int]$Code, $Evidence, $Vcd) {
    $raw = Invoke-Captured $Name $Code @($Command,$project,'--property',$Property,
        '--evidence-dir',$Evidence,'--steps','1','--vcd',$Vcd)
    $value = $raw | ConvertFrom-Json
    if ($value.status -cne $ExpectedStatus -or $value.exit_code -ne $Code) {
        throw "$Name returned the wrong status. $raw"
    }
    $value
}
function Check-Imported($Name, $Vcd, $Result, $Marker) {
    $import = (Invoke-Captured "import-$Name" 0 @('trace','import-vcd',$Vcd)) | ConvertFrom-Json
    if (!$import.four_state -or $import.formal_evidence -or $import.provenance -cne 'external-non-formal' -or
        $import.timescale -cne '1ns' -or $import.samples.Count -ne $Result.trace.Count -or
        $Result.vcd_sha256 -cne (Hash $Vcd)) {
        throw 'Imported provenance, timebase, sample count or VCD digest is incorrect.'
    }
    for ($index = 0; $index -lt $Result.trace.Count; ++$index) {
        $sample = $import.samples[$index]
        if ($sample.timestamp -cne [string]$index) { throw 'A sample index changed in VCD.' }
        $values = @{}
        foreach ($change in $sample.changes) { $values[[int]$change[0]] = [string]$change[1] }
        foreach ($signal in $import.signals) {
            if ($signal.scope[0] -cne 'waveform_demo') { throw 'VCD lost the design hierarchy.' }
            if ($signal.type -ceq 'event') {
                $expected = '1'
                if ($signal.name -cne 'clk' -or $signal.scope[1] -cne '__q3a_sampling') {
                    throw 'The abstract sampling clock is not represented as an event.'
                }
            } elseif ($signal.scope.Count -eq 2) {
                $marks = @{
                    attempt_sample = $Result.attempt_sample
                    antecedent_end_sample = $Result.antecedent_end_sample
                    match_sample = $Result.match_sample
                    failure_sample = $Result.failure_sample
                }
                if ($signal.scope[1] -cne '__q3a_diagnostic_1' -or !$marks.ContainsKey($signal.name) -or
                    $null -eq $marks[$signal.name]) { throw 'A diagnostic marker is unexpected or collided with an RTL name.' }
                $expected = if ($marks[$signal.name] -eq $index) { '1' } else { '0' }
            } else {
                $expected = $Result.trace[$index].($signal.name)
                if ($signal.name -in @('d','q') -and ($signal.width -ne 2 -or $signal.range -cne '[1:0]')) {
                    throw 'A declared packed width or index range was lost.'
                }
            }
            if ($values[[int]$signal.id] -cne $expected) { throw "Wrong $($signal.name) at sample $index." }
        }
    }
    if (@($import.signals | Where-Object name -CEQ $Marker).Count -ne 1 -or $import.signals.Count -ne 7) {
        throw 'An expected RTL signal, sampling event or diagnostic marker is absent.'
    }
    $import
}

$witness = "$root/cover-witness"
$firstVcd = "$root/cover.vcd"
$secondVcd = "$root/cover-reopened.vcd"
$covered = Run-Property cover dev-prove-four-state c_hit COVERED 0 $witness $firstVcd
$reopened = Run-Property reopen dev-verify-four-state c_hit COVERED 0 $witness $secondVcd
$import = Check-Imported cover $firstVcd $covered match_sample
$null = Check-Imported reopen $secondVcd $reopened match_sample
if (!$reopened.witness_revalidated -or $covered.vcd_sha256 -cne $reopened.vcd_sha256 -or
    $covered.trace[0].d -cne 'xz' -or $covered.trace[1].d -cne 'zx' -or
    $covered.trace[0].q -cne 'xx' -or $covered.trace[1].q -cne 'xz') {
    throw 'The deterministic four-state witness was not regenerated byte for byte.'
}

$failedVcd = "$root/failure.vcd"
$failed = Run-Property fail dev-prove-four-state p_fail COUNTEREXAMPLE 0 "$root/no-counterexample-artifact" $failedVcd
$null = Check-Imported fail $failedVcd $failed failure_sample
$missVcd = "$root/miss.vcd"
$miss = Run-Property miss dev-prove-four-state c_miss NOT_FOUND_WITHIN_BOUND 1 "$root/miss-proof" $missVcd
if ($miss.vcd_sha256 -or (Test-Path -LiteralPath $missVcd)) { throw 'A cover miss unexpectedly published a waveform.' }

$html = Invoke-Captured view 0 @('trace','view-vcd',$secondVcd)
$html | Set-Content -LiteralPath "$root/waveform.html" -Encoding utf8NoBOM
if (($html -join '') -notmatch '<title>External VCD waveform</title>' -or
    ($html -join '') -notmatch '"xz"' -or ($html -join '') -notmatch '"zx"') {
    throw 'The waveform viewer did not receive the four-state values.'
}
$null = Invoke-Captured strict-roundtrip 2 @('trace','import-vcd',$secondVcd,'--q3a-roundtrip')
$used = Hash $firstVcd
$sourceBefore = Hash "$root/dut.sv"
$null = Run-Property occupied dev-verify-four-state c_hit REJECTED 2 $witness $firstVcd
$null = Run-Property protected-source dev-verify-four-state c_hit REJECTED 2 $witness "$root/dut.sv"
$null = Run-Property alias dev-prove-four-state c_hit REJECTED 2 "$root/ARCHIVE" "$root/archive"
if ((Hash $firstVcd) -cne $used -or (Hash "$root/dut.sv") -cne $sourceBefore -or (Test-Path "$root/archive")) {
    throw 'A rejected VCD path changed existing inputs or published new evidence.'
}

[ordered]@{
    status = 'FOUR_STATE_WAVEFORM_QUALIFIED'
    executable_sha256 = Hash $exe
    cover_vcd_sha256 = $covered.vcd_sha256
    reopened_vcd_sha256 = $reopened.vcd_sha256
    counterexample_vcd_sha256 = $failed.vcd_sha256
    viewer_html_sha256 = Hash "$root/waveform.html"
    value_checks = 3 * $import.signals.Count * $import.samples.Count
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: three four-state waveform round trips, sampled diagnostic markers, offline viewer, and protected outputs.'
