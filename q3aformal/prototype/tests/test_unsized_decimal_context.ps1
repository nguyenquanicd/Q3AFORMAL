$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-context.q3a'

$lowerOutput = @(& $sourcecheck '--lower-project' $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Unsized-decimal RTL failed to lower:`n$($lowerOutput -join "`n")"
}
$tir = ($lowerOutput -join "`n") | ConvertFrom-Json

function Assert-ResizeEquation($name, $targetWidth, $sourceWidth, $sourceSigned, $sourceKind) {
    $matches = @($tir.combinational_equations | Where-Object target -eq $name)
    if ($matches.Count -ne 1) { throw "Expected one combinational equation for $name." }
    $expression = $matches[0].expression
    if ($expression.kind -ne 'assignment_resize' -or
        $expression.width -ne $targetWidth -or
        $expression.operands.Count -ne 1 -or
        $expression.operands[0].width -ne $sourceWidth -or
        $expression.operands[0].signed -ne $sourceSigned -or
        $expression.operands[0].kind -ne $sourceKind) {
        throw "Unexpected T-IR assignment sizing for ${name}: $($expression | ConvertTo-Json -Depth 8 -Compress)"
    }
}

Assert-ResizeEquation 'u8_one' 8 32 $true 'literal'
Assert-ResizeEquation 'u8_truncate' 8 32 $true 'literal'
Assert-ResizeEquation 's8_negative' 8 32 $true 'unary'
Assert-ResizeEquation 'u8_sum' 8 32 $true 'binary'
Assert-ResizeEquation 'comb_value' 8 32 $true 'literal'

$wideOne = @($tir.combinational_equations | Where-Object target -eq 'u40_one')
$wideNegative = @($tir.combinational_equations | Where-Object target -eq 's40_negative')
if ($wideOne.Count -ne 1 -or $wideOne[0].expression.width -ne 40 -or
    $wideOne[0].expression.kind -ne 'literal' -or
    -not $wideOne[0].expression.signed) {
    throw 'The 40-bit assignment context must widen the signed unsized decimal literal to 40 bits.'
}
if ($wideNegative.Count -ne 1 -or $wideNegative[0].expression.width -ne 40 -or
    $wideNegative[0].expression.kind -ne 'unary' -or
    -not $wideNegative[0].expression.signed -or
    $wideNegative[0].expression.operands[0].width -ne 40) {
    throw 'The 40-bit assignment context must apply to the unary-negative decimal expression.'
}

$stateEquation = @($tir.next_state_equations | Where-Object target -eq 'state_value')
if ($stateEquation.Count -ne 1 -or
    $stateEquation[0].expression.kind -ne 'assignment_resize' -or
    $stateEquation[0].expression.width -ne 8 -or
    $stateEquation[0].expression.operands[0].kind -ne 'unary' -or
    $stateEquation[0].expression.operands[0].width -ne 32) {
    throw 'The sequential assignment path must preserve 32-bit literal sizing and explicit destination conversion.'
}

$proof = @(& $sourcecheck '--bmc' $manifest '--property' 'p_unsized_decimal_assignment_context' '--frames' '0' 2>&1)
if ($LASTEXITCODE -ne 0 -or
    -not ($proof -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
    -not ($proof -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
    throw "The unsized-decimal expected-value property failed its frame-0 query:`n$($proof -join "`n")"
}

$binRoot = [System.IO.Path]::GetFullPath((Join-Path $prototypeRoot 'bin'))
$tempRoot = Join-Path $binRoot ('rtl005-context-' + [guid]::NewGuid().ToString('N'))
$prefix = Join-Path $tempRoot 'proof'
$bundle = Join-Path $tempRoot 'bundle'
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $inductionArguments = @('--prove-inductive', $manifest,
        '--property', 'p_unsized_decimal_assignment_context',
        '--output-prefix', $prefix, '--bundle-dir', $bundle)
    $induction = @(& $sourcecheck @inductionArguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        -not ($induction -contains 'Q3A_INDUCTION_STATUS PROVEN') -or
        -not ($induction -contains 'Q3A_INDUCTION_CERTIFICATE INDUCTIVE_PROOF_ACCEPTED')) {
        throw "The unsized-decimal property failed checked induction:`n$($induction -join "`n")"
    }
    $reopen = @(& $sourcecheck '--verify-bundle' $bundle 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        -not ($reopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "The unsized-decimal proof bundle did not reopen:`n$($reopen -join "`n")"
    }
} finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($binRoot + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

Write-Output 'PASS: RTL-005 checks minimum 32-bit signed literal sizing, narrow assignment truncation, wide context sizing, and continuous/always_comb/always_ff conversion; bounded expected values and checked induction both pass, and the proof bundle reopens.'
