$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-shift-assignment-context.q3a'

$output = @(& $tool --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not lower the shift context cases:`n$($output -join "`n")"
}
$tir = ($output -join "`n") | ConvertFrom-Json
$equations = @{}
foreach ($equation in $tir.combinational_equations) {
    $equations[$equation.target] = $equation.expression
}
$left = $equations['left_wide']
$right = $equations['right_wide']
$narrow = $equations['narrow']
$isolated = $equations['isolated_distance']
$conditionalWidth = $equations['selected_sum_wide']
$conditionalTruncation = $equations['selected_sum_narrow']
$conditionalPredicate = $equations['condition_isolated'].operands[0]
if ($left.value -ne '<<' -or $left.width -ne 16 -or
    $left.operands[0].width -ne 16 -or $left.operands[0].operands[0].width -ne 8 -or
    $right.value -ne '>>' -or $right.operands[0].value -ne '+' -or
    $right.operands[0].width -ne 16 -or
    $narrow.kind -ne 'assignment_resize' -or $narrow.width -ne 8 -or
    $narrow.operands[0].width -ne 16 -or
    $isolated.width -ne 40 -or $isolated.operands[1].width -ne 32 -or
    $conditionalWidth.kind -ne 'conditional' -or
    $conditionalWidth.operands[1].width -ne 16 -or
    $conditionalTruncation.kind -ne 'assignment_resize' -or
    $conditionalTruncation.width -ne 8 -or $conditionalTruncation.operands[0].width -ne 16 -or
    $conditionalPredicate.width -ne 32) {
    throw 'Shift width, assignment conversion, or distance isolation is incorrect in the transition model.'
}

foreach ($property in @('p_left', 'p_right', 'p_signed', 'p_truncate', 'p_distance', 'p_state',
    'p_nested_compare', 'p_nested_add', 'p_nested_select', 'p_nested_mixed', 'p_condition_isolated',
    'p_selected_sum_wide', 'p_selected_sum_narrow', 'p_alternate_branch')) {
    $frames = if ($property -eq 'p_state') { 1 } else { 0 }
    $result = @(& $tool --bmc $manifest --property $property --frames $frames 2>&1)
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $result -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Shift context reference ${property} failed:`n$($result -join "`n")"
    }
}

$failure = @(& $tool --bmc $manifest --property p_lost_bit --frames 0 2>&1)
$shifted = @($failure | Where-Object {
    $_ -match '^Q3A_BMC_TRACE_SIGNAL frame=0 name=left_wide width=16 value=0x1[0-9a-f]{2}$'
})
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or $shifted.Count -ne 1) {
    throw "Expected an independently replayed witness with bit 8 set:`n$($failure -join "`n")"
}

'PASS: logical shifts preserve assignment context and independent distance sizing, and replay a carry witness.'
