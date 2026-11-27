
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$CheckSavedTraces
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @(
    'module range_fixture(input logic clk, re, we, data,'
    '    input logic [1:0] ra, wa, output logic q);'
    '    logic words [1:3];'
    '    always_ff @(posedge clk) begin'
    '        if (re) q <= words[ra];'
    '        if (we) words[wa] <= data;'
    '    end'
    '    p_ok: assert property (@(posedge clk) 1''b1);'
    '    p_other: assert property (@(posedge clk) 1''b1);'
)
$read = @{property='__q3a_read_in_range'; address='ra'; line=5}
$write = @{property='__q3a_write_in_range'; address='wa'; line=6}
$cases = @(
    @{name='read'; expected=@($read); pending=$false;
      assumptions=@('a_write: assume property (@(posedge clk) !we || (wa != 2''d0));')},
    @{name='write'; expected=@($write); pending=$false;
      assumptions=@('a_read: assume property (@(posedge clk) !re || (ra != 2''d0));')},
    @{name='both'; expected=@($read,$write); pending=$false;
      assumptions=@('a_both: assume property (@(posedge clk) re && we && (ra == 2''d0) && (wa == 2''d0));')},
    @{name='pending'; expected=@($read); pending=$true;
      assumptions=@('a_write: assume property (@(posedge clk) !we || (wa != 2''d0));',
                    'a_future: assume property (@(posedge clk) re |=> re);')}
)
function Run-Memory([string]$Name, [string[]]$Arguments, [int]$Exit, [string]$Status) {
    $raw = @(& $exe @Arguments 2> "$root/$Name.stderr.txt")
    $result = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    $record = $raw | ConvertFrom-Json
    if ($result -ne $Exit -or $record.exit_code -ne $Exit -or $record.status -cne $Status) {
        throw "$Name did not report $Status. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $record
}
$reports = @(foreach ($case in $cases) {
    $name = $case.name
    Set-Content -LiteralPath "$root/$name.sv" -Value ($rtl + $case.assumptions + 'endmodule') -Encoding utf8NoBOM
    $project = "$root/$name.q3a"
    Set-Content -LiteralPath $project -Value @('Q3AFORMAL_PROJECT 2','top range_fixture',"source systemverilog ""$name.sv""") -Encoding utf8NoBOM
    $evidence = "$root/$name-evidence"
    $command = @('dev-prove-memory',$project,'--property','p_ok','--output-dir',$evidence,'--max-cells','3')
    $traceFile = "$root/$name.q3t"
    $mode = if ($CheckSavedTraces) { @('--range-trace',$traceFile) } else { @('--diagnose-range') }
    $record = Run-Memory $name ($command + $mode + @('--timeout-ms','5000')) 1 RANGE_UNPROVED
    $witness = $record.range_witness
    if (!$witness -or $witness.frame -ne 0 -or $witness.boundary_incomplete -ne $case.pending -or
        $witness.accesses.Count -ne $case.expected.Count -or (Test-Path -LiteralPath $evidence)) {
        throw "$name produced an invalid diagnostic or published proof evidence."
    }
    for ($index = 0; $index -lt $case.expected.Count; ++$index) {
        $wanted = $case.expected[$index]
        $actual = $witness.accesses[$index]
        if ($actual.property -cne $wanted.property -or $actual.address_signal -cne $wanted.address -or
            $actual.line -ne $wanted.line -or $actual.column -le 0 -or $actual.file -cne "$name.sv" -or
            $actual.address -isnot [string] -or $actual.address -cne '0' -or $actual.first -cne '1' -or $actual.last -cne '3') {
            throw "Unexpected location, access or bounds for $name. $($actual | ConvertTo-Json -Compress)"
        }
    }
    $traceResult = $null
    if ($CheckSavedTraces) {
        if (!$record.range_trace_saved -or !(Test-Path -LiteralPath $traceFile -PathType Leaf)) {
            throw "$name failed to save its trace."
        }
        $status = if ($case.pending) { 'RANGE_WITNESS_PENDING_ASSUMPTION' } else { 'RANGE_WITNESS_REVALIDATED' }
        $exitCode = if ($case.pending) { 1 } else { 0 }
        $traceResult = Run-Memory "$name-replay" @('dev-verify-memory-range',$project,'--property','p_ok',
            '--trace',$traceFile,'--max-cells','3') $exitCode $status
        if (($traceResult.range_witness | ConvertTo-Json -Compress -Depth 5) -cne
            ($witness | ConvertTo-Json -Compress -Depth 5)) {
            throw "$name returned different source coordinates or values at reopen."
        }
    }
    [ordered]@{case=$name; result=$record; reopened=$traceResult}
})
$project = "$root/read.q3a"
$unused = "$root/unused"
$normal = @('dev-prove-memory',$project,'--property','p_ok','--output-dir',$unused,'--max-cells','3')
$legacy = Run-Memory legacy $normal 1 RANGE_UNPROVED
if ($legacy.PSObject.Properties.Name -ccontains 'range_witness') { throw 'Diagnosis changed the default result.' }
$null = Run-Memory duplicate ($normal + @('--diagnose-range','--diagnose-range')) 2 REJECTED
$null = Run-Memory wrong-mode @('dev-verify-memory',$project,'--property','p_ok','--evidence-dir',$unused,
    '--max-cells','3','--diagnose-range') 2 REJECTED
if (Test-Path -LiteralPath $unused) { throw 'A rejected command published evidence.' }
if ($CheckSavedTraces) {
    $traceFile = "$root/read.q3t"
    $verify = @('dev-verify-memory-range',$project,'--property','p_ok','--trace',$traceFile,'--max-cells','3')
    $traceHash = (Get-FileHash -LiteralPath $traceFile).Hash
    $null = Run-Memory trace-existing ($normal + @('--range-trace',$traceFile)) 2 REJECTED
    if ((Get-FileHash -LiteralPath $traceFile).Hash -cne $traceHash) { throw 'Existing trace was overwritten.' }
    $null = Run-Memory changed-property ($verify -creplace '^p_ok$', 'p_other') 2 REJECTED

    $sourcePath = "$root/read.sv"
    $originalSource = [IO.File]::ReadAllBytes($sourcePath)
    try {
        Add-Content -LiteralPath $sourcePath -Value '// source identity changed'
        $null = Run-Memory changed-source $verify 2 REJECTED
    } finally { [IO.File]::WriteAllBytes($sourcePath,$originalSource) }

    $bytes = [IO.File]::ReadAllBytes($traceFile)
    $truncated = "$root/truncated.q3t"
    [IO.File]::WriteAllBytes($truncated, $bytes[0..($bytes.Length - 2)])
    $null = Run-Memory truncated ($verify -creplace 'read\.q3t$', 'truncated.q3t') 2 REJECTED
    $null = Run-Memory restored $verify 0 RANGE_WITNESS_REVALIDATED
}
[ordered]@{
    status = 'SOURCE_RANGE_WITNESS_DIAGNOSTICS_QUALIFIED'
    indexed_trace_reopen = [bool]$CheckSavedTraces
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    access_diagnostics = $reports
    default_and_option_checks = 3
    proof_evidence_published = $false
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: replayed read, write, simultaneous and provisional memory-range diagnostics with source locations.'

