$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-mixed-context.q3a'

$lowerOutput = @(& $sourcecheck '--lower-project' $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Mixed unsized-decimal RTL failed to lower:`n$($lowerOutput -join "`n")"
}
$tir = ($lowerOutput -join "`n") | ConvertFrom-Json

function Assert-MixedArithmetic($name, $targetWidth, $resultWidth,
                                $inputWidth, $inputSigned, $resultSigned,
                                $hasResize, $operation = '+') {
    $equations = @($tir.combinational_equations | Where-Object target -eq $name)
    if ($equations.Count -ne 1) { throw "Expected one combinational equation for $name." }
    $expression = $equations[0].expression
    if ($hasResize) {
        if ($expression.kind -ne 'assignment_resize' -or
            $expression.width -ne $targetWidth -or
            $expression.operands.Count -ne 1) {
            throw "Expected an explicit assignment resize for ${name}: $($expression | ConvertTo-Json -Depth 8 -Compress)"
        }
        $expression = $expression.operands[0]
    }
    if ($expression.kind -ne 'binary' -or $expression.value -ne $operation -or
        $expression.width -ne $resultWidth -or
        $expression.signed -ne $resultSigned -or
        $expression.operands.Count -ne 2) {
        throw "Unexpected mixed arithmetic sizing for ${name}: $($expression | ConvertTo-Json -Depth 8 -Compress)"
    }
    $left = $expression.operands[0]
    $right = $expression.operands[1]
    if ($left.kind -ne 'signal' -or $left.width -ne $inputWidth -or
        $left.signed -ne $inputSigned -or
        $right.kind -ne 'literal' -or $right.value -ne '1' -or
        $right.width -ne $resultWidth -or -not $right.signed) {
        throw "Unexpected operand widths or signedness for ${name}: $($expression | ConvertTo-Json -Depth 8 -Compress)"
    }
}

Assert-MixedArithmetic 'u8_plus_one' 8 32 8 $false $false $true
Assert-MixedArithmetic 'u8_minus_one' 8 32 8 $false $false $true '-'
Assert-MixedArithmetic 's8_plus_one' 8 32 8 $true  $true  $true
Assert-MixedArithmetic 's8_minus_one' 8 32 8 $true  $true  $true '-'
Assert-MixedArithmetic 'u16_plus_one' 16 32 8 $false $false $true
Assert-MixedArithmetic 'u40_plus_one' 40 40 40 $false $false $false
Assert-MixedArithmetic 'comb_plus_one' 8 32 8 $false $false $true

$negatedEquation = @($tir.combinational_equations | Where-Object target -eq 'u8_negated_plus_one')
if ($negatedEquation.Count -ne 1 -or
    $negatedEquation[0].expression.kind -ne 'assignment_resize' -or
    $negatedEquation[0].expression.operands[0].kind -ne 'unary' -or
    $negatedEquation[0].expression.operands[0].value -ne '-' -or
    $negatedEquation[0].expression.operands[0].width -ne 32 -or
    $negatedEquation[0].expression.operands[0].operands[0].kind -ne 'binary' -or
    $negatedEquation[0].expression.operands[0].operands[0].value -ne '+') {
    throw 'The nested unary-minus and mixed-addition tree must retain 32-bit sizing before 8-bit assignment conversion.'
}

function Find-Expression($node, $kind, $value) {
    if ($node.kind -eq $kind -and $node.value -eq $value) { return $node }
    foreach ($operand in $node.operands) {
        $found = Find-Expression $operand $kind $value
        if ($null -ne $found) { return $found }
    }
    return $null
}

$stateEquations = @($tir.next_state_equations | Where-Object target -eq 'state_plus_one')
if ($stateEquations.Count -ne 1) { throw 'Expected one sequential equation for state_plus_one.' }
$stateResize = Find-Expression $stateEquations[0].expression 'assignment_resize' 'assignment'
if ($null -eq $stateResize -or $stateResize.width -ne 8) {
    throw 'The always_ff mixed arithmetic path must retain an explicit 8-bit assignment conversion.'
}
$stateAdd = Find-Expression $stateResize 'binary' '+'
if ($null -eq $stateAdd -or $stateAdd.width -ne 32 -or -not $stateAdd.signed -or
    $stateAdd.operands[0].kind -ne 'signal' -or
    $stateAdd.operands[0].value -ne 's8_input' -or
    $stateAdd.operands[0].width -ne 8 -or
    -not $stateAdd.operands[0].signed) {
    throw 'The always_ff signed mixed arithmetic expression has incorrect T-IR sizing.'
}

$proof = @(& $sourcecheck '--bmc' $manifest '--property' `
    'p_mixed_decimal_assignment_context' '--frames' '0' 2>&1)
if ($LASTEXITCODE -ne 0 -or
    -not ($proof -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
    -not ($proof -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
    throw "Mixed unsized-decimal reference property failed its symbolic frame-0 query:`n$($proof -join "`n")"
}

$counterexample = @(& $sourcecheck '--bmc' $manifest '--property' `
    'p_mixed_decimal_counterexample' '--frames' '0' 2>&1)
if ($LASTEXITCODE -ne 0 -or
    -not ($counterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($counterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "The mixed-expression counterexample did not pass independent frame replay:`n$($counterexample -join "`n")"
}

$unsupportedManifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-mixed-unsupported.q3a'
$unsupported = @(& $sourcecheck '--lower-project' $unsupportedManifest 2>&1)
$unsupportedText = $unsupported -join "`n"
if ($LASTEXITCODE -eq 0 -or
    $unsupportedText -notmatch "operator '\*' is outside the Phase 0 RTL expression subset") {
    throw "An out-of-scope multiplication must fail closed:`n$unsupportedText"
}

Write-Output 'PASS: mixed unsized-decimal +/- expressions match the symbolic reference; the counterexample replays and multiplication is rejected.'
