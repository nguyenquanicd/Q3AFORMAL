#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DevelopmentExecutable,
    [Parameter(Mandatory)][string]$ReleasedExecutable,
    [Parameter(Mandatory)][string]$CheckerExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$dev = (Resolve-Path -LiteralPath $DevelopmentExecutable).ProviderPath
$release = (Resolve-Path -LiteralPath $ReleasedExecutable).ProviderPath
$checker = (Resolve-Path -LiteralPath $CheckerExecutable).ProviderPath
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$source = Join-Path $root 'source fixtures'
New-Item -ItemType Directory -Path $source | Out-Null
$rtl = @(
    'module mem #(parameter BASE = 0) (input logic clk, re, we, '
    '    input logic [1:0] ra, wa, din, output logic [1:0] dout);'
    '    logic [1:0] words [3:BASE];'
    '    always_ff @(posedge clk) begin'
    '        if (re) dout <= words[ra];'
    '        if (we) words[wa] <= din;'
    '    end'
    ('    ' + [char]96 + 'include "properties.svh"')
    'endmodule'
)
$checks = @(
    'property hold_output;'
    '    @(posedge clk) (!re) |=> (dout == $past(dout));'
    'endproperty'
    'p_hold: assert property (hold_output);'
    'p_false: assert property (@(posedge clk) re |=> (dout == $past(dout)));'
)
Set-Content -LiteralPath "$source/memory.sv" -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/properties.svh" -Value $checks -Encoding utf8NoBOM
$manifest = @('Q3AFORMAL_PROJECT 2', 'top mem', 'source systemverilog "memory.sv"', 'parameter BASE 0')
Set-Content -LiteralPath "$source/normal.q3a" -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/offset.q3a" -Value ($manifest -replace 'BASE 0', 'BASE 1') -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/manifest-edited.q3a" -Value ($manifest -replace '^top mem$', 'top  mem') -Encoding utf8NoBOM

function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
$identity = [ordered]@{development = Hash $dev; released = Hash $release; checker = Hash $checker}
$devVersion = & $dev --version | ConvertFrom-Json
$releasedVersion = & $release --version | ConvertFrom-Json
if ($devVersion.build_id -eq $releasedVersion.build_id -or $devVersion.build_configuration -cnotmatch 'Q3A_ENABLE_DEVELOPMENT_MEMORY' -or
    $releasedVersion.build_configuration -cmatch 'Q3A_ENABLE_DEVELOPMENT_MEMORY' -or
    -not ((& $dev --help) -cmatch 'dev-prove-memory') -or ((& $release --help) -cmatch 'dev-prove-memory')) {
    throw 'Development build isolation differs.'
}

$cases = [Collections.Generic.List[object]]::new()
function Test-Run([string]$Name, [string]$Program, [int]$Exit, [string]$Status, [string[]]$CommandArguments) {
    $stderr = Join-Path $root "$Name.stderr.txt"
    $stdout = @(& $Program @CommandArguments 2> $stderr)
    $code = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    if ($code -ne $Exit) { throw "$Name exited $code, expected $Exit. $stdout $(Get-Content $stderr -Raw)" }
    $record = if ($Status) { $stdout | ConvertFrom-Json }
    if ($Status -and ($record.status -cne $Status -or $record.exit_code -ne $code)) {
        throw "$Name did not report $Status. $stdout"
    }
    $cases.Add([ordered]@{name = $Name; exit = $code; status = $record.status})
    return $record
}

$evidence = Join-Path $root 'proof group'
$prove = @('dev-prove-memory', "$source/normal.q3a", '--property', 'p_hold', '--output-dir', $evidence, '--max-cells', '4')
$verify = @('dev-verify-memory', "$source/normal.q3a", '--property', 'p_hold', '--evidence-dir', $evidence, '--max-cells', '4')
$proved = Test-Run prove $dev 0 PROVEN $prove
$verified = Test-Run reopen $dev 0 REVALIDATED $verify
if ($proved.model_input_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $proved.model_input_sha256 -cne $verified.model_input_sha256 -or
    $proved.manifest_sha256 -cne (Hash "$source/normal.q3a") -or $verified.profile -cne 'Q3A-EXACT-MEMORY-DEVELOPMENT') {
    throw 'Source and manifest provenance differs.'
}

