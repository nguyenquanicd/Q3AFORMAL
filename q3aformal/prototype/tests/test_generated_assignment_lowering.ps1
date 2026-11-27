param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'generated-scalar-assignment.q3a'
$declarationManifest = Join-Path $prototypeRoot 'generated-scalar-declaration.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
    if ($LASTEXITCODE -ne 0) { throw 'Q3AFormal sourcecheck build failed.' }
}
if (-not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Active generated continuous assignment was not lowered: $($lowered -join [Environment]::NewLine)"
}
$model = ($lowered -join [Environment]::NewLine) | ConvertFrom-Json
$equations = @($model.combinational_equations | Where-Object { $_.target -eq 'y' })
if ($equations.Count -ne 1) {
    throw "Expected exactly one equation for y from the active generate branch, found $($equations.Count)."
}
$expressionJson = ConvertTo-Json -Depth 64 -Compress -InputObject $equations[0].expression
if ($expressionJson -notmatch '"value":"2"' -or
    $expressionJson -match 'unresolved_inactive_signal') {
    throw "Genvar substitution or inactive-branch filtering is incorrect: $expressionJson"
}
$childEquations = @($model.combinational_equations | Where-Object { $_.target -eq 'child_y' })
if ($childEquations.Count -ne 1) {
    throw "Expected one flattened child generated-assignment equation, found $($childEquations.Count)."
}
$childExpressionJson = ConvertTo-Json -Depth 64 -Compress -InputObject $childEquations[0].expression
if ($childExpressionJson -notmatch '"value":"5"') {
    throw "Child parameter override did not resolve the child genvar: $childExpressionJson"
}
$elaboration = & $sourcecheck --elaborate-project $manifest
if ($LASTEXITCODE -ne 0 -or
    @($elaboration | Where-Object { $_ -match 'generate assignment path="g_enabled.g_item\[2\]" selected=1 genvar i=2' }).Count -ne 1) {
    throw "Resolved generate assignment path/genvar is missing from elaboration output: $($elaboration -join [Environment]::NewLine)"
}

$declarationOutput = & $sourcecheck --lower-project $declarationManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Active generate-local declaration was not lowered: $($declarationOutput -join [Environment]::NewLine)"
}
$declarationModel = ($declarationOutput -join [Environment]::NewLine) | ConvertFrom-Json
$localSignals = @($declarationModel.signals | Where-Object { $_.name -match '^g_(active\.local_signal|lane\[[1-3]\]\.local_signal)$' })
$localEquations = @($declarationModel.combinational_equations | Where-Object { $_.target -match '^g_(active\.local_signal|lane\[[1-3]\]\.local_signal)$' })
$outputEquation = @($declarationModel.combinational_equations | Where-Object { $_.target -eq 'y' })
$childLocalSignal = @($declarationModel.signals | Where-Object { $_.name -eq 'u_child.g_child.local_signal' })
$childLocalEquation = @($declarationModel.combinational_equations | Where-Object { $_.target -eq 'u_child.g_child.local_signal' })
$childOutputEquation = @($declarationModel.combinational_equations | Where-Object { $_.target -eq 'child_y' })
if ($localSignals.Count -ne 4 -or $localEquations.Count -ne 4 -or
    $outputEquation.Count -ne 1 -or $childLocalSignal.Count -ne 1 -or
    $childLocalEquation.Count -ne 1 -or $childOutputEquation.Count -ne 1) {
    throw 'Expected four top-level scoped declarations and one child scoped declaration with corresponding equations in T-IR.'
}
$outputExpressionJson = ConvertTo-Json -Depth 64 -Compress -InputObject $outputEquation[0].expression
foreach ($localEquation in $localEquations) {
    $localExpressionJson = ConvertTo-Json -Depth 64 -Compress -InputObject $localEquation.expression
    if ($localExpressionJson -notmatch '"value":"a"') {
        throw "Generate-local lexical name resolution is incorrect: $localExpressionJson"
    }
}
foreach ($expectedName in @('g_active.local_signal', 'g_lane[1].local_signal', 'g_lane[2].local_signal', 'g_lane[3].local_signal')) {
    if ($outputExpressionJson -notmatch [regex]::Escape($expectedName)) {
        throw "The assembled output equation is missing scoped signal '$expectedName': $outputExpressionJson"
    }
}
$childOutputExpressionJson = ConvertTo-Json -Depth 64 -Compress -InputObject $childOutputEquation[0].expression
if ($childOutputExpressionJson -notmatch 'u_child\.g_child\.local_signal') {
    throw "Child generate-local name was not flattened with its instance path: $childOutputExpressionJson"
}
$topDeclarationPass = & $sourcecheck --bmc $declarationManifest --property p_generated_local_bus --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($topDeclarationPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Generate-for local signals did not preserve the complete bus relation: $($topDeclarationPass -join [Environment]::NewLine)"
}
$childDeclarationPass = & $sourcecheck --bmc $declarationManifest --property p_generated_child_local --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($childDeclarationPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Child generate-local signal did not preserve its output relation: $($childDeclarationPass -join [Environment]::NewLine)"
}
$negativeDeclarationCases = @(
    @{ Manifest = 'generated-localparam-negative.q3a'; Diagnostic = "duplicate generate-local declaration 'ENABLED'" },
    @{ Manifest = 'generated-unscoped-declaration-negative.q3a'; Diagnostic = 'must be inside a named or implicit generate block' }
)
foreach ($case in $negativeDeclarationCases) {
    $negativeManifest = Join-Path $prototypeRoot $case.Manifest
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $negativeOutput = & $sourcecheck --lower-project $negativeManifest 2>&1
    $negativeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    $negativeMessage = $negativeOutput -join [Environment]::NewLine
    if ($negativeExitCode -eq 0 -or
        $negativeMessage -notmatch [regex]::Escape($case.Diagnostic)) {
        throw "Expected generated declaration case '$($case.Manifest)' to fail closed with '$($case.Diagnostic)': $negativeMessage"
    }
}

'PASS: generated assignments and scoped generate-local declarations preserve per-scope names, packed bus assembly, and top/child RTL relations under bounded SAT checks.'
