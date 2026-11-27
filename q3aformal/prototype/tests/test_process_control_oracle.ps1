$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-process-control.q3a'
$tirLines = @(& $executable '--lower-project' $manifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Process-control RTL failed to lower:`n$($tirLines -join "`n")"
}
$tir = ($tirLines -join "`n") | ConvertFrom-Json

function Convert-IntegerLiteral([string] $text) {
    if ($text -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Unsupported literal in process-control oracle: $text"
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
            if ($expression.value -ne '==') {
                throw "Unexpected operator in process-control T-IR: $($expression.value)"
            }
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            return [long]($left -eq $right)
        }
        'conditional' {
            if ($expression.value -ne 'if') {
                throw "Unexpected conditional node value '$($expression.value)'"
            }
            $condition = Evaluate-Expression $expression.operands[0] $values
            if ($condition -ne 0) {
                return Evaluate-Expression $expression.operands[1] $values
            }
            return Evaluate-Expression $expression.operands[2] $values
        }
        default { throw "Unexpected expression kind '$($expression.kind)'" }
    }
}

if ($tir.top_module -ne 'rtl_process_control_vectors' -or
    $tir.clocks.Count -ne 0 -or $tir.next_state_equations.Count -ne 0 -or
    $tir.combinational_equations.Count -ne 2) {
    throw 'The vector must lower to two combinational equations and no state or clock.'
}
$equations = @{}
foreach ($equation in $tir.combinational_equations) {
    $equations[$equation.target] = $equation
}
foreach ($target in @('priority_y', 'case_y')) {
    if (-not $equations.ContainsKey($target)) {
        throw "Expected combinational equation '$target' is missing."
    }
}

$priority = $equations['priority_y'].expression
$selectA = $priority.operands[1]
$selectB = $selectA.operands[2]
if ($priority.kind -ne 'conditional' -or $priority.source.line -ne 14 -or
    $priority.operands[0].value -ne 'enable' -or
    $selectA.kind -ne 'conditional' -or $selectA.source.line -ne 15 -or
    $selectA.operands[0].value -ne 'select_a' -or
    $selectA.operands[1].value -ne 'data_a' -or
    $selectA.operands[1].source.line -ne 5 -or
    $selectB.kind -ne 'conditional' -or $selectB.source.line -ne 17 -or
    $selectB.operands[0].value -ne 'select_b' -or
    $selectB.operands[1].value -ne 'data_b' -or
    $selectB.operands[1].source.line -ne 6 -or
    $selectB.operands[2].value -ne 'data_c' -or
    $selectB.operands[2].source.line -ne 7 -or
    $priority.operands[2].value -ne "4'h0" -or
    $priority.operands[2].source.line -ne 23 -or
    $equations['priority_y'].source.line -ne 12) {
    throw 'The lowered nested if/else priority mux, branch order, or per-branch source mapping differs from the reviewed RTL.'
}

$case = $equations['case_y'].expression
$caseValues = @("2'b00", "2'b01", "2'b10")
$expectedCaseLiterals = @("4'h1", "4'h2", "4'h4")
$current = $case
for ($index = 0; $index -lt 3; $index++) {
    if ($current.kind -ne 'conditional' -or
        $current.operands[0].kind -ne 'binary' -or
        $current.operands[0].value -ne '==' -or
        $current.operands[0].operands[0].value -ne 'op' -or
        $current.operands[0].operands[1].value -ne $caseValues[$index] -or
        $current.operands[1].value -ne $expectedCaseLiterals[$index]) {
        throw "Exact-case T-IR branch $index does not match the source item order or label."
    }
    $current = $current.operands[2]
}
if ($current.kind -ne 'literal' -or $current.value -ne "4'hF" -or
    $equations['case_y'].source.line -ne 27) {
    throw 'The exact-case default result or source mapping is incorrect.'
}

