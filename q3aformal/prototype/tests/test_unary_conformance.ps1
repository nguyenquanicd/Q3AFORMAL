$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'unary-conformance.q3a'

function Get-TirValue {
    param([Parameter(Mandatory = $true)]$Expression, [Parameter(Mandatory = $true)][hashtable]$Inputs)

    switch ([string]$Expression.kind) {
        'signal' { return [long]$Inputs[[string]$Expression.value] }
        'unary' {
            $operand = Get-TirValue -Expression $Expression.operands[0] -Inputs $Inputs
            switch ([string]$Expression.value) {
                '+' { return $operand }
                '-' { return ((-$operand) -band 0xF) }
                '~' { return ((-bnot $operand) -band 0xF) }
                '!' { if ($operand -eq 0) { return 1L } else { return 0L } }
                default { throw "Unexpected unary operator '$($Expression.value)' in independent oracle." }
            }
        }
        default { throw "Unexpected T-IR expression kind '$($Expression.kind)' in unary oracle." }
    }
}

$lowered = & $executable --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) { throw "Unary source did not lower: $($lowered -join "`n")" }
$model = ($lowered -join "`n") | ConvertFrom-Json
$expected = @{
    unary_plus = @{ operator = '+'; width = 4; sourceLine = 9 }
    unary_minus = @{ operator = '-'; width = 4; sourceLine = 10 }
    bitwise_not = @{ operator = '~'; width = 4; sourceLine = 11 }
    logical_not = @{ operator = '!'; width = 1; sourceLine = 12 }
}
foreach ($target in $expected.Keys) {
    $spec = $expected[$target]
    $equations = @($model.combinational_equations | Where-Object { $_.target -eq $target })
    if ($equations.Count -ne 1 -or [int]$equations[0].target_width -ne $spec.width -or
        [int]$equations[0].source.line -ne $spec.sourceLine -or
        [string]$equations[0].expression.kind -ne 'unary' -or
        [string]$equations[0].expression.value -ne $spec.operator -or
        [string]$equations[0].expression.operands[0].value -ne 'u' -or
        [int]$equations[0].expression.operands[0].width -ne 4) {
        throw "T-IR operator, operand width, result width, or source mapping is wrong for '$target'."
    }

    for ($value = 0; $value -lt 16; $value++) {
        $actual = Get-TirValue -Expression $equations[0].expression -Inputs @{ u = $value }
        $reference = switch ($spec.operator) {
            '+' { $value }
            '-' { (-$value) -band 0xF }
            '~' { (-bnot $value) -band 0xF }
            '!' { if ($value -eq 0) { 1 } else { 0 } }
        }
        if ($actual -ne $reference) {
            throw "Unary oracle mismatch for '$target' at u=0x$('{0:X}' -f $value): expected $reference, got $actual."
        }
    }
}

foreach ($property in @('p_unary_plus', 'p_unary_minus', 'p_bitwise_not', 'p_logical_not')) {
    $output = & $executable --bmc $manifest --property $property --frames 0
    if ($LASTEXITCODE -ne 0 -or
        $output -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $output -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Unary source assertion failed or was vacuous for '$property': $($output -join "`n")"
    }
}

$negative = & $executable --bmc $manifest --property 'p_unary_plus_false' --frames 0
if ($LASTEXITCODE -ne 0 -or
    $negative -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $negative -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "Deliberately false unary assertion did not produce a replay-validated witness: $($negative -join "`n")"
}

'PASS: unary +, -, ~, and ! preserve expected T-IR types/source mapping over all 16 four-bit inputs; four nonvacuous assertions pass and a false assertion replays.'