Test-Run released-command $release 2 '' $prove | Out-Null
Test-Run standard-proof $dev 2 SETUP_ERROR @('prove', "$source/normal.q3a", '--property', 'p_hold', '--evidence-dir', "$root/standard") | Out-Null
Test-Run replay-wrong-property $dev 2 REJECTED ($verify -replace '^p_hold$', 'p_false') | Out-Null
Test-Run replay-edited-manifest $dev 2 REJECTED ($verify -replace 'normal\.q3a$', 'manifest-edited.q3a') | Out-Null
Test-Run prove-existing-directory $dev 2 REJECTED $prove | Out-Null
Test-Run reopen-preserved $dev 0 REVALIDATED $verify | Out-Null

$offset = Test-Run invalid-read $dev 1 RANGE_UNPROVED @('dev-prove-memory', "$source/offset.q3a", '--property', 'p_hold',
    '--output-dir', "$root/rejected-offset", '--max-cells', '3')
if ($offset.property -cne '__q3a_read_in_range' -or (Test-Path -LiteralPath "$root/rejected-offset")) {
    throw 'Invalid read did not block evidence publication.'
}
$negative = Test-Run false-property $dev 1 PROPERTY_UNPROVED @('dev-prove-memory', "$source/normal.q3a", '--property', 'p_false',
    '--output-dir', "$root/rejected-property", '--max-cells', '4')
if ($negative.property -cne 'p_false' -or (Test-Path -LiteralPath "$root/rejected-property")) {
    throw 'Unproved primary assertion did not block evidence publication.'
}
Test-Run too-small $dev 2 REJECTED ($prove -replace '^4$', '3') | Out-Null
Test-Run duplicate-option $dev 2 REJECTED ($prove + @('--max-depth','5','--max-depth','5')) | Out-Null
$signal = Join-Path $root 'cancel.signal'
Set-Content -LiteralPath $signal -Value 'stop'
Test-Run cancelled $dev 1 CANCELLED ($prove + @('--cancel-file', $signal)) | Out-Null

$guard = Join-Path $evidence 'read-range/safety.cnf'
$guardBackup = Join-Path $evidence 'read-range/safety.original'
Move-Item -LiteralPath $guard -Destination $guardBackup
try { Test-Run missing-range $dev 2 REJECTED $verify | Out-Null }
finally { Move-Item -LiteralPath $guardBackup -Destination $guard }

$header = Join-Path $source 'properties.svh'
$original = [IO.File]::ReadAllBytes($header)
try {
    Add-Content -LiteralPath $header -Value '// Different included source bytes.'
    Test-Run changed-include $dev 2 REJECTED $verify | Out-Null
} finally { [IO.File]::WriteAllBytes($header, $original) }
Test-Run replay-restored $dev 0 REVALIDATED $verify | Out-Null

$obligations = @(foreach ($group in 'read-range', 'write-range', 'property') {
    $directory = Join-Path $evidence $group
    $model = (Get-Content -LiteralPath "$directory/invariant.txt" -TotalCount 2)[1]
    foreach ($kind in 'initiation', 'consecution', 'safety') {
        $proof = Join-Path $directory "$kind.q3adrat"
        $cnf = Join-Path $directory "$kind.cnf"
        $result = @(& $checker --check-drat $cnf $proof --model-sha256 $model --query-kind "pdr-$kind")
        if ($LASTEXITCODE -ne 0 -or $result -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
            throw "Independent proof check failed for $group/$kind."
        }
        [ordered]@{group = $group; kind = "pdr-$kind"; cnf_sha256 = Hash $cnf; proof_sha256 = Hash $proof}
    }
})
if ($obligations.Count -ne 9 -or (Hash $dev) -cne $identity.development -or
    (Hash $release) -cne $identity.released -or (Hash $checker) -cne $identity.checker) {
    throw 'Executable or proof roster changed.'
}
[ordered]@{
    status = 'PASS'
    development_build_id = $devVersion.build_id
    released_build_id = $releasedVersion.build_id
    executables = $identity
    source_files = @{manifest = Hash "$source/normal.q3a"; rtl = Hash "$source/memory.sv"; include = Hash $header}
    cases = @($cases)
    standalone_obligations = $obligations
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: $($cases.Count) development and release CLI checks, nine standalone proof obligations."
