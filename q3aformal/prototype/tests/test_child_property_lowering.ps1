param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'child-module-property.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "A direct child module property was not lowered:`n$($lowered -join "`n")"
}
$model = ($lowered -join "`n") | ConvertFrom-Json
$copyProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.p_copy' })
$falseProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.p_not_copy' })
$historyProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.p_copy_history' })
$inlineProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.property_check_4' })
$assumeProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.p_assume_data_low' })
$coverProperty = @($model.properties | Where-Object { $_.name -eq 'u_leaf.property_check_6' })
if ($copyProperty.Count -ne 1 -or $falseProperty.Count -ne 1 -or
    $historyProperty.Count -ne 1 -or $inlineProperty.Count -ne 1 -or
    $assumeProperty.Count -ne 1 -or $coverProperty.Count -ne 1 -or
    $assumeProperty[0].kind -ne 'assume' -or $coverProperty[0].kind -ne 'cover' -or
    $copyProperty[0].clock -ne 'clk' -or
    $falseProperty[0].clock -ne 'clk' -or $historyProperty[0].clock -ne 'clk' -or
    $inlineProperty[0].clock -ne 'clk' -or
    [int]$historyProperty[0].history_guard_delay -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$historyProperty[0].history_guard_signal)) {
    throw "Child property names or clock mapping differ from expected T-IR:`n$($lowered -join "`n")"
}

$pass = & $sourcecheck --bmc $manifest --property 'u_leaf.p_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Child property did not pass after port-alias substitution: $($pass -join [Environment]::NewLine)"
}
$historyPass = & $sourcecheck --bmc $manifest --property 'u_leaf.p_copy_history' --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($historyPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Child property with guarded `$past history did not pass: $($historyPass -join [Environment]::NewLine)"
}
$inlinePass = & $sourcecheck --bmc $manifest --property 'u_leaf.property_check_4' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($inlinePass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Inline child property did not lower and pass: $($inlinePass -join [Environment]::NewLine)"
}
$counterexample = & $sourcecheck --bmc $manifest --property 'u_leaf.p_not_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($counterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($counterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "False child property did not produce a replay-validated counterexample: $($counterexample -join [Environment]::NewLine)"
}
$childCover = & $sourcecheck --bmc $manifest --property 'u_leaf.property_check_6' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($childCover -contains 'Q3A_BMC_STATUS UNKNOWN') -or
    -not ($childCover -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND')) {
    throw "Child assumption did not constrain its cover goal to a bounded miss: $($childCover -join [Environment]::NewLine)"
}

$bitManifest = Join-Path $prototypeRoot 'generated-child-property-bit.q3a'
$bitLowered = & $sourcecheck --lower-project $bitManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Generated child properties with bit-select outputs did not lower:`n$($bitLowered -join "`n")"
}
$bitModel = ($bitLowered -join "`n") | ConvertFrom-Json
$generatedProperties = @($bitModel.properties | Where-Object { $_.name -match '^g_lane\[[0-3]\]\.u_leaf\.' })
$bitBus = @($bitModel.combinational_equations | Where-Object { $_.target -eq 'y' })
if ($generatedProperties.Count -ne 24 -or $bitBus.Count -ne 1 -or
    [int]$bitBus[0].target_width -ne 4 -or
    ($bitLowered -join "`n") -match '__nested_output_bit_actual|__output_bit_actual') {
    throw "Generated child property paths, bus lowering, or proxy cleanup differ from expected T-IR:`n$($bitLowered -join "`n")"
}
$bitPass = & $sourcecheck --bmc $bitManifest --property 'g_lane[0].u_leaf.p_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($bitPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Generated child property with bit-select port aliases did not pass: $($bitPass -join [Environment]::NewLine)"
}
$bitHistoryPass = & $sourcecheck --bmc $bitManifest --property 'g_lane[0].u_leaf.p_copy_history' --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($bitHistoryPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Generated child guarded `$past property did not pass: $($bitHistoryPass -join [Environment]::NewLine)"
}
$bitCounterexample = & $sourcecheck --bmc $bitManifest --property 'g_lane[0].u_leaf.p_not_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($bitCounterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($bitCounterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "False generated child property did not produce a replay-validated counterexample: $($bitCounterexample -join [Environment]::NewLine)"
}
for ($lane = 0; $lane -lt 4; $lane++) {
    $bitCover = & $sourcecheck --bmc $bitManifest --property "g_lane[$lane].u_leaf.property_check_6" --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($bitCover -contains 'Q3A_BMC_STATUS UNKNOWN') -or
        -not ($bitCover -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND')) {
        throw "Generated child assumption did not constrain the cover goal on lane ${lane}: $($bitCover -join [Environment]::NewLine)"
    }
}

