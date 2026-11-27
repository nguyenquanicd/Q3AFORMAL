param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'sequential-child-output-bit.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Sequential child output bit-selects did not lower:`n$($lowered -join [Environment]::NewLine)"
}
$model = ($lowered -join "`n") | ConvertFrom-Json
$properties = @($model.properties | Where-Object {
    $_.name -match '^g_lane\[[0-3]\]\.u_lane\.p_(tracks|rejects)_previous_input$'
})
$stateProxies = @($model.signals | Where-Object {
    $_.role -eq 'state' -and $_.name -match '^g_lane\[[0-3]\]\.u_lane\.__output_bit_actual\.q$'
})
$proxyNextState = @($model.next_state_equations | Where-Object {
    $_.target -match '^g_lane\[[0-3]\]\.u_lane\.__output_bit_actual\.q$'
})
$bus = @($model.combinational_equations | Where-Object { $_.target -eq 'q' })
if ($properties.Count -ne 8 -or $stateProxies.Count -ne 4 -or
    $proxyNextState.Count -ne 4 -or $bus.Count -ne 1 -or
    [int]$bus[0].target_width -ne 4 -or
    $bus[0].expression.kind -ne 'concatenation') {
    throw "Expected eight lane-qualified properties, four child state lanes, and a complete output bus:`n$($lowered -join "`n")"
}

for ($lane = 0; $lane -lt 4; $lane++) {
    $prefix = "g_lane[$lane].u_lane."
    $pass = & $sourcecheck --bmc $manifest --property ($prefix + 'p_tracks_previous_input') --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Sequential output history property did not pass on lane ${lane}: $($pass -join [Environment]::NewLine)"
    }
    $fail = & $sourcecheck --bmc $manifest --property ($prefix + 'p_rejects_previous_input') --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($fail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($fail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "False sequential output history property did not replay on lane ${lane}: $($fail -join [Environment]::NewLine)"
    }
}

$nestedManifest = Join-Path $prototypeRoot 'nested-sequential-child-output-bit.q3a'
$nestedLowered = & $sourcecheck --lower-project $nestedManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Nested sequential child output bit-selects did not lower:`n$($nestedLowered -join [Environment]::NewLine)"
}
$nestedModel = ($nestedLowered -join "`n") | ConvertFrom-Json
$nestedProperties = @($nestedModel.properties | Where-Object {
    $_.name -match '^g_lane\[[0-3]\]\.u_wrapper\.u_lane\.p_(tracks|rejects)_previous_input$'
})
$nestedStateProxies = @($nestedModel.signals | Where-Object {
    $_.role -eq 'state' -and $_.name -match '^g_lane\[[0-3]\]\.u_wrapper\.__nested_output_bit_actual\.q$'
})
$nestedProxyNextState = @($nestedModel.next_state_equations | Where-Object {
    $_.target -match '^g_lane\[[0-3]\]\.u_wrapper\.__nested_output_bit_actual\.q$'
})
$nestedBus = @($nestedModel.combinational_equations | Where-Object { $_.target -eq 'q' })
if ($nestedProperties.Count -ne 8 -or $nestedStateProxies.Count -ne 4 -or
    $nestedProxyNextState.Count -ne 4 -or $nestedBus.Count -ne 1 -or
    [int]$nestedBus[0].target_width -ne 4 -or
    $nestedBus[0].expression.kind -ne 'concatenation') {
    throw "Expected nested lane-qualified properties, four separate state lanes, and a complete output bus:`n$($nestedLowered -join "`n")"
}
for ($lane = 0; $lane -lt 4; $lane++) {
    $prefix = "g_lane[$lane].u_wrapper.u_lane."
    $pass = & $sourcecheck --bmc $nestedManifest --property ($prefix + 'p_tracks_previous_input') --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Nested sequential output history property failed on lane ${lane}: $($pass -join [Environment]::NewLine)"
    }
    $fail = & $sourcecheck --bmc $nestedManifest --property ($prefix + 'p_rejects_previous_input') --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($fail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($fail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "False nested sequential history property failed replay on lane ${lane}: $($fail -join [Environment]::NewLine)"
    }
}

'PASS: generated direct and nested sequential child output bit-selects remain separate state lanes, assemble into parent buses, and pass/fail history assertions replay-check on every lane.'
