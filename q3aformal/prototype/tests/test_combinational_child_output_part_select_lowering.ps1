param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

foreach ($testCase in @(
    @{ Manifest = 'combinational-child-output-part-select.q3a'; Prefix = 'direct' },
    @{ Manifest = 'combinational-child-output-part-select-nested.q3a'; Prefix = 'nested' },
    @{ Manifest = 'combinational-child-output-part-select-ascending.q3a'; Prefix = 'ascending direct' },
    @{ Manifest = 'combinational-child-output-part-select-ascending-nested.q3a'; Prefix = 'ascending nested' }
)) {
    $manifest = Join-Path $prototypeRoot $testCase.Manifest
    $lowered = & $sourcecheck --lower-project $manifest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$($testCase.Prefix) combinational child output part-selects did not lower: $($lowered -join [Environment]::NewLine)"
    }
    $model = ($lowered -join [Environment]::NewLine) | ConvertFrom-Json
    $bus = @($model.combinational_equations | Where-Object { $_.target -eq 'q' })
    $proxySignals = @($model.signals | Where-Object {
        $_.name -match '__nested_output_part_actual|__output_part_actual'
    })
    if ($bus.Count -ne 1 -or [int]$bus[0].target_width -ne 8 -or
        $bus[0].expression.kind -ne 'concatenation' -or
        $proxySignals.Count -ne 0) {
        throw "Expected a complete eight-bit $($testCase.Prefix) output equation with no residual proxies: $($lowered -join [Environment]::NewLine)"
    }

    $property = & $sourcecheck --bmc $manifest --property p_maps_outputs --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($property -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "$($testCase.Prefix) combinational child output mapping did not prove: $($property -join [Environment]::NewLine)"
    }
}

'PASS: direct, nested, and ascending-range combinational child output part-selects lower to complete eight-bit buses and satisfy bounded mapping properties.'
