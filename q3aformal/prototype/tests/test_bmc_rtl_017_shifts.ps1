$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-rtl-017-shifts.q3a'

foreach ($direction in @('left', 'right')) {
    foreach ($amount in 0..7) {
        $propertyName = "p_${direction}_${amount}"
        $output = & $executable --bmc $manifest --property $propertyName --frames 0
        if ($LASTEXITCODE -ne 0 -or
            -not ($output -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
            -not ($output -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
            throw "RTL-017 shift boundary failed for ${propertyName}:`n$($output -join "`n")"
        }
    }
}

'PASS: source-level BMC proves all 16 four-bit left/right shift distances (0 through 7) against independently written bit-concatenation/zero-fill references.'
