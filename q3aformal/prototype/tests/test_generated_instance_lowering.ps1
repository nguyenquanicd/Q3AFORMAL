param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'generated-scalar-instance.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Active generate-if/for instance was not lowered with genvar and parameter values:`n$($lowered -join "`n")"
}
$model = ($lowered -join "`n") | ConvertFrom-Json
$generatedSignal = @($model.signals | Where-Object {
    $_.name -eq 'g_enabled.g_item[1].u.inverted'
})
$generatedParameter = @($model.parameters | Where-Object {
    $_.name -eq 'g_enabled.g_item[1].u.INVERT' -and $_.value -eq 1
})
$generatedEquation = @($model.combinational_equations | Where-Object {
    $_.target -eq 'g_enabled.g_item[1].u.inverted' -and
    $_.expression.kind -eq 'conditional' -and
    $_.expression.operands[0].kind -eq 'constant' -and
    $_.expression.operands[0].value -eq '1'
})
$outputEquation = @($model.combinational_equations | Where-Object {
    $_.target -eq 'y' -and
    $_.expression.kind -eq 'signal' -and
    $_.expression.value -eq 'g_enabled.g_item[1].u.inverted'
})
if ($generatedSignal.Count -ne 1 -or $generatedParameter.Count -ne 1 -or
    $generatedEquation.Count -ne 1 -or $outputEquation.Count -ne 1) {
    throw "Generated path, genvar-resolved parameter, or flattened equations differ from the expected T-IR:`n$($lowered -join "`n")"
}

$missingBranch = & $sourcecheck --elaborate-project $manifest
if ($LASTEXITCODE -ne 0 -or
    (($missingBranch -join "`n") -match 'missing_generated_cell')) {
    throw "Inactive generate branch must not be resolved or lowered:`n$($missingBranch -join "`n")"
}

$bitLanes = Join-Path $prototypeRoot 'generated-hierarchy.q3a'
$bitLaneLowered = & $sourcecheck --lower-project $bitLanes 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Generated scalar output lanes did not lower into their parent bus:`n$($bitLaneLowered -join "`n")"
}
$bitLaneModel = ($bitLaneLowered -join "`n") | ConvertFrom-Json
if (($bitLaneLowered -join "`n") -match '__nested_output_bit_actual|__output_bit_actual') {
    throw "Direct generated child output proxies leaked into serialized T-IR:`n$($bitLaneLowered -join "`n")"
}
$dataOutput = @($bitLaneModel.combinational_equations | Where-Object { $_.target -eq 'data_out' })
if ($dataOutput.Count -ne 1 -or [int]$dataOutput[0].target_width -ne 4 -or
    $dataOutput[0].expression.kind -ne 'concatenation' -or
    @($dataOutput[0].expression.operands).Count -ne 4) {
    throw "Generated output lanes did not produce one complete four-bit bus equation:`n$($bitLaneLowered -join "`n")"
}
for ($bit = 0; $bit -lt 4; $bit++) {
    $operand = $dataOutput[0].expression.operands[$bit]
    $expectedOffset = 3 - $bit
    if ($operand.kind -ne 'select' -or $operand.value -ne 'bit' -or
        $operand.operands[0].kind -ne 'signal' -or
        $operand.operands[0].value -ne 'data_in' -or
        [int]$operand.operands[1].value -ne $expectedOffset) {
        throw "Generated lane $bit did not preserve expected LSB offset $expectedOffset in data_out:`n$($bitLaneLowered -join "`n")"
    }
}

$nestedOutputManifest = Join-Path $prototypeRoot 'nested-instance-output-bit.q3a'
$nestedOutputLowered = & $sourcecheck --lower-project $nestedOutputManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Nested generated scalar output lanes did not lower into their parent bus:`n$($nestedOutputLowered -join "`n")"
}
$nestedOutputModel = ($nestedOutputLowered -join "`n") | ConvertFrom-Json
if (($nestedOutputLowered -join "`n") -match '__nested_output_bit_actual|__output_bit_actual') {
    throw "Nested generated child output proxies leaked into serialized T-IR:`n$($nestedOutputLowered -join "`n")"
}
$nestedBusEquation = @($nestedOutputModel.combinational_equations | Where-Object { $_.target -eq 'y' })
if ($nestedBusEquation.Count -ne 1 -or [int]$nestedBusEquation[0].target_width -ne 4 -or
    $nestedBusEquation[0].expression.kind -ne 'concatenation' -or
    @($nestedBusEquation[0].expression.operands).Count -ne 4) {
    throw "Nested generated output lanes did not produce one complete four-bit bus equation:`n$($nestedOutputLowered -join "`n")"
}
$nestedOutputPass = & $sourcecheck --bmc $nestedOutputManifest --property p_nested_output_map --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($nestedOutputPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Nested generated output mapping did not pass its SAT query: $($nestedOutputPass -join [Environment]::NewLine)"
}

'PASS: generated hierarchy lowers with resolved genvar/parameter identity, and direct/nested scalar output lanes assemble into complete bus equations with SAT-checked behavior.'
