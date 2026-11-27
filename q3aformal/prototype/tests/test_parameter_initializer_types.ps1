$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$defaults = Join-Path $prototypeRoot 'rtl-parameter-initializer-types.q3a'
$override = Join-Path $prototypeRoot 'rtl-parameter-initializer-types-override.q3a'

foreach ($case in @(
    @{ Manifest = $defaults; Property = 'p_expected' },
    @{ Manifest = $defaults; Property = 'p_bitwise' },
    @{ Manifest = $defaults; Property = 'p_context' },
    @{ Manifest = $override; Property = 'p_override_expected' }
)) {
    $pass = @(& $tool --bmc $case.Manifest --property $case.Property --frames 0)
    if ($LASTEXITCODE -ne 0 -or $pass -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $pass -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Typed parameter evaluation failed for $($case.Property):`n$($pass -join "`n")"
    }
}
foreach ($property in @('p_wrong', 'p_wrong_context')) {
    $failure = @(& $tool --bmc $defaults --property $property --frames 0)
    if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Expected a replayed counterexample for $property.`n$($failure -join "`n")"
    }
}

'PASS: typed defaults, localparams, overrides, arithmetic, bitwise, comparison, logic, conditional, shift, and fill contexts agree with explicit constants and replay.'