$checked = 0
for ($enable = 0; $enable -le 1; $enable++) {
    for ($selectA = 0; $selectA -le 1; $selectA++) {
        for ($selectB = 0; $selectB -le 1; $selectB++) {
            for ($dataA = 0; $dataA -lt 16; $dataA++) {
                for ($dataB = 0; $dataB -lt 16; $dataB++) {
                    for ($dataC = 0; $dataC -lt 16; $dataC++) {
                        for ($op = 0; $op -lt 4; $op++) {
                            $values = @{
                                enable = $enable; select_a = $selectA; select_b = $selectB
                                data_a = $dataA; data_b = $dataB; data_c = $dataC; op = $op
                            }
                            $expectedPriority = if (-not $enable) { 0 }
                                elseif ($selectA) { $dataA }
                                elseif ($selectB) { $dataB }
                                else { $dataC }
                            $expectedCase = switch ($op) {
                                0 { 1 }
                                1 { 2 }
                                2 { 4 }
                                default { 15 }
                            }
                            $actualPriority = Evaluate-Expression $priority $values
                            $actualCase = Evaluate-Expression $case $values
                            if ($actualPriority -ne $expectedPriority -or
                                $actualCase -ne $expectedCase) {
                                throw "Process-control mismatch: enable=$enable select_a=$selectA select_b=$selectB data=($dataA,$dataB,$dataC) op=$op"
                            }
                            $checked++
                        }
                    }
                }
            }
        }
    }
}
if ($checked -ne 131072) {
    throw "Expected 131072 source-model comparisons, checked $checked."
}

$latchManifest = Join-Path $projectRoot 'lower-latch-reject.q3a'
$latchOutput = @(& $executable '--lower-project' $latchManifest 2>&1)
$latchText = $latchOutput -join "`n"
if ($LASTEXITCODE -ne 1 -or
    $latchText -notmatch 'latch_inference_reject\.sv:6:5: always_comb signal ''data_out'' is not assigned on every control path; latch semantics are unsupported') {
    throw "Incomplete always_comb assignment must fail before T-IR output with the source-located latch diagnostic:`n$latchText"
}

$packedManifest = Join-Path $projectRoot 'lower-packed-if-condition.q3a'
$packedText = @(& $executable --lower-project $packedManifest)
if ($LASTEXITCODE -ne 0) {
    throw "Could not lower the packed if conditions:`n$($packedText -join "`n")"
}
$packed = ($packedText -join "`n") | ConvertFrom-Json
$combTest = ($packed.combinational_equations | Where-Object target -eq 'selected').expression.operands[0]
$resetTest = ($packed.next_state_equations | Where-Object target -eq 'captured').expression.operands[0]
foreach ($condition in @(
    @{ Expression = $combTest; Width = 3; SourceLine = 9 },
    @{ Expression = $resetTest; Width = 64; SourceLine = 16 }
)) {
    $expr = $condition.Expression
    if ($expr.kind -ne 'binary' -or $expr.value -ne '!=' -or $expr.width -ne 1 -or
        $expr.source.line -ne $condition.SourceLine -or
        $expr.operands[0].width -ne $condition.Width -or $expr.operands[1].width -ne $condition.Width) {
        throw "Packed predicate does not test its full source width at line $($condition.SourceLine)."
    }
}
foreach ($query in @(
    @{ Property = 'p_wrap'; Frames = 0; Status = 'BOUNDED_PASS' },
    @{ Property = 'p_capture'; Frames = 1; Status = 'BOUNDED_PASS' },
    @{ Property = 'p_wrong'; Frames = 1; Status = 'BOUNDED_FAIL' }
)) {
    $output = @(& $executable --bmc $packedManifest --property $query.Property --frames $query.Frames)
    if ($LASTEXITCODE -ne 0 -or $output -notcontains "Q3A_BMC_STATUS $($query.Status)" -or
        ($query.Status -eq 'BOUNDED_FAIL' -and $output -notcontains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Incorrect packed-if result for $($query.Property):`n$($output -join "`n")"
    }
}

"PASS: $checked input combinations, complete-assignment rejection, packed if truth values, synchronous update, and replay of a high-bit reset counterexample."
