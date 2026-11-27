$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'lower-sva-assertion-conformance.q3a'
$lowerOutput = @(& $sourcecheck --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Concurrent assertion vector did not lower:`n$($lowerOutput -join "`n")"
}
$tir = ($lowerOutput -join "`n") | ConvertFrom-Json
if (@($tir.clocks).Count -ne 1 -or $tir.clocks[0] -ne 'clk') {
    throw 'The assertion model must bind exactly one positive-edge clock named clk.'
}
$properties = @($tir.properties)
if ($properties.Count -ne 2) { throw "Expected two concurrent assertions, found $($properties.Count)." }
$propertyByName = @{}
foreach ($property in $properties) { $propertyByName[$property.name] = $property }
foreach ($expected in @(
    @{ name = 'p_known_true'; assertion_line = 8; expression_line = 6; expression_kind = 'binary'; expression_op = '||' },
    @{ name = 'p_known_false'; assertion_line = 13; expression_line = 11; expression_kind = 'signal'; expression_op = 'a' }
)) {
    if (-not $propertyByName.ContainsKey($expected.name)) {
        throw "Missing assertion record '$($expected.name)'."
    }
    $property = $propertyByName[$expected.name]
    if ($property.kind -ne 'assert' -or $property.clock -ne 'clk' -or
        $property.source.line -ne $expected.assertion_line -or
        $property.antecedent.terms.Count -ne 1 -or
        $property.antecedent.terms[0].predicate.kind -ne $expected.expression_kind -or
        $property.antecedent.terms[0].predicate.value -ne $expected.expression_op -or
        $property.antecedent.terms[0].predicate.source.line -ne $expected.expression_line -or
        $null -ne $property.consequent) {
        throw "Concurrent assertion T-IR, clock binding, or source mapping mismatch for '$($expected.name)'."
    }
}

$knownTrue = @(& $sourcecheck --bmc $manifest --property 'p_known_true' --frames 0 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $knownTrue -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $knownTrue -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "Known-true assertion did not pass nonvacuously at frame 0:`n$($knownTrue -join "`n")"
}

$knownFalse = @(& $sourcecheck --bmc $manifest --property 'p_known_false' --frames 0 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $knownFalse -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $knownFalse -notcontains 'Q3A_BMC_VACUITY NONVACUOUS' -or
    $knownFalse -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $knownFalse -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=a width=1 value=0x0') {
    throw "Known-false assertion did not produce the expected replay-validated frame-0 witness:`n$($knownFalse -join "`n")"
}

$negativeManifest = Join-Path $prototypeRoot 'reject-sva-negedge.q3a'
$negative = @(& $sourcecheck --lower-project $negativeManifest 2>&1)
$negativeText = $negative -join "`n"
if ($LASTEXITCODE -ne 1 -or
    $negativeText -notmatch "sva_negedge_reject\.sv:6:11: expected 'posedge', found 'negedge'" -or
    $negativeText -match '(?m)^Q3A_BMC_STATUS\b') {
    throw "Unsupported negedge event control must reject before BMC:`n$negativeText"
}

$labeledManifest = Join-Path $prototypeRoot 'lower-sva-labeled-checks.q3a'
$labeled = @(& $sourcecheck --lower-project $labeledManifest)
if ($LASTEXITCODE -ne 0) { throw "Could not lower labeled property checks: $labeled" }
$labeledModel = ($labeled -join "`n") | ConvertFrom-Json
$expected = @{
    'assert_a' = 'assert'
    'constrain_a' = 'assume'
    'cover_b' = 'cover'
    'u_leaf.check_a' = 'assert'
    'u_leaf.see_a' = 'cover'
    'u_wrap.u_nested.check_a' = 'assert'
    'u_wrap.u_nested.see_a' = 'cover'
}
if ($labeledModel.properties.Count -ne $expected.Count) {
    throw 'Labeled top and child properties did not lower to distinct identities.'
}
foreach ($id in $expected.Keys) {
    $matches = @($labeledModel.properties | Where-Object name -CEQ $id)
    if ($matches.Count -ne 1 -or $matches[0].kind -ne $expected[$id] -or $matches[0].clock -ne 'clk') {
        throw "Missing or incorrect labeled property '$id'."
    }
}
$leafProperty = $labeledModel.properties | Where-Object name -CEQ 'u_leaf.check_a'
if ($leafProperty.source.line -ne 5 -or $leafProperty.source.column -ne 5) {
    throw 'Labeled child property does not point to its source label.'
}
foreach ($query in @(
    @{ Name = 'assert_a'; Status = 'BOUNDED_PASS' },
    @{ Name = 'u_leaf.check_a'; Status = 'BOUNDED_PASS' },
    @{ Name = 'u_wrap.u_nested.check_a'; Status = 'BOUNDED_FAIL' },
    @{ Name = 'u_wrap.u_nested.see_a'; Status = 'COVERED' }
)) {
    $output = @(& $sourcecheck --bmc $labeledManifest --property $query.Name --frames 0)
    if ($LASTEXITCODE -ne 0 -or $output -notcontains "Q3A_BMC_STATUS $($query.Status)" -or
        ($query.Status -ne 'BOUNDED_PASS' -and $output -notcontains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Incorrect verdict for labeled property $($query.Name):`n$($output -join "`n")"
    }
}
$duplicateManifest = Join-Path $prototypeRoot 'reject-sva-duplicate-check-label.q3a'
$duplicate = @(& $sourcecheck --lower-project $duplicateManifest 2>&1)
if ($LASTEXITCODE -ne 1 -or ($duplicate -join "`n") -notmatch
    "sva_duplicate_check_label\.sv:3:5: duplicate property check name 'check_a'") {
    throw "Duplicate property identity did not reject with its source location: $duplicate"
}

'PASS: clock binding, source mapping, labeled assert/assume/cover through two hierarchy levels, replay, and source-located duplicate/unsupported-clock rejection.'
