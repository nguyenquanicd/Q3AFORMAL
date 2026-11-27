$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-handshake1.q3a'

$tirText = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Handshake transition vector failed to lower: $($tirText -join "`n")"
}
$tir = ($tirText -join "`n") | ConvertFrom-Json

function Convert-IntegerLiteral([string] $text) {
    if ($text -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Unsupported literal in handshake oracle: $text"
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
        'unary' {
            $value = Evaluate-Expression $expression.operands[0] $values
            switch ($expression.value) {
                '!' { return [long]($value -eq 0) }
                '~' { return [long](-bnot $value) }
                default { throw "Unsupported unary operator '$($expression.value)'" }
            }
        }
        'binary' {
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            switch ($expression.value) {
                '&&' { return [long](($left -ne 0) -and ($right -ne 0)) }
                '||' { return [long](($left -ne 0) -or ($right -ne 0)) }
                '==' { return [long]($left -eq $right) }
                '!=' { return [long]($left -ne $right) }
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
        default { throw "Unsupported expression kind '$($expression.kind)'" }
    }
}

$equations = @{}
foreach ($equation in $tir.combinational_equations) {
    $equations[$equation.target] = $equation.expression
}
$nextState = @{}
foreach ($equation in $tir.next_state_equations) {
    $nextState[$equation.target] = $equation.expression
}
foreach ($required in @('in_ready', 'full', 'data_q')) {
    if (($required -eq 'in_ready' -and -not $equations.ContainsKey($required)) -or
        ($required -ne 'in_ready' -and -not $nextState.ContainsKey($required))) {
        throw "Required transition equation '$required' is missing"
    }
}

$checked = 0
foreach ($oldFull in 0..1) {
    foreach ($oldData in 0..15) {
        foreach ($reset in 0..1) {
            foreach ($valid in 0..1) {
                foreach ($ready in 0..1) {
                    foreach ($inputData in 0..15) {
                        $values = @{
                            clk = 0; rst = $reset; in_valid = $valid
                            in_data = $inputData; out_ready = $ready
                            full = $oldFull; data_q = $oldData
                        }
                        foreach ($equation in $tir.combinational_equations) {
                            $values[$equation.target] = Evaluate-Expression $equation.expression $values
                        }

                        # Independent reference equations from the reviewed transition table.
                        $expectedFull = if ($reset -ne 0) { 0 } elseif ($values.in_ready -ne 0) { $valid } else { $oldFull }
                        $expectedData = if ($reset -ne 0) { 0 } elseif ($values.in_ready -ne 0 -and $valid -ne 0) { $inputData } else { $oldData }

                        # Evaluate both next-state equations from the same pre-edge valuation.
                        $actualFull = Evaluate-Expression $nextState.full $values
                        $actualData = Evaluate-Expression $nextState.data_q $values
                        if ($actualFull -ne $expectedFull -or $actualData -ne $expectedData) {
                            throw "Frame mismatch: full=$oldFull data_q=$oldData rst=$reset valid=$valid ready=$ready data=$inputData; expected ($expectedFull,$expectedData), got ($actualFull,$actualData)"
                        }
                        $checked++
                    }
                }
            }
        }
    }
}

"PASS: $checked handshake state/input valuations match the independent reset, hold, and simultaneous-update oracle."
