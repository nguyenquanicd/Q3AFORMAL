$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'

function Lower-Project([string] $manifest) {
    $output = @(& $executable '--lower-project' $manifest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Case vector failed to lower ($manifest):`n$($output -join "`n")"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

function Convert-IntegerLiteral([string] $text) {
    if ($text -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Unsupported literal in case-order oracle: $text"
    }
    $base = switch ($Matches.base.ToLowerInvariant()) {
        'b' { 2 }
        'o' { 8 }
        'd' { 10 }
        'h' { 16 }
    }
    return [long][Convert]::ToInt64($Matches.digits.Replace('_', ''), $base)
}

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' {
            if (-not $values.ContainsKey($expression.value)) {
                throw "Oracle has no value for signal '$($expression.value)'"
            }
            return [long]$values[$expression.value]
        }
        'literal' { return Convert-IntegerLiteral $expression.value }
        'binary' {
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            switch ($expression.value) {
                '==' { return [long]($left -eq $right) }
                '||' { return [long](($left -ne 0) -or ($right -ne 0)) }
                default { throw "Unsupported binary operator '$($expression.value)'" }
            }
        }
        'conditional' {
            $condition = Evaluate-Expression $expression.operands[0] $values
            if ($condition -ne 0) {
                return Evaluate-Expression $expression.operands[1] $values
            }
            return Evaluate-Expression $expression.operands[2] $values
        }
        default { throw "Unsupported T-IR expression kind '$($expression.kind)'" }
    }
}

function Assert-ExactCaseBranch($expression, [string] $label, [string] $value,
                                [int] $labelLine, [int] $valueLine) {
    if ($expression.kind -ne 'conditional' -or
        $expression.operands[0].kind -ne 'binary' -or
        $expression.operands[0].value -ne '==' -or
        $expression.operands[0].operands[0].value -ne 'select' -or
        $expression.operands[0].operands[1].value -ne $label -or
        $expression.operands[0].source.line -ne $labelLine -or
        $expression.operands[1].kind -ne 'literal' -or
        $expression.operands[1].value -ne $value -or
        $expression.operands[1].source.line -ne $valueLine) {
        throw "Exact case branch $label -> $value or its source map is incorrect."
    }
}

$combinationalManifest = Join-Path $projectRoot 'lower-case-order.q3a'
$combinational = Lower-Project $combinationalManifest
if ($combinational.top_module -ne 'case_order_vectors' -or
    $combinational.clocks.Count -ne 0 -or
    $combinational.next_state_equations.Count -ne 0 -or
    $combinational.combinational_equations.Count -ne 1) {
    throw 'The combinational duplicate-label vector must produce one equation with no state or clock.'
}
$combEquation = $combinational.combinational_equations[0]
if ($combEquation.target -ne 'result' -or $combEquation.source.line -ne 5) {
    throw 'The combinational case equation target or source mapping is incorrect.'
}
$combExpression = $combEquation.expression
if ($combExpression.source.line -ne 6) { throw 'The case statement source line is incorrect.' }
Assert-ExactCaseBranch $combExpression "2'b00" "2'b00" 7 7
Assert-ExactCaseBranch $combExpression.operands[2] "2'b01" "2'b01" 8 8
Assert-ExactCaseBranch $combExpression.operands[2].operands[2] "2'b01" "2'b10" 9 9
$combDefault = $combExpression.operands[2].operands[2].operands[2]
if ($combDefault.kind -ne 'literal' -or $combDefault.value -ne "2'b11" -or
    $combDefault.source.line -ne 10) {
    throw 'The combinational case default or its source mapping is incorrect.'
}

for ($select = 0; $select -lt 4; $select++) {
    $actual = Evaluate-Expression $combExpression @{ select = $select }
    # The duplicate 01 label is deliberately unreachable; the first source arm wins.
    $expected = switch ($select) { 0 { 0 } 1 { 1 } default { 3 } }
    if ($actual -ne $expected) {
        throw "Combinational case mismatch for select=$select`: expected $expected, got $actual."
    }
}

