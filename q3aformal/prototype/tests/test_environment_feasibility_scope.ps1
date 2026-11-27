#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = Join-Path $root 'project.q3a'
$source = Join-Path $root 'fixture.sv'
@('Q3AFORMAL_PROJECT 2','top feasibility','source systemverilog "fixture.sv"') |
    Set-Content -LiteralPath $manifest -Encoding utf8

function Write-Fixture([string]$Constraint) {
    @"
module feasibility(input logic clk, input logic a);
    env_high: assume property (@(posedge clk) a);
    env_conflict: assume property (@(posedge clk) $Constraint);
    p_safe: assert property (@(posedge clk) a);
    c_hit: cover property (@(posedge clk) a);
endmodule
"@ | Set-Content -LiteralPath $source -Encoding utf8
}

function Count-LegalPrefixes([int]$Bound, [int]$ConflictSample) {
    $legal = 0
    foreach ($bits in 0..((1 -shl ($Bound + 1)) - 1)) {
        $permitted = $true
        for ($sample = 0; $sample -le $Bound; ++$sample) {
            $value = [bool]($bits -band (1 -shl $sample))
            if (!$value -or ($sample -ge $ConflictSample -and $value)) {
                $permitted = $false
                break
            }
        }
        if ($permitted) { ++$legal }
    }
    return $legal
}

function Test-Run([string]$Id,[string]$Engine,[string]$Property,[int]$Depth,
                  [int]$ReportedBound,[int]$ConflictSample,[string]$Status,[int]$Code,
                  [string[]]$ExtraOptions=@()) {
    $record = Join-Path $root "$Id.json"
    $certificate = Join-Path $root "$Id-proof"
    $bundle = Join-Path $root "$Id-bundle"
    $stderr = Join-Path $root "$Id.stderr.txt"
    $options = @($manifest,'--run-record',$record,'--engine',$Engine,'--property',$Property)
    $options += switch ($Engine) {
        bmc { @('--frames',[string]$Depth,'--bundle-dir',$bundle) }
        induction { @('--k',[string]$Depth,'--output-prefix',$certificate) }
        pdr { @('--max-depth',[string]$Depth,'--evidence-dir',$certificate) }
    }
    $stdout = @(& $exe prove @options @ExtraOptions 2> $stderr)
    $actual = $LASTEXITCODE
    if ($stdout.Count -ne 1) { throw "$Id should return one JSON result." }
    $result = $stdout[0] | ConvertFrom-Json
    $expected = if ((Count-LegalPrefixes $ReportedBound $ConflictSample) -gt 0) { 'SAT' } else { 'UNSAT' }
    $scope = if ($ReportedBound -eq 0) { 'INITIAL_SAMPLE' } else { 'FINITE_PREFIX' }
    $feasibility = $result.properties[0].environment_feasibility
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status -or
        $result.properties[0].name -cne $Property -or
        $feasibility.status -cne $expected -or $feasibility.scope -cne $scope -or
        $feasibility.bound -ne $ReportedBound -or
        (Get-Content -Raw -LiteralPath $record).TrimEnd() -cne $stdout[0]) {
        throw "$Id disagrees with the independent finite-prefix oracle. $stdout $(Get-Content -Raw $stderr)"
    }
    if ($expected -ceq 'UNSAT' -and ($result.certificate -or (Test-Path -LiteralPath $certificate))) {
        throw "$Id published a certificate under contradictory assumptions."
    }
    if ($Engine -ceq 'bmc' -and $expected -ceq 'UNSAT') {
        $verified = @(& $exe --verify-bundle $bundle --require-source-model)
        $verified | Set-Content -LiteralPath (Join-Path $root "$Id.revalidation.txt") -Encoding utf8
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            $verified -cnotcontains "Q3A_BUNDLE_BMC_QUERY REVALIDATED status=$conflict bound=$ReportedBound") {
            throw "$Id did not archive a revalidated inconsistency query."
        }
    }
    [ordered]@{id=$Id;engine=$Engine;property=$Property;status=$result.status;environment=$feasibility}
}

$conflict = 'INCONSISTENT_MODEL_OR_ASSUMPTIONS'
$results = @(
    Write-Fixture "1'b1 |=> 1'b1 ##1 !a"
    Test-Run short-bmc bmc p_safe 1 1 2 BOUNDED_PASS 1
    Test-Run short-bmc-cover bmc c_hit 1 1 2 COVERED 0
    Test-Run late-bmc-assert bmc p_safe 2 2 2 $conflict 1
    Test-Run late-bmc-cover bmc c_hit 3 3 2 $conflict 1
    Test-Run late-induction induction p_safe 1 2 2 $conflict 1
    Test-Run late-pdr-assert pdr p_safe 2 2 2 $conflict 1
    Test-Run late-pdr-cover pdr c_hit 2 2 2 $conflict 1
    Test-Run capped-pdr pdr p_safe 2 0 2 RESOURCE_LIMIT 1 @('--max-queries','1')
    Write-Fixture '!$past(a, 2)'
    Test-Run history-warmup bmc p_safe 1 1 2 BOUNDED_PASS 1
    Test-Run history-conflict bmc c_hit 2 2 2 $conflict 1
    Test-Run history-induction induction p_safe 2 2 2 $conflict 1
    Write-Fixture '!a'
    Test-Run initial-bmc bmc c_hit 0 0 0 $conflict 1
    Test-Run initial-pdr pdr c_hit 2 0 0 $conflict 1
)
[ordered]@{schema='Q3AFORMAL_ENVIRONMENT_FEASIBILITY_1';executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();
    cases=$results} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: exact initial and bounded environment scopes, cover and assertion outcomes, and capped PDR feasibility.'
