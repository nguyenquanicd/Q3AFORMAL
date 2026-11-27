
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DevelopmentExecutable,
    [Parameter(Mandatory)][string]$DefaultExecutable,
    [Parameter(Mandatory)][string]$CheckerExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$dev = (Resolve-Path -LiteralPath $DevelopmentExecutable).Path
$default = (Resolve-Path -LiteralPath $DefaultExecutable).Path
$checker = (Resolve-Path -LiteralPath $CheckerExecutable).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @'
module sampled(input logic clk, input logic [0:1] data);
    logic [0:1] prior, older;
    always_ff @(posedge clk) begin
        prior <= data;
        older <= prior;
    end
    p_stable: assert property (@(posedge clk) $stable(data) == (data == prior));
    p_changed: assert property (@(posedge clk) $changed(data) == (data != prior));
    p_rose: assert property (@(posedge clk) $rose(data) == (data[1] && !prior[1]));
    p_fell: assert property (@(posedge clk) $fell(data) == (!data[1] && prior[1]));
    p_nested: assert property (@(posedge clk) $stable($changed(data)) == ((data == prior) == (prior == older)));
    p_signed: assert property (@(posedge clk) $changed(2'sb10) == 1'b0);
    c_msb: cover property (@(posedge clk) $changed(data) && !$rose(data) && !$fell(data));
    c_startup: cover property (@(posedge clk) $stable(data));
    p_wrong: assert property (@(posedge clk) $changed(data) == $rose(data));
endmodule
'@
Set-Content -LiteralPath "$root/sampled.sv" -Value $rtl -Encoding utf8NoBOM
$baselineManifest = @('Q3AFORMAL_PROJECT 2', 'top sampled', 'source systemverilog "sampled.sv"')
$project = "$root/sampled.q3a"
$profile = 'Q3A-SAMPLED-VALUE-DEVELOPMENT'
Set-Content -LiteralPath $project -Value ($baselineManifest + "option profile $profile") -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/no-opt-in.q3a" -Value $baselineManifest -Encoding utf8NoBOM

function Invoke-Case([string]$Name, [string]$Program, [string[]]$Arguments) {
    $stdout = @(& $Program @Arguments 2> "$root/$Name.stderr.txt")
    $exitCode = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    [pscustomobject]@{ Exit = $exitCode; Text = $stdout -join [Environment]::NewLine }
}
function Require-Rejection([string]$Name, [string]$Program, [string[]]$Arguments, [string]$Diagnostic) {
    $case = Invoke-Case $Name $Program $Arguments
    $stderr = Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw
    if ($case.Exit -eq 0 -or "$($case.Text) $stderr" -cnotmatch $Diagnostic) {
        throw "$Name did not report the expected rejection. $($case.Text) $stderr"
    }
}
function Require-Result([string]$Name, [string[]]$Arguments, [string]$Expected) {
    $case = Invoke-Case $Name $dev $Arguments
    $value = $case.Text | ConvertFrom-Json
    if ($value.status -cne $Expected -or $value.exit_code -ne $case.Exit) {
        throw "$Name expected $Expected. $($case.Text) $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $value
}
function Require-Reopen([string]$Name, [string]$Bundle) {
    $case = Invoke-Case $Name $dev @('--verify-bundle', $Bundle, '--require-source-model')
    if ($case.Exit -ne 0 -or $case.Text -cnotmatch 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $case.Text -cnotmatch 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "$Name failed source revalidation. $($case.Text) $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
}

Require-Rejection default-profile $default @('--lower-project', $project) 'profile'
Require-Rejection no-opt-in $dev @('--lower-project', "$root/no-opt-in.q3a") 'unsupported system function'
foreach ($bad in @(
    @{ Name = 'wrong-context'; Expression = 'assign x = $rose(data);'; Diagnostic = 'unsupported system function' },
    @{ Name = 'alternate-clock'; Expression = 'p: assert property (@(posedge clk) $stable(data, @(posedge clk)));'; Diagnostic = 'alternate clocks' },
    @{ Name = 'empty'; Expression = 'p: assert property (@(posedge clk) $fell());'; Diagnostic = 'expected an expression operand' }
)) {
    $line = "module sampled(input logic clk, data, output logic x); $($bad.Expression) endmodule"
    Set-Content -LiteralPath "$root/$($bad.Name).sv" -Value $line -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$($bad.Name).q3a" -Value (
        ($baselineManifest -replace 'sampled\.sv', "$($bad.Name).sv") + "option profile $profile"
    ) -Encoding utf8NoBOM
    Require-Rejection $bad.Name $dev @('--lower-project', "$root/$($bad.Name).q3a") $bad.Diagnostic
}
$modelResult = Invoke-Case lowering $dev @('--lower-project', $project)
if ($modelResult.Exit -ne 0) { throw (Get-Content "$root/lowering.stderr.txt" -Raw) }
$model = $modelResult.Text | ConvertFrom-Json
$nested = $model.properties | Where-Object name -CEQ p_nested
$stable = $model.properties | Where-Object name -CEQ p_stable
if ($model.semantic_profile -cne $profile -or $nested.antecedent_history_guard_delay -ne 2 -or
    $stable.antecedent_history_guard_delay -ne 1 -or !$nested.antecedent_history_guard_signal) {
    throw 'Sampled-value history depth or profile identity is missing.'
}

$proofs = @{}
foreach ($name in 'p_stable','p_changed','p_rose','p_fell','p_nested','p_signed') {
    $record = Require-Result $name @('prove', $project, '--engine', 'pdr', '--property', $name,
        '--max-depth', '12', '--evidence-dir', "$root/$name-certificate") 'PROVEN'
    $proofs[$name] = $record.certificate
    $reopened = Invoke-Case "$name-certificate-verified" $dev @('verify-pdr', $project, '--property', $name,
        '--evidence-dir', "$root/$name-certificate")
    if ($reopened.Exit -ne 0 -or $reopened.Text -cnotmatch 'Q3A_PDR_CERTIFICATE VERIFIED' -or
        $reopened.Text -cnotmatch 'Q3A_PDR_RUN_CONFIGURATION VERIFIED') {
        throw "Certificate did not verify against the source model and run configuration. $($reopened.Text)"
    }
}
$standalone = Invoke-Case standalone $checker @('--check-drat', "$root/p_nested-certificate/consecution.cnf",
    "$root/p_nested-certificate/consecution.q3adrat", '--model-sha256', $proofs.p_nested.model_sha256,
    '--query-kind', 'pdr-consecution')
if ($standalone.Exit -ne 0 -or $standalone.Text -cnotmatch 'Q3A_PROOF_CHECK ACCEPTED') {
    throw "Standalone proof checker rejected nested sampled-value history. $($standalone.Text)"
}
$null = Require-Result no-sample @('prove', $project, '--engine', 'bmc', '--property', 'c_startup', '--frames', '0') 'BOUNDED_COVER_MISS'
$null = Require-Result msb-only @('prove', $project, '--engine', 'bmc', '--property', 'c_msb', '--frames', '1',
    '--bundle-dir', "$root/msb-bundle") 'COVERED'
Require-Reopen msb-replay "$root/msb-bundle"
Require-Rejection default-source-replay $default @("--verify-bundle", "$root/msb-bundle", "--require-source-model") "unsupported source bundle profile"
$null = Require-Result mutation @('prove', $project, '--engine', 'pdr', '--property', 'p_wrong', '--max-depth', '8',
    '--evidence-dir', "$root/mutation-proof", '--bundle-dir', "$root/mutation-bundle") 'FAIL'
Require-Reopen mutation-replay "$root/mutation-bundle"

function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
[ordered]@{
    status = 'DEVELOPMENT_SAMPLED_VALUE_QUALIFIED'
    profile = $profile
    development_sha256 = Hash $dev
    default_sha256 = Hash $default
    checker_sha256 = Hash $checker
    distinct_proofs = $proofs.Count
    standalone_nested_proof = 'ACCEPTED'
    source_certificate_revalidations = 6
    source_bundle_revalidations = 2
    negative_cases = 6
    first_sample_cover = 'BOUNDED_COVER_MISS'
    changed_without_lsb_edge = 'COVERED'
    changed_matches_rose_mutation = 'FAIL'
    hardware_acceptance = 'PENDING'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: sampled-value conformance, first-sample guard, source and standalone proof checks.'

