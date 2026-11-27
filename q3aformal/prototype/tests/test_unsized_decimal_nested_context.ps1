$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-unsized-decimal-nested-context.q3a'

$rawModel = & $tool --lower-project $manifest
if ($LASTEXITCODE -ne 0) { throw 'Could not lower the nested decimal design.' }
$model = ($rawModel -join "`n") | ConvertFrom-Json

function Get-Arithmetic($equations, [string]$target) {
    $found = @($equations | Where-Object target -eq $target)
    if ($found.Count -ne 1) { throw "Missing equation for $target." }
    $resize = $found[0].expression
    if ($resize.kind -ne 'assignment_resize' -or $resize.value -ne 'assignment' -or
        $resize.width -ne 16 -or $resize.operands.Count -ne 1) {
        throw "Missing final assignment conversion for $target."
    }
    $resize.operands[0]
}

foreach ($case in @(
    @{ Target = 'unsigned_sum'; Signed = $false },
    @{ Target = 'signed_sum'; Signed = $true },
    @{ Target = 'mixed_sum'; Signed = $false },
    @{ Target = 'based_sum'; Signed = $true }
)) {
    $root = Get-Arithmetic $model.combinational_equations $case.Target
    $inner = $root.operands[0]
    if ($root.kind -ne 'binary' -or $root.value -ne '+' -or $root.width -ne 32 -or
        $root.signed -ne $case.Signed -or $inner.width -ne 32 -or
        $inner.kind -ne 'binary' -or $inner.value -ne '+' -or
        $inner.signed -ne $case.Signed -or
        $inner.source.file -notlike '*/rtl_unsized_decimal_nested_context.sv') {
        throw "Incorrect arithmetic type propagation for $($case.Target)."
    }
}

$mixed = (Get-Arithmetic $model.combinational_equations 'mixed_sum').operands[0]
$zeroExtended = $mixed.operands[0]
$retyped = $zeroExtended.operands[0]
if ($zeroExtended.value -ne 'expression_width' -or $zeroExtended.width -ne 32 -or
    $retyped.value -ne 'expression_type' -or $retyped.width -ne 8 -or
    $retyped.signed -or !$retyped.operands[0].signed) {
    throw 'The mixed signed operand must become unsigned before widening.'
}
$registered = Get-Arithmetic $model.next_state_equations 'registered_sum'
if ($registered.operands[0].width -ne 32) {
    throw 'The nested next-state sum was truncated before assignment.'
}

foreach ($name in @('p_all_unsigned','p_unsigned_carry','p_signed_carry',
                    'p_mixed_zero_extension','p_widen_before_negating',
                    'p_sized_literal_context','p_comparison_context','p_state_carry',
                    'p_decimal_on_other_side','p_shift_context')) {
    $bound = if ($name -eq 'p_state_carry') { 1 } else { 0 }
    $result = @(& $tool --bmc $manifest --property $name --frames $bound)
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $result -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Expected a nonvacuous pass for ${name}:`n$($result -join "`n")"
    }
}
$badShift = @(& $tool --bmc $manifest --property p_false_shift --frames 0)
if ($LASTEXITCODE -ne 0 -or $badShift -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $badShift -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $badShift -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=shifted width=16 value=0x100') {
    throw "Expected a replayed witness for the widened constant shift:`n$($badShift -join "`n")"
}
$failure = @(& $tool --bmc $manifest --property p_deliberately_false --frames 0)
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $failure -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=unsigned_sum width=16 value=0x1ff') {
    throw "Expected the former truncated result to fail independent replay checks:`n$($failure -join "`n")"
}

$bundleParent = (Resolve-Path -LiteralPath (Join-Path $prototypeRoot 'bin')).Path
$bundlePath = Join-Path $bundleParent ('dec-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $published = @(& $tool --bmc $manifest --property p_false_shift --frames 0 --bundle-dir $bundlePath)
    if ($LASTEXITCODE -ne 0 -or $published -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Could not save the nested arithmetic witness.'
    }
    $reopened = @(& $tool --verify-bundle $bundlePath)
    if ($LASTEXITCODE -ne 0 -or $reopened -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The stored arithmetic witness did not replay:`n$($reopened -join "`n")"
    }
} finally {
    if (Test-Path -LiteralPath $bundlePath) {
        $resolved = (Resolve-Path -LiteralPath $bundlePath).Path
        if ([IO.Path]::GetDirectoryName($resolved) -ne $bundleParent -or
            [IO.Path]::GetFileName($resolved) -notmatch '^dec-[a-f0-9]{8}$') {
            throw 'Unexpected decimal test output path.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

'PASS: nested decimal arithmetic propagates width and signedness across assignment and comparison contexts, and replays the 511-value witness.'
