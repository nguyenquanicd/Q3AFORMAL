$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-sized-expression-context.q3a'

$model = @(& $tool --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0) { throw ($model -join "`n") }
$tir = ($model -join "`n") | ConvertFrom-Json
$equations = @{}
foreach ($equation in $tir.combinational_equations) {
    $equations[$equation.target] = $equation.expression
}
if ($equations['wide_sum'].width -ne 16 -or
    $equations['nested_sum'].operands[0].width -ne 16 -or
    $equations['narrow_diff'].kind -ne 'assignment_resize' -or
    $equations['narrow_diff'].operands[0].width -ne 8 -or
    $equations['sign_extended'].kind -ne 'assignment_resize' -or
    -not $equations['sign_extended'].operands[0].signed -or
    $equations['after_temporary_sum'].operands[0].width -ne 8) {
    throw 'The transition model did not preserve the expected evaluation widths and assignment boundary.'
}

foreach ($property in @('p_compare', 'p_sum', 'p_diff', 'p_sign', 'p_temporary',
    'p_signed_temporary', 'p_state')) {
    $frames = if ($property -eq 'p_state') { 1 } else { 0 }
    $result = @(& $tool --bmc $manifest --property $property --frames $frames 2>&1)
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $result -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Unexpected result for ${property}:`n$($result -join "`n")"
    }
}

$failure = @(& $tool --bmc $manifest --property p_lost_carry --frames 0 2>&1)
$carry = @($failure | Where-Object {
    $_ -match '^Q3A_BMC_TRACE_SIGNAL frame=0 name=wide_sum width=16 value=0x1[0-9a-f]{2}$'
})
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or $carry.Count -ne 1) {
    throw "Expected a replayed carry witness:`n$($failure -join "`n")"
}

'PASS: sized arithmetic, comparisons, assignment conversion, and typed blocking temporary boundaries.'
