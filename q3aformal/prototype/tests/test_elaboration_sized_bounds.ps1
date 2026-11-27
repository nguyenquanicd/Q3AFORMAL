$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-elaboration-sized-bounds.q3a'

$lowered = @(& $tool --lower-project $manifest)
if ($LASTEXITCODE -ne 0) {
    throw "Packed declarations did not lower:`n$($lowered -join "`n")"
}
$model = ($lowered -join "`n") | ConvertFrom-Json
foreach ($name in @('lane', 'small', 'g_expected.u_generated.g_lane[0].inner',
                    'g_decimal.u_generated.g_lane[0].inner')) {
    $signal = @($model.signals | Where-Object name -EQ $name)
    if ($signal.Count -ne 1 -or $signal[0].width -ne 3) {
        throw "Packed signal $name has the wrong width."
    }
}
if (@($model.signals | Where-Object name -Match '^g_(wrong|decimal_wrong)\.').Count -ne 0) {
    throw 'An inactive generate branch leaked into the model.'
}
foreach ($name in @('WINDOW', 'LOCAL_MASK')) {
    $constant = @($model.parameters | Where-Object name -EQ $name)
    if ($constant.Count -ne 1 -or $constant[0].width -ne 3 -or $constant[0].value -ne 7) {
        throw "Packed constant $name has the wrong width or fill value."
    }
}
foreach ($decl in @(
    @{ Name = 'MASK'; Value = 0 },
    @{ Name = 'g_scope[0].MASK'; Value = 1 },
    @{ Name = 'g_scope[1].MASK'; Value = 2 },
    @{ Name = 'g_scope[0].CHILD_LAST'; Value = 7 },
    @{ Name = 'g_scope[1].g_active.u_scoped.g_lane[0].ACTIVE_MASK'; Value = 7 }
)) {
    $constant = @($model.parameters | Where-Object name -EQ $decl.Name)
    if ($constant.Count -ne 1 -or $constant[0].width -ne 3 -or
        $constant[0].value -ne $decl.Value -or $constant[0].kind -ne 'localparam') {
        throw "Incorrect generated constant $($decl.Name)."
    }
}

$pass = @(& $tool --bmc $manifest --property p_expected --frames 0)
if ($LASTEXITCODE -ne 0 -or $pass -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $pass -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "The exact-width connections must map the explicitly expected slices:`n$($pass -join "`n")"
}
foreach ($property in @('p_wrong', 'p_wrong_scope')) {
    $failure = @(& $tool --bmc $manifest --property $property --frames 0)
    if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Expected an independently replayed witness for $property.`n$($failure -join "`n")"
    }
}

$mismatch = Join-Path $prototypeRoot 'reject-elaboration-sized-bounds-width.q3a'
$rejected = @(& $tool --lower-project $mismatch 2>&1)
if ($LASTEXITCODE -ne 1 -or
    -not (($rejected -join "`n") -match "u_parameter.*port 'data'.*width 2 to formal width 3")) {
    throw "A parameter override that produces a two-bit slice must fail exact-width binding:`n$($rejected -join "`n")"
}

'PASS: typed bounds, generate controls, and per-iteration local constants agree with explicit child slice references; replay and width rejection pass.'
