$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'rtl-compound-shift-distance.q3a'

$positive = @(& $tool --bmc $manifest --property p_fixed_distances --frames 0)
if ($LASTEXITCODE -ne 0 -or $positive -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $positive -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "Compound constant distances did not match the explicit bit-slice references:`n$($positive -join "`n")"
}
$counterexample = @(& $tool --bmc $manifest --property p_wrong_distance --frames 0)
if ($LASTEXITCODE -ne 0 -or
    $counterexample -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $counterexample -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "Expected an independently replayed wrong-distance counterexample:`n$($counterexample -join "`n")"
}

foreach ($case in @(
    @{ Property = 'p_dynamic_distance'; Diagnostic = 'compile-time constant shift distances' },
    @{ Property = 'p_negative_distance'; Diagnostic = 'negative constant shift distances' }
)) {
    $result = @(& $tool --bmc $manifest --property $case.Property --frames 0 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        !($result -match ('^Q3A_BITBLAST_ERROR .*rtl_compound_shift_distance\.sv.*' + $case.Diagnostic)) -or
        ($result -match '^Q3A_BMC_STATUS ')) {
        throw "Expected a source-located rejection for $($case.Property):`n$($result -join "`n")"
    }
}

'PASS: all 256 input values satisfy four explicit shift references; false reference replays and dynamic/negative distances reject.'
