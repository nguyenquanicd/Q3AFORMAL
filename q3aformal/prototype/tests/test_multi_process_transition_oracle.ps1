$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-multi-process.q3a'

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' { return [long]$values[$expression.value] }
        'literal' {
            if ($expression.value -notmatch "^\d+'(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
                throw "Unsupported literal '$($expression.value)' in multiprocess oracle"
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
            $condition = Evaluate-Expression $expression.operands[0] $values
            if ($condition -ne 0) { return Evaluate-Expression $expression.operands[1] $values }
            return Evaluate-Expression $expression.operands[2] $values
        }
        default { throw "Unsupported expression kind '$($expression.kind)' in multiprocess oracle" }
    }
}

$text = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Multiple-process manifest should lower:`n$($text -join "`n")"
}
$tir = ($text -join "`n") | ConvertFrom-Json
if ($tir.clocks.Count -ne 1 -or $tir.clocks[0] -ne 'clk' -or
    $tir.next_state_equations.Count -ne 2) {
    throw 'Expected two state transitions bound to the same top-level clock'
}
$nextByTarget = @{}
$equationByTarget = @{}
foreach ($equation in $tir.next_state_equations) {
    $nextByTarget[$equation.target] = $equation.expression
    $equationByTarget[$equation.target] = $equation
}
foreach ($stateName in @('a_q', 'b_q')) {
    $state = @($tir.signals | Where-Object { $_.name -eq $stateName })[0]
    if ($null -eq $state -or $state.role -ne 'state' -or
        -not $nextByTarget.ContainsKey($stateName)) {
        throw "Missing state signal or transition equation '$stateName'"
    }
}

foreach ($expected in @(
    @{ target = 'a_q'; process = 8; condition = 9; reset_value = 10; data_value = 12 },
    @{ target = 'b_q'; process = 16; condition = 17; reset_value = 18; data_value = 20 }
)) {
    $equation = $equationByTarget[$expected.target]
    $expression = $equation.expression
    if ($equation.source.line -ne $expected.process -or
        $expression.kind -ne 'conditional' -or $expression.source.line -ne $expected.condition -or
        $expression.operands[0].value -ne 'rst' -or
        $expression.operands[1].kind -ne 'literal' -or $expression.operands[1].value -ne "1'b0" -or
        $expression.operands[1].source.line -ne $expected.reset_value -or
        $expression.operands[2].source.line -ne $expected.data_value) {
        throw "Sequential source mapping for '$($expected.target)' does not match the RTL reset and data branches."
    }
}

foreach ($oldA in 0..1) {
    foreach ($oldB in 0..1) {
        foreach ($reset in 0..1) {
            foreach ($newA in 0..1) {
                $values = @{ clk = 0; rst = $reset; new_a = $newA; a_q = $oldA; b_q = $oldB }
                $actualA = Evaluate-Expression $nextByTarget['a_q'] $values
                $actualB = Evaluate-Expression $nextByTarget['b_q'] $values
                $expectedA = if ($reset -ne 0) { 0 } else { $newA }
                $expectedB = if ($reset -ne 0) { 0 } else { $oldA }
                if ($actualA -ne $expectedA -or $actualB -ne $expectedB) {
                    throw "Independent-process transition mismatch for a=$oldA b=$oldB rst=$reset new_a=$newA"
                }
            }
        }
    }
}

$blockingManifest = Join-Path $projectRoot 'reject-blocking-sequential.q3a'
$blockingText = & $executable --lower-project $blockingManifest 2>&1
$blockingExit = $LASTEXITCODE
$blockingDiagnostic = $blockingText -join "`n"
if ($blockingExit -eq 0 -or
    $blockingDiagnostic -notmatch 'blocking_sequential_reject\.sv:7:9: always_ff assignments must use nonblocking') {
    throw "Blocking assignment must reject at its source location; exit=$blockingExit; output=$blockingDiagnostic"
}

'PASS: both always_ff processes share clk and match all 16 simultaneous pre-edge transition cases; reset/assignment source mappings are exact and blocking assignment rejects at line 7.'
