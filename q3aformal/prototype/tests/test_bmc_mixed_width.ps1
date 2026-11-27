$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-mixed-width.q3a'

foreach ($propertyName in @(
    'p_unsigned_relational_extension',
    'p_unsigned_equality_extension',
    'p_unsigned_bitwise_extension',
    'p_signed_relational_extension',
    'p_signed_arithmetic_extension',
    'p_signed_conditional_extension'
)) {
    $output = & $executable --bmc $manifest --property $propertyName --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($output -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
        -not ($output -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
        throw "Source-level mixed-width extension check failed for ${propertyName}:`n$($output -join "`n")"
    }
}

'PASS: source-level signed and unsigned mixed-width relational, equality, bitwise, arithmetic, and conditional expressions agree with explicitly extended references.'
