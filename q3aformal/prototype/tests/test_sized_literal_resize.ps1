$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'lower-rtl-sized-literal-resize.q3a'
$output = & $sourcecheck --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Sized-literal vector failed to lower:`n$($output -join "`n")"
}
$tir = ($output -join "`n") | ConvertFrom-Json

$equationByTarget = @{}
foreach ($equation in @($tir.combinational_equations) + @($tir.next_state_equations)) {
    if ($equationByTarget.ContainsKey($equation.target)) {
        throw "Duplicate lowered equation for '$($equation.target)'."
    }
    $equationByTarget[$equation.target] = $equation
}

function Get-LiteralInteger($expression) {
    if ($expression.kind -ne 'literal' -or
        $expression.value -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Expected a sized integral literal, got $($expression | ConvertTo-Json -Compress -Depth 5)."
    }
    $base = switch ($Matches.base.ToLowerInvariant()) {
        'b' { 2 }
        'o' { 8 }
        'd' { 10 }
        'h' { 16 }
    }
    $width = [int]$Matches.width
    $raw = [long][Convert]::ToInt64($Matches.digits.Replace('_', ''), $base)
    $sourceMask = [long]([Math]::Pow(2, $width) - 1)
    return @{ value = ($raw -band $sourceMask); width = $width; signed = ($Matches.signed -eq 's') }
}

$expected = @(
    @{ target = 'based_binary'; value = 0x56; width = 8; signed = $false; literal = "8'b0101_0110"; line = 18; expression_line = 18; resized = $false },
    @{ target = 'based_octal'; value = 0x56; width = 8; signed = $false; literal = "8'o126"; line = 19; expression_line = 19; resized = $false },
    @{ target = 'based_decimal'; value = 0x56; width = 8; signed = $false; literal = "8'd86"; line = 20; expression_line = 20; resized = $false },
    @{ target = 'based_hex'; value = 0x56; width = 8; signed = $false; literal = "8'h56"; line = 21; expression_line = 21; resized = $false },
    @{ target = 'based_signed_binary'; value = 0x56; width = 8; signed = $true; literal = "8'sb0101_0110"; line = 22; expression_line = 22; resized = $false },
    @{ target = 'based_signed_octal'; value = 0x56; width = 8; signed = $true; literal = "8'so126"; line = 23; expression_line = 23; resized = $false },
    @{ target = 'based_signed_decimal'; value = 0x56; width = 8; signed = $true; literal = "8'sd86"; line = 24; expression_line = 24; resized = $false },
    @{ target = 'based_signed_hex'; value = 0x56; width = 8; signed = $true; literal = "8'sh56"; line = 25; expression_line = 25; resized = $false },
    @{ target = 'based_signed'; value = 0x56; width = 8; signed = $true; literal = "8'sd86"; line = 26; expression_line = 26; resized = $false },
    @{ target = 'unsigned_zero_extend'; value = 0x0A; width = 8; signed = $false; literal = "4'b1010"; line = 27; expression_line = 27; resized = $true; source_width = 4; source_signed = $false },
    @{ target = 'signed_sign_extend'; value = 0xFE; width = 8; signed = $true; literal = "4'sb1110"; line = 28; expression_line = 28; resized = $true; source_width = 4; source_signed = $true },
    @{ target = 'unsigned_truncate'; value = 0x06; width = 4; signed = $false; literal = "8'hA6"; line = 29; expression_line = 29; resized = $true; source_width = 8; source_signed = $false },
    @{ target = 'unsigned_zero_extend_comb'; value = 0x0A; width = 8; signed = $false; literal = "4'b1010"; line = 31; expression_line = 32; resized = $true; source_width = 4; source_signed = $false },
    @{ target = 'signed_sign_extend_state'; value = 0xFE; width = 8; signed = $true; literal = "4'sb1110"; line = 35; expression_line = 36; resized = $true; source_width = 4; source_signed = $true; state = $true }
)

function Evaluate-LoweredSizedLiteral($equation, $expectation) {
    $expression = $equation.expression
    if ($expectation.resized) {
        if ($expression.kind -ne 'assignment_resize' -or
            $expression.width -ne $expectation.width -or $expression.operands.Count -ne 1) {
            throw "Expected explicit assignment_resize for '$($expectation.target)'."
        }
        $literal = $expression.operands[0]
    } else {
        $literal = $expression
        if ($expression.kind -ne 'literal' -or $expression.width -ne $expectation.width) {
            throw "Expected an exact-width literal for '$($expectation.target)'."
        }
    }

    $decoded = Get-LiteralInteger $literal
    if ($literal.value -ne $expectation.literal -or
        $literal.width -ne $(if ($expectation.resized) { $expectation.source_width } else { $expectation.width }) -or
        $literal.signed -ne $(if ($expectation.resized) { $expectation.source_signed } else { $expectation.signed }) -or
        $equation.target_width -ne $expectation.width -or
        $equation.source.line -ne $expectation.line -or
        $expression.source.line -ne $expectation.expression_line) {
        throw "T-IR literal width, signedness, target width, or source mapping mismatch for '$($expectation.target)'."
    }

    $value = $decoded.value
    if ($expectation.resized -and $expectation.width -gt $decoded.width -and
        $decoded.signed -and (($value -band ([long][Math]::Pow(2, $decoded.width - 1))) -ne 0)) {
        $value = $value -bor ([long][Math]::Pow(2, $expectation.width) - [long][Math]::Pow(2, $decoded.width))
    }
    $targetMask = [long]([Math]::Pow(2, $expectation.width) - 1)
    return ($value -band $targetMask)
}

foreach ($item in $expected) {
    if (-not $equationByTarget.ContainsKey($item.target)) {
        throw "Missing lowered equation for '$($item.target)'."
    }
    $actual = Evaluate-LoweredSizedLiteral $equationByTarget[$item.target] $item
    if ($actual -ne $item.value) {
        throw "Independent literal value mismatch for '$($item.target)': expected $($item.value), got $actual."
    }
}
if ($equationByTarget.Count -ne $expected.Count) {
    throw "Expected $($expected.Count) literal equations, found $($equationByTarget.Count)."
}

$constantProof = @(& $sourcecheck --bmc $manifest --property 'p_sized_literal_constants' --frames 0 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $constantProof -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $constantProof -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "SAT check for sized-literal constants failed:`n$($constantProof -join "`n")"
}
$stateProof = @(& $sourcecheck --bmc $manifest --property 'p_sized_literal_sequential_resize' --frames 1 2>&1)
if ($LASTEXITCODE -ne 0 -or
    $stateProof -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $stateProof -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "SAT check for sequential sized-literal extension failed:`n$($stateProof -join "`n")"
}

'PASS: all 14 sized-literal equations preserve base, signedness, width, resize direction, source mapping, and independent values; SAT checks pass for continuous/combinational outputs and the sequential resized value.'
