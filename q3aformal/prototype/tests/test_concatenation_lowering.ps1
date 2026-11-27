$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repoRoot = Split-Path -Parent $prototypeRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'lower-concat-three.q3a'

$tirText = @(& $sourcecheck '--lower-project' $manifest 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Three-member concatenation did not lower:`n$($tirText -join "`n")" }
$tir = ($tirText -join "`n") | ConvertFrom-Json
$equations = @($tir.combinational_equations | Where-Object target -eq 'y')
if ($equations.Count -ne 1) { throw "Expected one equation for y, found $($equations.Count)." }
$expression = $equations[0].expression
$operands = @($expression.operands)
if ($expression.kind -ne 'concatenation' -or $expression.width -ne 6 -or $operands.Count -ne 3) {
    throw 'Expected a six-bit concatenation containing exactly three operands.'
}
$expectedNames = @('a', 'b', 'c')
$expectedWidths = @(2, 3, 1)
for ($index = 0; $index -lt $operands.Count; $index++) {
    if ($operands[$index].kind -ne 'signal' -or
        $operands[$index].value -ne $expectedNames[$index] -or
        $operands[$index].width -ne $expectedWidths[$index]) {
        throw "Concatenation operand $index has unexpected ordering, identity, or width."
    }
}

# Independently calculate every value from the declared operand widths and source ordering.
for ($a = 0; $a -lt 4; $a++) {
    for ($b = 0; $b -lt 8; $b++) {
        for ($c = 0; $c -lt 2; $c++) {
            $expected = ($a -shl 4) -bor ($b -shl 1) -bor $c
            $frame = @{ a = $a; b = $b; c = $c }
            $loweredValue = 0
            foreach ($operand in $operands) {
                $loweredValue = ($loweredValue -shl $operand.width) -bor $frame[$operand.value]
            }
            if ($expected -ne $loweredValue) {
                throw "T-IR concatenation mismatch for a=$a b=$b c=${c}: expected $expected, got $loweredValue."
            }
        }
    }
}

$tempRoot = Join-Path (Join-Path $prototypeRoot 'bin') ('concat3-regression-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $prefix = Join-Path $tempRoot 'proof'
    $bundle = Join-Path $tempRoot 'bundle'
    $proofOutput = @(& $sourcecheck '--prove-inductive' $manifest '--property' 'p_three_member_concat_order' '--output-prefix' $prefix '--bundle-dir' $bundle 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (($proofOutput -join "`n") -match '(?m)^Q3A_INDUCTION_STATUS PROVEN$')) {
        throw "Three-member concatenation order property did not prove:`n$($proofOutput -join "`n")"
    }
    $reopenOutput = @(& $sourcecheck '--verify-bundle' $bundle 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (($reopenOutput -join "`n") -match '(?m)^Q3A_BUNDLE_STATUS REVALIDATED$')) {
        throw "The saved concatenation proof bundle did not revalidate:`n$($reopenOutput -join "`n")"
    }
} finally {
    $binRoot = [System.IO.Path]::GetFullPath((Join-Path $prototypeRoot 'bin'))
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($binRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

Write-Output 'PASS: RTL-015 three-member concatenation ordering matched 64 independent input combinations and a revalidated k-induction proof.'
