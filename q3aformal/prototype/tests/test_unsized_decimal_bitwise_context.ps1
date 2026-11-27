$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-bitwise-context.q3a'

$lowered = @(& $tool --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not lower mixed arithmetic and bitwise RTL:`n$($lowered -join "`n")"
}
$tir = ($lowered -join "`n") | ConvertFrom-Json
$repeated = @(& $tool --lower-project $manifest 2>&1)
if ($LASTEXITCODE -ne 0 -or ($repeated -join "`n") -cne ($lowered -join "`n")) {
    throw 'Repeated lowering changed the exact serialized transition model.'
}
$masked = ($tir.combinational_equations | Where-Object target -eq 'masked').expression
$sumBits = ($tir.combinational_equations | Where-Object target -eq 'sum_bits').expression
$unsignedComplement = ($tir.combinational_equations |
    Where-Object target -eq 'unsigned_complement').expression
$signedComplement = ($tir.combinational_equations |
    Where-Object target -eq 'signed_complement').expression
if ($masked.kind -ne 'assignment_resize' -or $masked.width -ne 8 -or
    $masked.operands[0].value -ne '&' -or $masked.operands[0].width -ne 32 -or
    $sumBits.kind -ne 'assignment_resize' -or $sumBits.width -ne 16 -or
    $sumBits.operands[0].operands[0].value -ne '+' -or
    $sumBits.operands[0].operands[0].width -ne 32 -or
    $unsignedComplement.operands[0].operands[0].signed -or
    $signedComplement.width -ne 40 -or -not $signedComplement.operands[0].signed) {
    throw 'The transition model has an incorrect bitwise evaluation width or signedness.'
}

$narrow = ($tir.combinational_equations | Where-Object target -eq 'narrow_predicate').expression
$wide = ($tir.combinational_equations | Where-Object target -eq 'wide_comparison').expression
$shift = ($tir.combinational_equations | Where-Object target -eq 'self_sized_shift_count').expression
$member = ($tir.combinational_equations | Where-Object target -eq 'self_sized_member').expression
if ($narrow.operands[0].operands[0].width -ne 32 -or
    $wide.operands[0].operands[0].width -ne 40 -or
    $shift.width -ne 40 -or $shift.operands[1].width -ne 8 -or
    $shift.operands[1].operands[0].operands[0].width -ne 32 -or
    $member.kind -ne 'concatenation' -or $member.width -ne 40 -or
    $member.operands[1].width -ne 32) {
    throw 'Result context leaked into a self-determined operand or did not reach a comparison operand.'
}

$properties = @('p_mask', 'p_sum_bits', 'p_unsigned_complement', 'p_signed_complement',
    'p_inverse_xor', 'p_inverse_xor_alternate', 'p_comb_mask', 'p_state_bits', 'p_comparison',
    'p_decimal_shift_context', 'p_decimal_conditional_context', 'p_self_determined_context')
foreach ($property in $properties) {
    $frames = if ($property -eq 'p_state_bits') { 1 } else { 0 }
    $output = @(& $tool --bmc $manifest --property $property --frames $frames 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $output -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Bitwise reference failed for ${property}:`n$($output -join "`n")"
    }
}

$failure = @(& $tool --bmc $manifest --property p_carry_lost --frames 0 2>&1)
$carryLines = @($failure | Where-Object {
    $_ -match '^Q3A_BMC_TRACE_SIGNAL frame=0 name=sum_bits width=16 value=0x1[0-9a-f]{2}$'
})
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or $carryLines.Count -ne 1) {
    throw "Expected a replayed witness with bit 8 set:`n$($failure -join "`n")"
}

$invalidManifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-runtime-concat-reject.q3a'
$invalid = @(& $tool --lower-project $invalidManifest 2>&1)
if ($LASTEXITCODE -ne 1 -or ($invalid -join "`n") -notmatch
    'Q3A_LOWERING_ERROR .*rtl_unsized_decimal_runtime_concat\.sv:5:28: unsized decimal concatenation member requires an explicit width') {
    throw "A direct unsized decimal concatenation member should be rejected at its source:`n$($invalid -join "`n")"
}

$wrongContext = @(& $tool --bmc $manifest --property p_wrong_predicate_context --frames 0)
if ($LASTEXITCODE -ne 0 -or $wrongContext -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $wrongContext -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "A widened self-determined predicate must produce a replayed counterexample:`n$($wrongContext -join "`n")"
}

'PASS: twelve decimal-expression references, including nested self-determined widths and two replayed false expectations.'
