$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repoRoot = Split-Path -Parent $prototypeRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$positiveManifest = Join-Path $prototypeRoot 'lower-fill-literals.q3a'

$tirText = @(& $sourcecheck '--lower-project' $positiveManifest 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Fill-literal RTL failed to lower:`n$($tirText -join "`n")" }
$tir = ($tirText -join "`n") | ConvertFrom-Json
$expectedWidths = @{ zero_2 = 2; one_2 = 2; zero_5 = 5; one_5 = 5; zero_13 = 13; one_13 = 13 }
foreach ($name in $expectedWidths.Keys) {
    $matches = @($tir.combinational_equations | Where-Object target -eq $name)
    if ($matches.Count -ne 1) { throw "Expected exactly one equation for $name." }
    $equation = $matches[0]
    $expectedFill = if ($name.StartsWith('one_')) { "'1" } else { "'0" }
    $width = [int]$expectedWidths[$name]
    $expectedValue = if ($expectedFill -eq "'1") { [int]([Math]::Pow(2, $width) - 1) } else { 0 }
    $tirValue = if ($equation.expression.value -eq "'1") { [int]([Math]::Pow(2, $equation.expression.width) - 1) } else { 0 }
    if ($equation.target_width -ne $width -or $equation.expression.width -ne $width -or
        $equation.expression.kind -ne 'literal' -or $equation.expression.value -ne $expectedFill -or
        $tirValue -ne $expectedValue) {
        throw "Unexpected context width or fill value in equation for $name."
    }
}
if (-not (@($tir.properties | Where-Object name -eq 'p_fill_context_width').Count)) {
    throw 'T-IR is missing p_fill_context_width.'
}

foreach ($manifestName in @('reject-fill-x.q3a', 'reject-fill-z.q3a')) {
    $manifestPath = Join-Path $prototypeRoot $manifestName
    $output = @(& $sourcecheck '--lower-project' $manifestPath 2>&1)
    $exitCode = $LASTEXITCODE
    $diagnostic = $output -join "`n"
    if ($exitCode -ne 1 -or
        $diagnostic -notmatch "(?m)^Q3A_PARSE_ERROR .*unbased unsized X/Z fill literals are unsupported; only '0 and '1 are supported$") {
        throw "Expected a source-located two-state fill-literal rejection for $manifestName; exit=$exitCode.`n$diagnostic"
    }
    if ($diagnostic -match '(?m)^Q3A_(?:BMC|INDUCTION|SAT|BUNDLE_RESULT)_STATUS\b') {
        throw "Unsupported fill literal $manifestName unexpectedly reached a formal query."
    }
}

$tempRoot = Join-Path (Join-Path $prototypeRoot 'bin') ('fill-context-regression-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $proofOutput = @(& $sourcecheck '--prove-inductive' $positiveManifest '--property' 'p_fill_context_width' '--output-prefix' (Join-Path $tempRoot 'proof') '--bundle-dir' (Join-Path $tempRoot 'bundle') 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (($proofOutput -join "`n") -match '(?m)^Q3A_INDUCTION_STATUS PROVEN$')) {
        throw "Fill-context property did not prove:`n$($proofOutput -join "`n")"
    }
    $reopenOutput = @(& $sourcecheck '--verify-bundle' (Join-Path $tempRoot 'bundle') 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (($reopenOutput -join "`n") -match '(?m)^Q3A_BUNDLE_STATUS REVALIDATED$')) {
        throw "Fill-context proof bundle did not revalidate:`n$($reopenOutput -join "`n")"
    }
} finally {
    $binRoot = [System.IO.Path]::GetFullPath((Join-Path $prototypeRoot 'bin'))
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($binRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

Write-Output 'PASS: RTL-007 fill literals resolve at widths 2/5/13, X/Z forms reject before proof, and the checked induction proof reopens.'
