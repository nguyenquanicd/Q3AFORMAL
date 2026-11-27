$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$cases = @(
    @{ manifest = 'generate-if-enabled-width4.q3a'; enable = 1; width = 4; op = '^'; line = 13; selected = @('generate if path="if@11" selected=1', 'generate if path="g_enabled.if@12" selected=1', 'generate assignment path="g_enabled.g_width_four" selected=1') },
    @{ manifest = 'generate-if-enabled-width3.q3a'; enable = 1; width = 3; op = '&'; line = 15; selected = @('generate if path="if@11" selected=1', 'generate if path="g_enabled.if@12" selected=0', 'generate assignment path="g_enabled.g_width_other" selected=1') },
    @{ manifest = 'generate-if-disabled-width4.q3a'; enable = 0; width = 4; op = '0'; line = 18; selected = @('generate if path="if@11" selected=0', 'generate assignment path="g_disabled" selected=1') },
    @{ manifest = 'generate-if-disabled-width3.q3a'; enable = 0; width = 3; op = '0'; line = 18; selected = @('generate if path="if@11" selected=0', 'generate assignment path="g_disabled" selected=1') }
)

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' { return [long]$values[$expression.value] }
        'literal' {
            if ($expression.value -eq "'0") { return 0L }
            throw "Unexpected generated literal '$($expression.value)'."
        }
        'binary' {
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            switch ($expression.value) {
                '^' { return [long]($left -bxor $right) }
                '&' { return [long]($left -band $right) }
                default { throw "Unexpected generated operator '$($expression.value)'." }
            }
        }
        default { throw "Unexpected expression kind '$($expression.kind)' in generated equation." }
    }
}

$checked = 0
foreach ($case in $cases) {
    $manifest = Join-Path $prototypeRoot $case.manifest
    $lowered = @(& $sourcecheck --lower-project $manifest 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "${($case.manifest)} failed to lower:`n$($lowered -join "`n")" }
    $model = ($lowered -join "`n") | ConvertFrom-Json

    $widthParameter = @($model.parameters | Where-Object { $_.name -eq 'WIDTH' })
    $enableParameter = @($model.parameters | Where-Object { $_.name -eq 'ENABLE' })
    if ($widthParameter.Count -ne 1 -or [int]$widthParameter[0].value -ne $case.width -or
        $enableParameter.Count -ne 1 -or [int]$enableParameter[0].value -ne $case.enable) {
        throw "Resolved parameters differ from the expected configuration for $($case.manifest)."
    }
    $equation = @($model.combinational_equations | Where-Object { $_.target -eq 'y' })
    if ($equation.Count -ne 1 -or [int]$equation[0].target_width -ne $case.width -or
        $equation[0].source.line -ne $case.line -or
        ($case.op -eq '0' -and ($equation[0].expression.kind -ne 'literal' -or $equation[0].expression.value -ne "'0")) -or
        ($case.op -ne '0' -and ($equation[0].expression.kind -ne 'binary' -or $equation[0].expression.value -ne $case.op))) {
        throw "Selected equation, width, or source mapping is wrong for $($case.manifest)."
    }
    if (@($model.properties | Where-Object { $_.name -eq 'p_generated_behavior' -and $_.clock -eq 'clk' }).Count -ne 1) {
        throw "Source-level assertion or clock binding is missing for $($case.manifest)."
    }

    foreach ($a in 0..([int]([Math]::Pow(2, $case.width) - 1))) {
        foreach ($b in 0..([int]([Math]::Pow(2, $case.width) - 1))) {
            $actual = Evaluate-Expression $equation[0].expression @{ a = $a; b = $b }
            $expected = if ($case.enable -eq 0) { 0 } elseif ($case.width -eq 4) { $a -bxor $b } else { $a -band $b }
            if ($actual -ne $expected) {
                throw "Independent generated-branch oracle mismatch: $($case.manifest), a=$a, b=$b, expected=$expected, actual=$actual."
            }
            $checked++
        }
    }

    $elaboration = @(& $sourcecheck --elaborate-project $manifest 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Elaboration failed for $($case.manifest): $($elaboration -join "`n")" }
    foreach ($expectedLine in $case.selected) {
        if ($elaboration -notcontains $expectedLine) {
            throw "Expected generate branch selection '$expectedLine' is absent for $($case.manifest)."
        }
    }

    $proof = @(& $sourcecheck --bmc $manifest --property 'p_generated_behavior' --frames 0 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        $proof -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $proof -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Generated-branch source assertion did not pass nonvacuously for $($case.manifest): $($proof -join "`n")"
    }
}

"PASS: nested static generate-if true/false selection, parameters, source mappings, 640 independent input pairs, and four nonvacuous bounded assertions match the expected behavior."
