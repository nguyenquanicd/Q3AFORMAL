$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'

function Get-LoweredManifest([string] $manifestName) {
    $manifest = Join-Path $prototypeRoot $manifestName
    $output = @(& $sourcecheck --lower-project $manifest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Assumption vector $manifestName failed to lower:`n$($output -join "`n")"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

$consistent = Get-LoweredManifest 'lower-sva-assumption-consistent.q3a'
if (@($consistent.clocks).Count -ne 1 -or $consistent.clocks[0] -ne 'clk') {
    throw 'The consistent model must bind exactly one positive-edge clock.'
}
$consistentByName = @{}
foreach ($property in @($consistent.properties)) { $consistentByName[$property.name] = $property }
foreach ($expected in @(
    @{ name = 'p_assume_a'; kind = 'assume'; line = 11; expression_line = 6 },
    @{ name = 'p_assert_a'; kind = 'assert'; line = 12; expression_line = 9 }
)) {
    if (-not $consistentByName.ContainsKey($expected.name)) {
        throw "Missing SVA record '$($expected.name)'."
    }
    $property = $consistentByName[$expected.name]
    if ($property.kind -ne $expected.kind -or $property.clock -ne 'clk' -or
        $property.source.line -ne $expected.line -or
        $property.antecedent.terms.Count -ne 1 -or
        $property.antecedent.terms[0].predicate.kind -ne 'signal' -or
        $property.antecedent.terms[0].predicate.value -ne 'a' -or
        $property.antecedent.terms[0].predicate.source.line -ne $expected.expression_line) {
        throw "Assumption/assertion identity or source mapping mismatch for '$($expected.name)'."
    }
}

# Independent exhaustive reference for three one-bit sampled input frames.
$legalConsistentSequences = 0
for ($sequence = 0; $sequence -lt 8; $sequence++) {
    $allFramesAssumed = $true
    $assertionHolds = $true
    foreach ($frame in 0..2) {
        $a = ($sequence -shr $frame) -band 1
        if ($a -ne 1) { $allFramesAssumed = $false }
        if ($a -ne 1) { $assertionHolds = $false }
    }
    if ($allFramesAssumed -and $assertionHolds) { $legalConsistentSequences++ }
}
if ($legalConsistentSequences -ne 1) {
    throw "Independent oracle expected one consistent three-frame sequence, found $legalConsistentSequences."
}

$consistentQuery = @(& $sourcecheck --bmc (Join-Path $prototypeRoot 'lower-sva-assumption-consistent.q3a') --property 'p_assert_a' --frames 2 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $consistentQuery -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $consistentQuery -notcontains 'Q3A_BMC_BOUND transitions=2 frames=3' -or
    $consistentQuery -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "Consistent assumption did not constrain every active sampled frame:`n$($consistentQuery -join "`n")"
}

$contradictory = Get-LoweredManifest 'lower-sva-assumption-contradictory.q3a'
$contradictoryByName = @{}
foreach ($property in @($contradictory.properties)) { $contradictoryByName[$property.name] = $property }
foreach ($expected in @(
    @{ name = 'p_assume_a_high'; kind = 'assume'; line = 28; predicate_kind = 'signal'; predicate_value = 'a'; predicate_line = 20 },
    @{ name = 'p_assume_a_low'; kind = 'assume'; line = 29; predicate_kind = 'unary'; predicate_value = '!'; predicate_line = 23 },
    @{ name = 'p_assert_a_high'; kind = 'assert'; line = 30; predicate_kind = 'signal'; predicate_value = 'a'; predicate_line = 26 }
)) {
    if (-not $contradictoryByName.ContainsKey($expected.name)) {
        throw "Missing contradictory-model property '$($expected.name)'."
    }
    $property = $contradictoryByName[$expected.name]
    if ($property.kind -ne $expected.kind -or $property.clock -ne 'clk' -or
        $property.source.line -ne $expected.line -or
        $property.antecedent.terms[0].predicate.kind -ne $expected.predicate_kind -or
        $property.antecedent.terms[0].predicate.value -ne $expected.predicate_value -or
        $property.antecedent.terms[0].predicate.source.line -ne $expected.predicate_line) {
        throw "Contradictory assumption identity, clock, or source mapping mismatch for '$($expected.name)'."
    }
}

$legalContradictoryValues = 0
foreach ($a in 0..1) {
    $highAssumption = ($a -eq 1)
    $lowAssumption = ($a -eq 0)
    if ($highAssumption -and $lowAssumption) { $legalContradictoryValues++ }
}
if ($legalContradictoryValues -ne 0) {
    throw 'Independent one-frame oracle expected contradictory assumptions to have no legal value.'
}

$contradictoryQuery = @(& $sourcecheck --bmc (Join-Path $prototypeRoot 'lower-sva-assumption-contradictory.q3a') --property 'p_assert_a_high' --frames 2 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $contradictoryQuery -notcontains 'Q3A_BMC_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS' -or
    $contradictoryQuery -notcontains 'Q3A_BMC_BOUND transitions=2 frames=3' -or
    $contradictoryQuery -contains 'Q3A_BMC_VACUITY VACUOUS') {
    throw "Contradictory assumptions were not reported explicitly as inconsistent:`n$($contradictoryQuery -join "`n")"
}

'PASS: assumption identities/source mappings are retained; the consistent assumption constrains all three sampled frames, and contradictory assumptions return INCONSISTENT_MODEL_OR_ASSUMPTIONS.'
