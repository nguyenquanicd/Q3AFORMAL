$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-packed-type-boundaries.q3a'

$serialized = & $sourcecheck --lower-project $manifest
if ($LASTEXITCODE -ne 0) { throw 'Packed type fixture failed to lower.' }
$model = ($serialized -join "`n") | ConvertFrom-Json
foreach ($case in @(
    @{ Input = 'narrow_in'; Output = 'narrow_out'; Width = 1; Signed = $true; Line = 10 },
    @{ Input = 'signed_in'; Output = 'signed_out'; Width = 64; Signed = $true; Line = 11 },
    @{ Input = 'unsigned_in'; Output = 'unsigned_out'; Width = 64; Signed = $false; Line = 12 }
)) {
    $inputSignal = $model.signals | Where-Object { $_.name -eq $case.Input }
    $outputSignal = $model.signals | Where-Object { $_.name -eq $case.Output }
    $equation = $model.combinational_equations | Where-Object { $_.target -eq $case.Output }
    if ($inputSignal.role -ne 'input' -or $outputSignal.role -ne 'output' -or
        $inputSignal.width -ne $case.Width -or $outputSignal.width -ne $case.Width -or
        $inputSignal.signed -ne $case.Signed -or $outputSignal.signed -ne $case.Signed -or
        $equation.target_width -ne $case.Width -or $equation.source.line -ne $case.Line -or
        $equation.expression.kind -ne 'signal' -or $equation.expression.value -ne $case.Input -or
        $equation.expression.width -ne $case.Width -or $equation.expression.signed -ne $case.Signed) {
        throw "Incorrect packed type or source mapping for $($case.Output)."
    }
}

foreach ($name in @('p_narrow_copy', 'p_signed_msb', 'p_unsigned_msb',
                    'p_signed_negative', 'p_unsigned_nonnegative')) {
    $outputLines = @(& $sourcecheck --bmc $manifest --property $name --frames 0)
    if ($LASTEXITCODE -ne 0 -or
        $outputLines -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $outputLines -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Expected nonvacuous bounded pass for ${name}:`n$($outputLines -join "`n")"
    }
}

$negative = @(& $sourcecheck --bmc $manifest --property p_false_signed_nonnegative --frames 0)
$negativeExit = $LASTEXITCODE
$negativeWord = @($negative | Where-Object {
    $_ -match '^Q3A_BMC_TRACE_SIGNAL frame=0 name=signed_out width=64 value=0x[89a-f][0-9a-f]{15}$'
})
if ($negativeExit -ne 0 -or
    $negative -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $negative -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or $negativeWord.Count -ne 1) {
    throw "Expected a replayed negative 64-bit witness:`n$($negative -join "`n")"
}

'PASS: 1-bit and 64-bit packed logic/bit types preserve widths, signedness and opposite range directions. Five properties pass and one negative 64-bit witness replays.'
