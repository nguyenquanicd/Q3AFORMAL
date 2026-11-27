$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-casez.q3a'

$tirText = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "casez vector failed to lower: $($tirText -join "`n")"
}
$tir = ($tirText -join "`n") | ConvertFrom-Json
$equation = @($tir.combinational_equations | Where-Object { $_.target -eq 'code' })[0]
if ($null -eq $equation) { throw 'The casez output equation is missing' }

function Convert-IntegerLiteral([string] $text) {
    if ($text -match '^\d+$') { return [long]::Parse($text) }
    if ($text -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Unsupported literal in casez oracle: $text"
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
        'signal' { return [long]$values[$expression.value] }
        'literal' { return Convert-IntegerLiteral $expression.value }
        'casez_match' {
            $selector = Evaluate-Expression $expression.operands[0] $values
            $pattern = Evaluate-Expression $expression.operands[1] $values
            $mask = Evaluate-Expression $expression.operands[2] $values
            return [long](($selector -band $mask) -eq ($pattern -band $mask))
        }
        'binary' {
            $left = Evaluate-Expression $expression.operands[0] $values
            $right = Evaluate-Expression $expression.operands[1] $values
            switch ($expression.value) {
                '||' { return [long](($left -ne 0) -or ($right -ne 0)) }
                '==' { return [long]($left -eq $right) }
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

for ($selector = 0; $selector -lt 16; $selector++) {
    $actual = Evaluate-Expression $equation.expression @{ sel = $selector }
    # 1??? is the first source item and overlaps 10??. The first item wins.
    $expected = if (($selector -band 8) -ne 0) { 1 } else { 0 }
    if ($actual -ne $expected) {
        throw "casez mismatch for sel=$selector`: expected code=$expected, got $actual"
    }
}

$wildcardManifest = Join-Path $projectRoot 'lower-casez-wildcards.q3a'
$wildcardText = @(& $executable '--lower-project' $wildcardManifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "casez wildcard-position vector failed to lower:`n$($wildcardText -join "`n")"
}
$wildcardTir = ($wildcardText -join "`n") | ConvertFrom-Json
if ($wildcardTir.top_module -ne 'casez_wildcard_positions' -or
    $wildcardTir.clocks.Count -ne 0 -or
    $wildcardTir.next_state_equations.Count -ne 0 -or
    $wildcardTir.combinational_equations.Count -ne 1) {
    throw 'The wildcard-position vector must lower to one combinational output equation.'
}
$wildcardEquation = $wildcardTir.combinational_equations[0]
if ($wildcardEquation.target -ne 'code' -or
    $wildcardEquation.source.file -notmatch 'casez_wildcard_positions\.sv' -or
    $wildcardEquation.source.line -ne 5) {
    throw 'The wildcard-position output equation or source mapping is incorrect.'
}
$wildcardExpression = $wildcardEquation.expression
$expectedBranches = @(
    @{ Pattern = 4; Mask = 4; Code = "2'b00"; Line = 7 },
    @{ Pattern = 2; Mask = 2; Code = "2'b01"; Line = 8 },
    @{ Pattern = 1; Mask = 1; Code = "2'b10"; Line = 9 }
)
for ($index = 0; $index -lt $expectedBranches.Count; $index++) {
    $branch = $expectedBranches[$index]
    if ($wildcardExpression.kind -ne 'conditional' -or
        $wildcardExpression.source.line -ne 6 -or
        $wildcardExpression.operands[0].kind -ne 'casez_match' -or
        $wildcardExpression.operands[0].source.line -ne $branch.Line -or
        $wildcardExpression.operands[0].operands[0].value -ne 'sel' -or
        (Convert-IntegerLiteral $wildcardExpression.operands[0].operands[1].value) -ne $branch.Pattern -or
        (Convert-IntegerLiteral $wildcardExpression.operands[0].operands[2].value) -ne $branch.Mask -or
        $wildcardExpression.operands[1].value -ne $branch.Code -or
        $wildcardExpression.operands[1].source.line -ne $branch.Line) {
        throw "Wildcard mask, output code, source order, or source location is wrong for branch $index."
    }
    $wildcardExpression = $wildcardExpression.operands[2]
}
if ($wildcardExpression.kind -ne 'literal' -or
    $wildcardExpression.value -ne "2'b11" -or
    $wildcardExpression.source.line -ne 10) {
    throw 'The wildcard-position default branch or source mapping is incorrect.'
}

for ($selector = 0; $selector -lt 16; $selector++) {
    $actual = Evaluate-Expression $wildcardEquation.expression @{ sel = $selector }
    $expected = if (($selector -band 4) -ne 0) { 0 }
        elseif (($selector -band 2) -ne 0) { 1 }
        elseif (($selector -band 1) -ne 0) { 2 }
        else { 3 }
    if ($actual -ne $expected) {
        throw "Wildcard-position casez mismatch for sel=$selector`: expected code=$expected, got $actual"
    }
}

$basedManifest = Join-Path $projectRoot 'lower-casez-based-patterns.q3a'
$basedText = & $executable --lower-project $basedManifest
if ($LASTEXITCODE -ne 0) {
    throw "Based casez patterns failed to lower:`n$($basedText -join "`n")"
}
$basedTir = ($basedText -join "`n") | ConvertFrom-Json
$basedEquation = @($basedTir.combinational_equations | Where-Object target -eq 'code')[0]
$basedBranches = @(
    @{ Mask = 0x70; Value = 0x20 },
    @{ Mask = 0x07; Value = 0x05 },
    @{ Mask = 0x7f; Value = 0x03 },
    @{ Mask = 0x7e; Value = 0x02 },
    @{ Mask = 0x70; Value = 0x10 }
)
$branchExpression = $basedEquation.expression
foreach ($branch in $basedBranches) {
    $condition = $branchExpression.operands[0]
    if ($condition.kind -ne 'casez_match' -or
        $condition.operands[1].width -ne 7 -or $condition.operands[2].width -ne 7 -or
        (Convert-IntegerLiteral $condition.operands[1].value) -ne $branch.Value -or
        (Convert-IntegerLiteral $condition.operands[2].value) -ne $branch.Mask) {
        throw "Incorrect casez mask or literal value at line $($condition.source.line)."
    }
    $branchExpression = $branchExpression.operands[2]
}
for ($selector = 0; $selector -lt 128; $selector++) {
    $expected = 5
    for ($index = 0; $index -lt $basedBranches.Count; $index++) {
        $branch = $basedBranches[$index]
        if (($selector -band $branch.Mask) -eq $branch.Value) {
            $expected = $index
            break
        }
    }
    $actual = Evaluate-Expression $basedEquation.expression @{ sel = $selector }
    if ($actual -ne $expected) {
        throw "Based casez mismatch for sel=$selector. Expected $expected, got $actual."
    }
}

$correct = @(& $executable --bmc $basedManifest --property p_decode --frames 0)
if ($LASTEXITCODE -ne 0 -or $correct -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS') {
    throw "Based casez decoder disagrees with its reference property:`n$($correct -join "`n")"
}
$incorrect = @(& $executable --bmc $basedManifest --property p_wrong --frames 0)
if ($LASTEXITCODE -ne 0 -or $incorrect -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $incorrect -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "The deliberately wrong casez expectation did not replay:`n$($incorrect -join "`n")"
}

'PASS: casez oracle checks 160 selector values, binary/octal/hexadecimal masks, sizing, source order, defaults, and replay of a deliberately false assertion.'
