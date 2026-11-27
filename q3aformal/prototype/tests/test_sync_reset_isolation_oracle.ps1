$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-sync-reset-isolation.q3a'

$text = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Synchronous reset isolation vector failed to lower:`n$($text -join "`n")"
}
$tir = ($text -join "`n") | ConvertFrom-Json
if ($tir.clocks.Count -ne 1 -or $tir.clocks[0] -ne 'clk' -or
    $tir.next_state_equations.Count -ne 2) {
    throw 'Expected two next-state equations bound to the positive-edge clk.'
}

$nextByTarget = @{}
foreach ($equation in $tir.next_state_equations) {
    $nextByTarget[$equation.target] = $equation
}
foreach ($name in @('reset_q', 'free_q')) {
    if (-not $nextByTarget.ContainsKey($name)) {
        throw "Missing next-state equation for '$name'."
    }
}

$resetEquation = $nextByTarget['reset_q']
$resetExpr = $resetEquation.expression
if ($resetEquation.source.line -ne 8 -or $resetExpr.kind -ne 'conditional' -or
    $resetExpr.source.line -ne 9 -or $resetExpr.operands[0].value -ne 'rst' -or
    $resetExpr.operands[1].kind -ne 'literal' -or $resetExpr.operands[1].value -ne "1'b0" -or
    $resetExpr.operands[1].source.line -ne 10 -or
    $resetExpr.operands[2].value -ne 'data_in' -or $resetExpr.operands[2].source.line -ne 12) {
    throw 'The reset_q T-IR equation or reset/else source locations do not match the RTL.'
}
$freeEquation = $nextByTarget['free_q']
if ($freeEquation.source.line -ne 8 -or $freeEquation.expression.kind -ne 'signal' -or
    $freeEquation.expression.value -ne 'data_in' -or $freeEquation.expression.source.line -ne 14) {
    throw 'The free_q equation must capture data_in without reset gating and preserve its source location.'
}

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' { return [long]$values[$expression.value] }
        'literal' {
            if ($expression.value -notmatch "^\d+'(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
                throw "Unsupported literal '$($expression.value)' in reset oracle."
            }
            $base = switch ($Matches.base.ToLowerInvariant()) {
                'b' { 2 }
                'o' { 8 }
                'd' { 10 }
                'h' { 16 }
            }
            return [long][Convert]::ToInt64($Matches.digits.Replace('_', ''), $base)
        }
        'conditional' {
            if ((Evaluate-Expression $expression.operands[0] $values) -ne 0) {
                return Evaluate-Expression $expression.operands[1] $values
            }
            return Evaluate-Expression $expression.operands[2] $values
        }
        default { throw "Unsupported expression kind '$($expression.kind)' in reset oracle." }
    }
}

$checked = 0
foreach ($oldResetQ in 0..1) {
    foreach ($oldFreeQ in 0..1) {
        foreach ($reset in 0..1) {
            foreach ($data in 0..1) {
                $values = @{ rst = $reset; data_in = $data; reset_q = $oldResetQ; free_q = $oldFreeQ }
                $actualResetQ = Evaluate-Expression $resetEquation.expression $values
                $actualFreeQ = Evaluate-Expression $freeEquation.expression $values
                $expectedResetQ = if ($reset -ne 0) { 0 } else { $data }
                $expectedFreeQ = $data
                if ($actualResetQ -ne $expectedResetQ -or $actualFreeQ -ne $expectedFreeQ) {
                    throw "Transition mismatch for reset=$reset data_in=$data old_reset_q=$oldResetQ old_free_q=$oldFreeQ."
                }
                $checked++
            }
        }
    }
}

$state = @{ reset_q = 1; free_q = 0 }
$frames = @(
    @{ rst = 1; data_in = 1; expected_reset_q = 0; expected_free_q = 1 },
    @{ rst = 1; data_in = 0; expected_reset_q = 0; expected_free_q = 0 },
    @{ rst = 0; data_in = 1; expected_reset_q = 1; expected_free_q = 1 },
    @{ rst = 0; data_in = 0; expected_reset_q = 0; expected_free_q = 0 },
    @{ rst = 1; data_in = 1; expected_reset_q = 0; expected_free_q = 1 },
    @{ rst = 0; data_in = 0; expected_reset_q = 0; expected_free_q = 0 }
)
foreach ($frame in $frames) {
    $values = @{ rst = $frame.rst; data_in = $frame.data_in; reset_q = $state.reset_q; free_q = $state.free_q }
    $nextResetQ = Evaluate-Expression $resetEquation.expression $values
    $nextFreeQ = Evaluate-Expression $freeEquation.expression $values
    if ($nextResetQ -ne $frame.expected_reset_q -or $nextFreeQ -ne $frame.expected_free_q) {
        throw "Frame-sequence mismatch at reset=$($frame.rst), data_in=$($frame.data_in)."
    }
    $state.reset_q = $nextResetQ
    $state.free_q = $nextFreeQ
}

"PASS: $checked old-state/input valuations and six reset-held/released/reasserted frames match the independent oracle; reset source mappings and unreset state behavior are exact."
