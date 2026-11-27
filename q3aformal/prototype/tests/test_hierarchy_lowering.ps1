$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifests = @('.\hierarchy-named.q3a', '.\hierarchy-positional.q3a', '.\hierarchy-process.q3a', '.\hierarchy-expression.q3a', '.\hierarchy-internal.q3a', '.\hierarchy-sequential.q3a', '.\hierarchy-multiregister.q3a', '.\hierarchy-multiple-instances.q3a', '.\hierarchy-nested.q3a', '.\hierarchy-nested-state.q3a', '.\parameterized-hierarchy.q3a', '.\parameterized-hierarchy-width3.q3a', '.\parameterized-hierarchy-positional.q3a', '.\parameterized-hierarchy-default.q3a')

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' { return [long]$values[$expression.value] }
        'literal' {
            if ($expression.value -notmatch "^\d+'(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
                throw "Unsupported literal '$($expression.value)' in hierarchy oracle"
            }
            $base = switch ($Matches.base.ToLowerInvariant()) {
                'b' { 2 }
                'o' { 8 }
                'd' { 10 }
                'h' { 16 }
            }
            return [long][Convert]::ToInt64($Matches.digits.Replace('_', ''), $base)
        }
        'unary' {
            $operand = Evaluate-Expression $expression.operands[0] $values
            if ($expression.value -eq '!') { return [long]($operand -eq 0) }
            throw "Unsupported unary operator '$($expression.value)' in hierarchy oracle"
        }
        'conditional' {
            $condition = Evaluate-Expression $expression.operands[0] $values
            if ($condition -ne 0) {
                return Evaluate-Expression $expression.operands[1] $values
            }
            return Evaluate-Expression $expression.operands[2] $values
        }
        'binary' {
            if ($expression.value -notin @('==', '^')) {
                throw "Unsupported operator '$($expression.value)' in hierarchy oracle"
            }
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            if ($expression.value -eq '^') { return [long]($left -bxor $right) }
            return [long]($left -eq $right)
        }
        default { throw "Unsupported expression kind '$($expression.kind)' in hierarchy oracle" }
    }
}

