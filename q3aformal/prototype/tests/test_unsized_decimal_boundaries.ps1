$ErrorActionPreference = 'Stop'
$prototype = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $prototype 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototype 'rtl-unsized-decimal-boundaries.q3a'
$raw = & $tool --lower-project $manifest
if ($LASTEXITCODE -ne 0) { throw 'Could not lower the decimal boundary design.' }
$model = ($raw -join "`n") | ConvertFrom-Json

foreach ($case in @(
    @{ Name = 'p_min_width'; Width = 32; Value = '2147483647' },
    @{ Name = 'p_extra_sign_bit'; Width = 33; Value = '2147483648' },
    @{ Name = 'p_magnitude_bit'; Width = 34; Value = '4294967296' },
    @{ Name = 'p_max_positive'; Width = 64; Value = '9223372036854775807' },
    @{ Name = 'p_unary_minus'; Width = 33; Value = '2147483648'; Negative = $true }
)) {
    $property = @($model.properties | Where-Object { $_.name -eq $case.Name })
    if ($property.Count -ne 1) { throw "Missing $($case.Name)." }
    $left = $property[0].antecedent.terms[0].predicate.operands[0]
    if ($case.Negative) {
        if ($left.kind -ne 'unary' -or $left.value -ne '-' -or
            $left.width -ne $case.Width -or !$left.signed) {
            throw "Unary minus did not preserve its operand width."
        }
        $left = $left.operands[0]
    }
    if ($left.kind -ne 'literal' -or $left.width -ne $case.Width -or
        !$left.signed -or $left.value -cne $case.Value -or
        $left.source.file -notlike '*/rtl_unsized_decimal_boundaries.sv') {
        throw "Incorrect decimal width, value or source map for $($case.Name)."
    }
}

foreach ($name in @('p_min_width','p_extra_sign_bit','p_magnitude_bit',
                    'p_max_positive','p_unary_minus','p_port','p_truncate','p_widen')) {
    $result = @(& $tool --bmc $manifest --property $name --frames 0)
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $result -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Expected nonvacuous decimal pass for ${name}:`n$($result -join "`n")"
    }
}
$failure = @(& $tool --bmc $manifest --property p_deliberately_false --frames 0)
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "Expected a replayed counterexample:`n$($failure -join "`n")"
}

$savedPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $overflow = @(& $tool --bmc (Join-Path $prototype 'reject-unsized-decimal-overflow.q3a') --property p_value --frames 0 2>&1)
    $overflowExit = $LASTEXITCODE
} finally { $ErrorActionPreference = $savedPreference }
if ($overflowExit -ne 1 -or
    ($overflow -join "`n") -notmatch 'Q3A_LOWERING_ERROR .*rtl_unsized_decimal_overflow\.sv:2:\d+: unsized decimal literal exceeds the supported signed 64-bit range' -or
    ($overflow -join "`n") -match 'Q3A_BMC_STATUS') {
    throw "Expected a source-located rejection before a formal verdict:`n$($overflow -join "`n")"
}

'PASS: decimal literals preserve 32/33/34/64-bit signed widths, exact-width port binding, assignment conversion, and replay. Larger input is rejected.'