$sequentialManifest = Join-Path $projectRoot 'lower-sequential-case.q3a'
$sequential = Lower-Project $sequentialManifest
if ($sequential.top_module -ne 'sequential_case_vectors' -or
    $sequential.clocks.Count -ne 1 -or $sequential.clocks[0] -ne 'clk' -or
    $sequential.combinational_equations.Count -ne 0 -or
    $sequential.next_state_equations.Count -ne 1) {
    throw 'The sequential case vector must lower to one clocked state equation.'
}
$nextEquation = $sequential.next_state_equations[0]
$nextExpression = $nextEquation.expression
if ($nextEquation.target -ne 'result' -or $nextEquation.source.line -ne 8 -or
    $nextExpression.kind -ne 'conditional' -or $nextExpression.value -ne 'case' -or
    $nextExpression.source.line -ne 9) {
    throw 'The sequential case target, statement kind, or source mapping is incorrect.'
}
$firstArm = $nextExpression.operands[0]
if ($firstArm.kind -ne 'binary' -or $firstArm.value -ne '==' -or
    $firstArm.operands[1].value -ne "2'b00" -or $firstArm.source.line -ne 10 -or
    $nextExpression.operands[1].value -ne 'value_b' -or
    $nextExpression.operands[1].source.line -ne 12) {
    throw 'The first sequential case arm must select the last nonblocking assignment, value_b.'
}
$multiLabelBranch = $nextExpression.operands[2]
if ($multiLabelBranch.kind -ne 'conditional' -or
    $multiLabelBranch.operands[0].kind -ne 'binary' -or
    $multiLabelBranch.operands[0].value -ne '||' -or
    $multiLabelBranch.operands[1].value -ne 'value_a' -or
    $multiLabelBranch.operands[1].source.line -ne 14) {
    throw 'The grouped sequential case labels or value_a branch were not preserved.'
}
$defaultHold = $multiLabelBranch.operands[2]
if ($defaultHold.kind -ne 'signal' -or $defaultHold.value -ne 'result' -or
    $defaultHold.source.line -ne 15) {
    throw 'The sequential case default must preserve the implicit state hold and source mapping.'
}

$checked = 0
for ($select = 0; $select -lt 4; $select++) {
    for ($valueA = 0; $valueA -le 1; $valueA++) {
        for ($valueB = 0; $valueB -le 1; $valueB++) {
            for ($current = 0; $current -le 1; $current++) {
                $actual = Evaluate-Expression $nextExpression @{
                    select = $select; value_a = $valueA; value_b = $valueB; result = $current
                }
                $expected = if ($select -eq 0) { $valueB }
                    elseif ($select -eq 1 -or $select -eq 2) { $valueA }
                    else { $current }
                if ($actual -ne $expected) {
                    throw "Sequential case mismatch: select=$select value_a=$valueA value_b=$valueB result=$current expected=$expected actual=$actual."
                }
                $checked++
            }
        }
    }
}
if ($checked -ne 32) { throw "Expected 32 sequential transition checks, saw $checked." }

$contextManifest = Join-Path $projectRoot 'lower-case-comparison-context.q3a'
$context = Lower-Project $contextManifest
foreach ($binding in @(
    @{ Target = 'signed_match'; Width = 5; Signed = $true },
    @{ Target = 'mixed_match'; Width = 5; Signed = $false },
    @{ Target = 'widened_sum'; Width = 4; Signed = $false },
    @{ Target = 'fill_match'; Width = 5; Signed = $false },
    @{ Target = 'constant_sum'; Width = 4; Signed = $false }
)) {
    $equation = @($context.combinational_equations | Where-Object target -eq $binding.Target)[0]
    $comparison = $equation.expression.operands[0]
    if ($comparison.kind -ne 'binary' -or $comparison.value -ne '==' -or
        @($comparison.operands | Where-Object {
            $_.width -ne $binding.Width -or $_.signed -ne $binding.Signed
        }).Count -ne 0) {
        throw "Incorrect comparison context for $($binding.Target)."
    }
}

foreach ($query in @(
    @{ Property = 'p_context'; Frames = 0; Status = 'BOUNDED_PASS' },
    @{ Property = 'p_sequential'; Frames = 1; Status = 'BOUNDED_PASS' },
    @{ Property = 'p_wrong'; Frames = 1; Status = 'BOUNDED_FAIL' }
)) {
    $verdict = @(& $executable --bmc $contextManifest --property $query.Property --frames $query.Frames)
    if ($LASTEXITCODE -ne 0 -or $verdict -notcontains "Q3A_BMC_STATUS $($query.Status)" -or
        ($query.Status -eq 'BOUNDED_FAIL' -and $verdict -notcontains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Incorrect case context verdict for $($query.Property):`n$($verdict -join "`n")"
    }
}

'PASS: case source priority, grouped labels, default/hold and sequential updates match independent oracles. Shared width and sign, blocking-value capture, fill sizing, and replay of the mixed-width case were verified.'