$nestedManifest = Join-Path $prototypeRoot 'nested-child-module-property.q3a'
$nestedOutput = & $sourcecheck --lower-project $nestedManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Properties below an intermediate wrapper did not lower:`n$($nestedOutput -join [Environment]::NewLine)"
}
$nestedModel = ($nestedOutput -join "`n") | ConvertFrom-Json
$nestedCopy = @($nestedModel.properties | Where-Object { $_.name -eq 'u_wrapper.u_leaf.p_copy' })
$nestedHistory = @($nestedModel.properties | Where-Object { $_.name -eq 'u_wrapper.u_leaf.p_copy_history' })
$nestedFalse = @($nestedModel.properties | Where-Object { $_.name -eq 'u_wrapper.u_leaf.p_not_copy' })
$nestedAssume = @($nestedModel.properties | Where-Object { $_.name -eq 'u_wrapper.u_leaf.p_assume_data_low' })
$nestedCover = @($nestedModel.properties | Where-Object { $_.name -eq 'u_wrapper.u_leaf.property_check_6' })
if ($nestedCopy.Count -ne 1 -or $nestedHistory.Count -ne 1 -or
    $nestedFalse.Count -ne 1 -or $nestedAssume.Count -ne 1 -or
    $nestedCover.Count -ne 1 -or $nestedAssume[0].kind -ne 'assume' -or
    $nestedCover[0].kind -ne 'cover' -or $nestedCopy[0].clock -ne 'clk' -or
    $nestedHistory[0].clock -ne 'clk' -or
    [int]$nestedHistory[0].history_guard_delay -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$nestedHistory[0].history_guard_signal) -or
    [string]$nestedHistory[0].history_guard_signal -notlike 'u_wrapper.*') {
    throw "Nested property paths, clock mapping or history guard names differ from expected T-IR:`n$($nestedOutput -join "`n")"
}
$nestedPass = & $sourcecheck --bmc $nestedManifest --property 'u_wrapper.u_leaf.p_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($nestedPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Nested child property did not pass after multi-level port alias substitution: $($nestedPass -join [Environment]::NewLine)"
}
$nestedHistoryPass = & $sourcecheck --bmc $nestedManifest --property 'u_wrapper.u_leaf.p_copy_history' --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($nestedHistoryPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Nested child guarded `$past property did not pass: $($nestedHistoryPass -join [Environment]::NewLine)"
}
$nestedCounterexample = & $sourcecheck --bmc $nestedManifest --property 'u_wrapper.u_leaf.p_not_copy' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($nestedCounterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($nestedCounterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "False nested child property did not produce a replay-validated counterexample: $($nestedCounterexample -join [Environment]::NewLine)"
}
$nestedCoverResult = & $sourcecheck --bmc $nestedManifest --property 'u_wrapper.u_leaf.property_check_6' --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($nestedCoverResult -contains 'Q3A_BMC_STATUS UNKNOWN') -or
    -not ($nestedCoverResult -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND')) {
    throw "Nested child assumption did not constrain its cover goal to a bounded miss: $($nestedCoverResult -join [Environment]::NewLine)"
}

$generatedNestedManifest = Join-Path $prototypeRoot 'generated-nested-child-property-bit.q3a'
$generatedNestedOutput = & $sourcecheck --lower-project $generatedNestedManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Generated properties below nested wrappers did not lower:`n$($generatedNestedOutput -join [Environment]::NewLine)"
}
$generatedNestedModel = ($generatedNestedOutput -join "`n") | ConvertFrom-Json
$generatedNestedProperties = @($generatedNestedModel.properties | Where-Object {
    $_.name -match '^g_lane\[[0-3]\]\.u_wrapper\.u_inner\.u_leaf\.'
})
$generatedNestedHistory = @($generatedNestedProperties | Where-Object {
    $_.name -eq 'g_lane[0].u_wrapper.u_inner.u_leaf.p_copy_history'
})
$generatedNestedBus = @($generatedNestedModel.combinational_equations | Where-Object {
    $_.target -eq 'y'
})
if ($generatedNestedProperties.Count -ne 24 -or
    $generatedNestedHistory.Count -ne 1 -or
    $generatedNestedBus.Count -ne 1 -or
    [int]$generatedNestedBus[0].target_width -ne 4 -or
    ($generatedNestedOutput -join "`n") -match '__nested_output_bit_actual|__output_bit_actual') {
    throw "Generated nested property paths, four-bit bus, or output proxy cleanup differ from expected T-IR:`n$($generatedNestedOutput -join "`n")"
}
for ($lane = 0; $lane -lt 4; $lane++) {
    $propertyPrefix = "g_lane[$lane].u_wrapper.u_inner.u_leaf."
    $generatedNestedPass = & $sourcecheck --bmc $generatedNestedManifest --property ($propertyPrefix + 'p_copy') --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($generatedNestedPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Generated nested child property failed on lane ${lane}: $($generatedNestedPass -join [Environment]::NewLine)"
    }
    $generatedNestedHistoryPass = & $sourcecheck --bmc $generatedNestedManifest --property ($propertyPrefix + 'p_copy_history') --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($generatedNestedHistoryPass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Generated nested child guarded `$past property failed on lane ${lane}: $($generatedNestedHistoryPass -join [Environment]::NewLine)"
    }
    $generatedNestedFalse = & $sourcecheck --bmc $generatedNestedManifest --property ($propertyPrefix + 'p_not_copy') --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($generatedNestedFalse -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($generatedNestedFalse -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "False generated nested property failed replay on lane ${lane}: $($generatedNestedFalse -join [Environment]::NewLine)"
    }
    $generatedNestedCover = & $sourcecheck --bmc $generatedNestedManifest --property ($propertyPrefix + 'property_check_6') --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($generatedNestedCover -contains 'Q3A_BMC_STATUS UNKNOWN') -or
        -not ($generatedNestedCover -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND')) {
        throw "Generated nested child assumption did not constrain cover on lane ${lane}: $($generatedNestedCover -join [Environment]::NewLine)"
    }
}

'PASS: direct/generated/nested child assert, assume and cover properties map through hierarchy; assumptions constrain bounded covers, guarded $past passes, and false assertions replay on every generated lane.'
