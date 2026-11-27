param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'sequential-child-output-part-select.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Sequential child output part-selects did not lower: $($lowered -join [Environment]::NewLine)"
}
$model = ($lowered -join [Environment]::NewLine) | ConvertFrom-Json
$stateProxies = @($model.signals | Where-Object {
    $_.role -eq 'state' -and $_.width -eq 4 -and
    $_.name -match '^u_(low|high)\.__output_part_actual\.q$'
})
$proxyNextState = @($model.next_state_equations | Where-Object {
    $_.target -match '^u_(low|high)\.__output_part_actual\.q$' -and
    $_.target_width -eq 4
})
$bus = @($model.combinational_equations | Where-Object { $_.target -eq 'q' })
if ($stateProxies.Count -ne 2 -or $proxyNextState.Count -ne 2 -or
    $bus.Count -ne 1 -or $bus[0].target_width -ne 8) {
    throw "Expected two four-bit state proxies and one complete eight-bit output bus: $($lowered -join [Environment]::NewLine)"
}

foreach ($instanceName in @('u_low', 'u_high')) {
    $property = $instanceName + '.p_tracks_previous_input'
    $pass = & $sourcecheck --bmc $manifest --property $property --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Previous-input property failed for '$instanceName': $($pass -join [Environment]::NewLine)"
    }
    $falseProperty = $instanceName + '.p_rejects_previous_input'
    $fail = & $sourcecheck --bmc $manifest --property $falseProperty --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($fail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($fail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "False previous-input property did not replay for '$instanceName': $($fail -join [Environment]::NewLine)"
    }
}

$nestedManifest = Join-Path $prototypeRoot 'sequential-child-output-part-select-nested.q3a'
$nestedLowered = & $sourcecheck --lower-project $nestedManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Nested sequential child output part-selects did not lower: $($nestedLowered -join [Environment]::NewLine)"
}
$nestedModel = ($nestedLowered -join [Environment]::NewLine) | ConvertFrom-Json
$nestedStateProxies = @($nestedModel.signals | Where-Object {
    $_.role -eq 'state' -and $_.width -eq 4 -and
    $_.name -match '^u_(low|high)\.__nested_output_part_actual\.q$'
})
$nestedBus = @($nestedModel.combinational_equations | Where-Object { $_.target -eq 'q' })
if ($nestedStateProxies.Count -ne 2 -or $nestedBus.Count -ne 1 -or
    $nestedBus[0].target_width -ne 8) {
    throw "Expected nested four-bit state proxies and one complete eight-bit output bus: $($nestedLowered -join [Environment]::NewLine)"
}
foreach ($instanceName in @('u_low.u_lane', 'u_high.u_lane')) {
    $property = $instanceName + '.p_tracks_previous_input'
    $pass = & $sourcecheck --bmc $nestedManifest --property $property --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "Nested previous-input property failed for '$instanceName': $($pass -join [Environment]::NewLine)"
    }
    $falseProperty = $instanceName + '.p_rejects_previous_input'
    $fail = & $sourcecheck --bmc $nestedManifest --property $falseProperty --frames 1
    if ($LASTEXITCODE -ne 0 -or
        -not ($fail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($fail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "False nested previous-input property did not replay for '$instanceName': $($fail -join [Environment]::NewLine)"
    }
}

foreach ($testCase in @(
    @{ Manifest = 'sequential-child-output-part-select-ascending.q3a'; Prefixes = @('u_low', 'u_high'); Nested = $false },
    @{ Manifest = 'sequential-child-output-part-select-ascending-nested.q3a'; Prefixes = @('u_low.u_lane', 'u_high.u_lane'); Nested = $true }
)) {
    $ascendingManifest = Join-Path $prototypeRoot $testCase.Manifest
    $ascendingLowered = & $sourcecheck --lower-project $ascendingManifest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Ascending sequential child output part-selects did not lower: $($ascendingLowered -join [Environment]::NewLine)"
    }
    $ascendingModel = ($ascendingLowered -join [Environment]::NewLine) | ConvertFrom-Json
    $proxyPrefix = if ($testCase.Nested) { '^u_(low|high)\.__nested_output_part_actual\.q$' } else { '^u_(low|high)\.__output_part_actual\.q$' }
    $ascendingProxies = @($ascendingModel.signals | Where-Object {
        $_.role -eq 'state' -and $_.width -eq 4 -and $_.name -match $proxyPrefix
    })
    $ascendingBus = @($ascendingModel.combinational_equations | Where-Object { $_.target -eq 'q' })
    if ($ascendingProxies.Count -ne 2 -or $ascendingBus.Count -ne 1 -or
        [int]$ascendingBus[0].target_width -ne 8) {
        throw "Expected two four-bit state proxies and one complete ascending eight-bit bus: $($ascendingLowered -join [Environment]::NewLine)"
    }
    foreach ($instanceName in $testCase.Prefixes) {
        $property = $instanceName + '.p_tracks_previous_input'
        $pass = & $sourcecheck --bmc $ascendingManifest --property $property --frames 1
        if ($LASTEXITCODE -ne 0 -or
            -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
            throw "Ascending previous-input property failed for '$instanceName': $($pass -join [Environment]::NewLine)"
        }
        $falseProperty = $instanceName + '.p_rejects_previous_input'
        $fail = & $sourcecheck --bmc $ascendingManifest --property $falseProperty --frames 1
        if ($LASTEXITCODE -ne 0 -or
            -not ($fail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
            -not ($fail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
            throw "False ascending previous-input property did not replay for '$instanceName': $($fail -join [Environment]::NewLine)"
        }
    }
}

$negativeCases = @(
    @{ Manifest = 'sequential-child-output-part-select-bad-width.q3a'; Diagnostic = 'exact widths are required' },
    @{ Manifest = 'sequential-child-output-part-select-bad-direction.q3a'; Diagnostic = 'part-select direction must match the declared packed range' },
    @{ Manifest = 'sequential-child-output-part-select-incomplete.q3a'; Diagnostic = 'child output bit-select connections do not cover every bit' },
    @{ Manifest = 'sequential-child-output-part-select-duplicate.q3a'; Diagnostic = 'multiple child output connections drive packed bit offset' }
)
foreach ($case in $negativeCases) {
    $negativeManifest = Join-Path $prototypeRoot $case.Manifest
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $negativeOutput = & $sourcecheck --lower-project $negativeManifest 2>&1
    $negativeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    $negativeMessage = $negativeOutput -join [Environment]::NewLine
    if ($negativeExitCode -eq 0 -or
        $negativeMessage -notmatch [regex]::Escape($case.Diagnostic)) {
        throw "Expected '$($case.Manifest)' to fail closed with '$($case.Diagnostic)': $negativeMessage"
    }
}

'PASS: direct, nested, and ascending-range sequential child output part-selects form vector state proxies, assemble into output buses, and pass/fail history properties replay-check.'
