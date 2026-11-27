$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-sized-select-bounds.q3a'

$verified = @(& $tool --bmc $manifest --property p_expected --frames 0)
if ($LASTEXITCODE -ne 0 -or
    $verified -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $verified -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "Sized bound arithmetic and bitwise expressions did not match the constant-index references:`n$($verified -join "`n")"
}
foreach ($property in @('p_wrong_index', 'p_wrong_bitwise_range')) {
    $wrongIndex = @(& $tool --bmc $manifest --property $property --frames 0)
    if ($LASTEXITCODE -ne 0 -or
        $wrongIndex -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $wrongIndex -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Expected a replayed counterexample for $property.`n$($wrongIndex -join "`n")"
    }
}

'PASS: fixed-width arithmetic, bitwise, and conditional selects match explicit carry, borrow, signedness, shift and range direction references.'
