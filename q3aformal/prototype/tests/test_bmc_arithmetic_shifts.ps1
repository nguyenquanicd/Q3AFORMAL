$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-arithmetic-shifts.q3a'

foreach ($propertyName in @(
    'p_add_false',
    'p_sub_false',
    'p_neg_false',
    'p_shift_left_false',
    'p_shift_right_false'
)) {
    $output = & $executable --bmc $manifest --property $propertyName --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($output -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($output -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Arithmetic/shift BMC witness failed SAT or independent replay for ${propertyName}:`n$($output -join "`n")"
    }
}

'PASS: RTL arithmetic and constant-shift counterexamples are solved and independently replayed.'