foreach ($manifestName in $manifests) {
    $manifest = Join-Path $projectRoot $manifestName
    $text = & $executable --lower-project $manifest
    if ($LASTEXITCODE -ne 0) {
        throw "Hierarchy manifest should lower: $manifestName`n$($text -join "`n")"
    }
    $tir = ($text -join "`n") | ConvertFrom-Json
    $visibleSignalNames = @($tir.signals | ForEach-Object { $_.name })
    if ($manifestName -like '.\parameterized-hierarchy*.q3a') {
        $expectedWidth = switch ($manifestName) {
            '.\parameterized-hierarchy-width3.q3a' { 3 }
            '.\parameterized-hierarchy-default.q3a' { 2 }
            default { 4 }
        }
        $dataIn = @($tir.signals | Where-Object { $_.name -eq 'data_in' })[0]
        $dataOut = @($tir.signals | Where-Object { $_.name -eq 'data_out' })[0]
        $middle = @($tir.signals | Where-Object { $_.name -eq 'u_leaf.data_mid' })[0]
        if ($null -eq $dataIn -or $null -eq $dataOut -or $null -eq $middle -or
            $dataIn.width -ne $expectedWidth -or $dataOut.width -ne $expectedWidth -or
            $middle.width -ne $expectedWidth) {
            throw "Parameterized hierarchy widths did not resolve to $expectedWidth bits for $manifestName"
        }
        $equationByTarget = @{}
        foreach ($equation in $tir.combinational_equations) {
            $equationByTarget[$equation.target] = $equation.expression
        }
        if (-not $equationByTarget.ContainsKey('u_leaf.data_mid') -or
            -not $equationByTarget.ContainsKey('data_out')) {
            throw "Parameterized hierarchy is missing the expected passthrough equations for $manifestName"
        }
        $constantNames = @($tir.parameters | ForEach-Object { $_.name })
        if ($manifestName -eq '.\parameterized-hierarchy-default.q3a') {
            $requiredConstants = @('u_leaf.WIDTH', 'u_leaf.DATA_WIDTH', 'u_leaf.u_passthrough.WIDTH')
        } else {
            $requiredConstants = @('WIDTH', 'u_leaf.WIDTH', 'u_leaf.DATA_WIDTH', 'u_leaf.u_passthrough.WIDTH')
        }
        foreach ($constantName in $requiredConstants) {
            $constant = @($tir.parameters | Where-Object { $_.name -eq $constantName })[0]
            if ($null -eq $constant -or $constant.value -ne $expectedWidth) {
                throw "Missing or incorrect hierarchical parameter '$constantName' in $manifestName"
            }
        }
        foreach ($inputValue in 0..(([long]1 -shl $expectedWidth) - 1)) {
            $intermediate = Evaluate-Expression $equationByTarget['u_leaf.data_mid'] @{ data_in = $inputValue }
            $output = Evaluate-Expression $equationByTarget['data_out'] @{ 'u_leaf.data_mid' = $intermediate }
            if ($intermediate -ne $inputValue -or $output -ne $inputValue) {
                throw "Parameterized hierarchy passthrough mismatch for width=$expectedWidth value=$inputValue"
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-nested.q3a') {
        $internalSignal = @($tir.signals | Where-Object { $_.name -eq 'u_middle.u_compare.xor_value' })[0]
        $sameEquation = @($tir.combinational_equations | Where-Object { $_.target -eq 'same' })[0]
        if ($null -eq $internalSignal -or $internalSignal.role -ne 'internal' -or
            $null -eq $sameEquation -or $tir.combinational_equations.Count -ne 2) {
            throw 'Nested leaf logic must flatten with a full instance path and drive the top output'
        }
        $values = @{}
        foreach ($lhs in 0..15) {
            foreach ($rhs in 0..15) {
                $values['lhs'] = $lhs
                $values['rhs'] = $rhs
                foreach ($equation in $tir.combinational_equations) {
                    $values[$equation.target] = Evaluate-Expression $equation.expression $values
                }
                $expected = [long]($lhs -eq $rhs)
                if ($values.same -ne $expected) {
                    throw "Nested hierarchy mismatch for lhs=$lhs rhs=$rhs"
                }
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-nested-state.q3a') {
        $stateName = 'u_middle.u_toggle.value_q'
        $stateSignal = @($tir.signals | Where-Object { $_.name -eq $stateName })[0]
        $transitionEquation = @($tir.next_state_equations | Where-Object { $_.target -eq $stateName })[0]
        $outputEquation = @($tir.combinational_equations | Where-Object { $_.target -eq 'value' })[0]
        if ($null -eq $stateSignal -or $stateSignal.role -ne 'state' -or
            $null -eq $transitionEquation -or $tir.clocks -notcontains 'clk' -or
            $null -eq $outputEquation -or $outputEquation.expression.value -ne $stateName) {
            throw 'Nested child state must retain its full path, bind to the top clock, and drive its connected output'
        }
        foreach ($oldState in 0..1) {
            foreach ($reset in 0..1) {
                foreach ($enable in 0..1) {
                    $values = @{ clk = 0; rst = $reset; enable = $enable }
                    $values[$stateName] = $oldState
                    $actual = Evaluate-Expression $transitionEquation.expression $values
                    $expected = if ($reset -ne 0) { 0 } elseif ($enable -ne 0) { 1 - $oldState } else { $oldState }
                    if ($actual -ne $expected) {
                        throw "Nested child state mismatch for q=$oldState rst=$reset enable=$enable"
                    }
                }
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-multiple-instances.q3a') {
        $stateNames = @('u_left.value_q', 'u_right.value_q')
        if ($tir.clocks -notcontains 'clk' -or $tir.next_state_equations.Count -ne 2) {
            throw 'Expected two independent child state equations on the shared top clock'
        }
        $nextByTarget = @{}
        foreach ($equation in $tir.next_state_equations) {
            $nextByTarget[$equation.target] = $equation.expression
        }
        foreach ($stateName in $stateNames) {
            $signal = @($tir.signals | Where-Object { $_.name -eq $stateName })[0]
            if ($null -eq $signal -or $signal.role -ne 'state' -or
                -not $nextByTarget.ContainsKey($stateName)) {
                throw "Missing or misclassified instance state '$stateName'"
            }
        }
        $outputTargets = @($tir.combinational_equations | ForEach-Object { $_.target })
        if ($outputTargets -notcontains 'left_value' -or
            $outputTargets -notcontains 'right_value') {
            throw 'Expected both child outputs to drive distinct top-level outputs'
        }
        foreach ($oldLeft in 0..1) {
            foreach ($oldRight in 0..1) {
                foreach ($reset in 0..1) {
                    foreach ($enable in 0..1) {
                        $values = @{ clk = 0; rst = $reset; enable = $enable }
                        $values['u_left.value_q'] = $oldLeft
                        $values['u_right.value_q'] = $oldRight
                        $actualLeft = Evaluate-Expression $nextByTarget['u_left.value_q'] $values
                        $actualRight = Evaluate-Expression $nextByTarget['u_right.value_q'] $values
                        $expectedLeft = if ($reset -ne 0) { 0 } elseif ($enable -ne 0) { 1 - $oldLeft } else { $oldLeft }
                        $expectedRight = if ($reset -ne 0) { 0 } elseif ($enable -ne 0) { 1 - $oldRight } else { $oldRight }
                        if ($actualLeft -ne $expectedLeft -or $actualRight -ne $expectedRight) {
                            throw "Instance state isolation mismatch for left=$oldLeft right=$oldRight rst=$reset enable=$enable"
                        }
                    }
                }
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-multiregister.q3a') {
        $stateNames = @('u_pair.a_q', 'u_pair.b_q')
        foreach ($stateName in $stateNames) {
            $state = @($tir.signals | Where-Object { $_.name -eq $stateName })[0]
            if ($null -eq $state -or $state.role -ne 'state' -or $state.width -ne 1) {
                throw "Expected one-bit child state '$stateName'"
            }
        }
        if ($tir.clocks -notcontains 'clk' -or $tir.next_state_equations.Count -ne 2) {
            throw 'Expected two child next-state equations bound to top-level clk'
        }
        $nextByTarget = @{}
        foreach ($equation in $tir.next_state_equations) {
            $nextByTarget[$equation.target] = $equation.expression
        }
        foreach ($target in $stateNames) {
            if (-not $nextByTarget.ContainsKey($target)) {
                throw "Missing next-state equation for '$target'"
            }
        }
        foreach ($oldA in 0..1) {
            foreach ($oldB in 0..1) {
                foreach ($reset in 0..1) {
                    foreach ($newA in 0..1) {
                        $values = @{ clk = 0; rst = $reset; new_a = $newA }
                        $values['u_pair.a_q'] = $oldA
                        $values['u_pair.b_q'] = $oldB
                        $actualA = Evaluate-Expression $nextByTarget['u_pair.a_q'] $values
                        $actualB = Evaluate-Expression $nextByTarget['u_pair.b_q'] $values
                        $expectedA = if ($reset -ne 0) { 0 } else { $newA }
                        $expectedB = if ($reset -ne 0) { 0 } else { $oldA }
                        if ($actualA -ne $expectedA -or $actualB -ne $expectedB) {
                            throw "Simultaneous child-state mismatch for a=$oldA b=$oldB rst=$reset new_a=$newA"
                        }
                    }
                }
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-sequential.q3a') {
        $stateSignal = @($tir.signals | Where-Object { $_.name -eq 'u_toggle.value_q' })[0]
        if ($null -eq $stateSignal -or $stateSignal.role -ne 'state' -or
            $stateSignal.width -ne 1 -or $tir.clocks -notcontains 'clk') {
            throw 'Child sequential state must be named hierarchically and bind to the parent clock'
        }
        if ($tir.next_state_equations.Count -ne 1 -or
            $tir.next_state_equations[0].target -ne 'u_toggle.value_q') {
            throw 'Expected one child-state transition equation'
        }
        $outputEquation = @($tir.combinational_equations | Where-Object { $_.target -eq 'value' })[0]
        if ($null -eq $outputEquation -or
            $outputEquation.expression.value -ne 'u_toggle.value_q') {
            throw 'Child output must be driven from the hierarchical child state'
        }
        $transition = $tir.next_state_equations[0].expression
        foreach ($oldState in 0..1) {
            foreach ($reset in 0..1) {
                foreach ($enable in 0..1) {
                    $values = @{ clk = 0; rst = $reset; enable = $enable }
                    $values['u_toggle.value_q'] = $oldState
                    $actual = Evaluate-Expression $transition $values
                    $expected = if ($reset -ne 0) { 0 } elseif ($enable -ne 0) { 1 - $oldState } else { $oldState }
                    if ($actual -ne $expected) {
                        throw "Child next-state mismatch for q=$oldState rst=$reset enable=$enable"
                    }
                }
            }
        }
        continue
    }
    if ($manifestName -eq '.\hierarchy-internal.q3a') {
        $requiredSignals = @('lhs', 'rhs', 'same', 'u_compare.xor_value')
        foreach ($requiredSignal in $requiredSignals) {
            if ($visibleSignalNames -notcontains $requiredSignal) {
                throw "Flattened TIR is missing hierarchical signal '$requiredSignal'"
            }
        }
        $internalSignal = @($tir.signals | Where-Object { $_.name -eq 'u_compare.xor_value' })[0]
        if ($internalSignal.role -ne 'internal' -or $internalSignal.width -ne 4) {
            throw 'Child local signal must retain its hierarchical name, internal role, and four-bit width'
        }
        $targets = @($tir.combinational_equations | ForEach-Object { $_.target })
        if ($tir.combinational_equations.Count -ne 2 -or
            $targets -notcontains 'u_compare.xor_value' -or
            $targets -notcontains 'same') {
            throw 'Expected flattened child-local XOR and parent output equations'
        }
        foreach ($sample in @(@{ lhs = 10; rhs = 10 }, @{ lhs = 10; rhs = 11 },
                               @{ lhs = 6; rhs = 7 }, @{ lhs = 3; rhs = 2 })) {
            $values = @{ lhs = $sample.lhs; rhs = $sample.rhs }
            foreach ($equation in $tir.combinational_equations) {
                $values[$equation.target] = Evaluate-Expression $equation.expression $values
            }
            $expected = [long]((($sample.lhs -bxor $sample.rhs) -eq 0))
            if ($values.same -ne $expected) {
                throw "Internal child network mismatch for lhs=$($sample.lhs), rhs=$($sample.rhs)"
            }
        }
        continue
    }
    if (($visibleSignalNames -join ',') -ne 'lhs,rhs,same') {
        throw "Flattened TIR should preserve only top-level signal names: $($visibleSignalNames -join ',')"
    }
    if ($tir.combinational_equations.Count -ne 1 -or
        $tir.combinational_equations[0].target -ne 'same') {
        throw 'Expected one flattened equation driving the top-level same output'
    }

    $expression = $tir.combinational_equations[0].expression
    if ($manifestName -eq '.\hierarchy-expression.q3a') {
        if ($expression.kind -ne 'binary' -or $expression.value -ne '==' -or
            $expression.operands[0].kind -ne 'binary' -or
            $expression.operands[0].value -ne '^' -or
            $expression.operands[0].operands[0].value -ne 'lhs' -or
            $expression.operands[0].operands[1].value -ne 'rhs' -or
            $expression.operands[1].value -ne 'rhs') {
            throw 'Expression-valued child input port was not substituted into the flattened relation'
        }
    } elseif ($manifestName -eq '.\hierarchy-process.q3a') {
        if ($expression.kind -ne 'conditional' -or
            $expression.operands[0].kind -ne 'binary' -or
            $expression.operands[0].value -ne '==' -or
            $expression.operands[0].operands[0].value -ne 'lhs' -or
            $expression.operands[0].operands[1].value -ne 'rhs') {
            throw 'Child always_comb ports were not substituted into the flattened conditional equation'
        }
    } elseif ($expression.kind -ne 'binary' -or $expression.value -ne '==' -or
        $expression.operands[0].value -ne 'lhs' -or
        $expression.operands[1].value -ne 'rhs') {
        throw 'Child continuous-assignment port aliases were not substituted into the flattened equality expression'
    }

    foreach ($sample in @(@{ lhs = 10; rhs = 10; expected = 1 },
                           @{ lhs = 10; rhs = 11; expected = 0 },
                           @{ lhs = 6; rhs = 6; expected = 1 },
                           @{ lhs = 6; rhs = 7; expected = 0 },
                           @{ lhs = 0; rhs = 0; expected = 1 },
                           @{ lhs = 3; rhs = 2; expected = 0 })) {
        $actual = Evaluate-Expression $expression @{ lhs = $sample.lhs; rhs = $sample.rhs }
        if ($manifestName -eq '.\hierarchy-expression.q3a') {
            $sample.expected = [long]((($sample.lhs -bxor $sample.rhs) -eq $sample.rhs))
        }
        if ($actual -ne $sample.expected) {
            throw "Independent equality oracle failed for $manifestName"
        }
    }
}

$missingTopManifest = Join-Path $projectRoot 'hierarchy-missing-top.q3a'
$missingTopOutput = @(& $executable '--elaborate-project' $missingTopManifest 2>&1)
$missingTopText = $missingTopOutput -join "`n"
if ($LASTEXITCODE -ne 1 -or
    $missingTopText -notmatch 'hierarchy_vectors\.sv:1:1: top module ''hierarchy_missing_top'' was not found in the source set') {
    throw "A nonexistent top must fail elaboration with a source-located diagnostic:`n$missingTopText"
}

$negativeElaborationCases = @(
    @{ Manifest = 'hierarchy-width-mismatch.q3a';
       SourceFile = 'negative-vectors/port_width_mismatch_reject.sv';
       Pattern = "port 'data_in' connects actual expression 'narrow_data' width 4 to formal width 8" },
    @{ Manifest = 'hierarchy-invalid-port.q3a';
       SourceFile = 'negative-vectors/invalid_named_port_reject.sv';
       Pattern = "instance 'u_compare' references unknown port 'invalid_port'" },
    @{ Manifest = 'unresolved-module.q3a';
       SourceFile = 'negative-vectors/unresolved_module_reject.sv';
       Pattern = "instance references unresolved module 'phase0_missing_child'" },
    @{ Manifest = 'recursive-instance.q3a';
       SourceFile = 'negative-vectors/recursive_instance_reject.sv';
       Pattern = "recursive module instantiation detected at instance 'u_recurse'" }
)
foreach ($case in $negativeElaborationCases) {
    $negativeManifest = Join-Path $projectRoot $case.Manifest
    $negativeOutput = @(& $executable '--elaborate-project' $negativeManifest 2>&1)
    $negativeText = $negativeOutput -join "`n"
    $sourceLocationPattern = [regex]::Escape($case.SourceFile) + ':\d+:\d+:'
    if ($LASTEXITCODE -ne 1 -or
        $negativeText -notmatch [regex]::Escape($case.Pattern) -or
        $negativeText -notmatch $sourceLocationPattern) {
        throw "Expected hierarchy rejection and source location did not match for $($case.Manifest):`n$negativeText"
    }
}

'PASS: positive named/positional and parameterized hierarchy lowers as expected; missing tops, invalid ports, width mismatches, unresolved modules, and recursive instances fail during elaboration with source-located diagnostics.'
