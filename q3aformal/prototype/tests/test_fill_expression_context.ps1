$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-fill-expression-context.q3a'

$output = @(& $tool --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
$tir = ($output -join "`n") | ConvertFrom-Json
$equations = @{}
foreach ($equation in $tir.combinational_equations) {
    $equations[$equation.target] = $equation.expression
}
$packed = $equations['packed_bits']
$distance = $equations['shifted'].operands[1]
$mask = $equations['masked'].operands[1]
if ($packed.kind -ne 'concatenation' -or $packed.width -ne 8 -or
    ($packed.operands.width -join ',') -ne '1,6,1' -or
    $distance.value -ne "'1" -or $distance.width -ne 1 -or
    $mask.value -ne "'1" -or $mask.width -ne 16) {
    throw 'Unexpected fill width in the concatenation, shift distance or mask.'
}

foreach ($property in @('p_compare', 'p_mask', 'p_packed', 'p_shift', 'p_selected',
    'p_child', 'p_tied_child', 'p_case', 'p_register', 'p_register_zero')) {
    $frames = if ($property -like 'p_register*') { 1 } else { 0 }
    $result = @(& $tool --bmc $manifest --property $property --frames $frames 2>&1)
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $result -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Unexpected result for ${property}:`n$($result -join "`n")"
    }
}

$failure = @(& $tool --bmc $manifest --property p_bad_mask --frames 0 2>&1)
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "The false one-bit-mask property should yield a replayed witness:`n$($failure -join "`n")"
}

'PASS: ten fill-context properties, including self-determined widths, port bindings and 64-bit state; false mask replays.'
