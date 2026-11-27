$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-sva-sequences.q3a'

$tirText = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "SVA history vector failed to lower: $($tirText -join "`n")"
}
$tir = ($tirText -join "`n") | ConvertFrom-Json

function Get-ExpressionNodes($node, [System.Collections.Generic.List[object]] $nodes) {
    if ($null -eq $node) { return }
    if ($node -is [System.Array]) {
        foreach ($item in $node) { Get-ExpressionNodes $item $nodes }
        return
    }
    if ($node.PSObject.Properties.Name -contains 'kind' -and
        $node.PSObject.Properties.Name -contains 'operands') {
        $nodes.Add($node)
        Get-ExpressionNodes $node.operands $nodes
        return
    }
    foreach ($property in $node.PSObject.Properties) {
        Get-ExpressionNodes $property.Value $nodes
    }
}

$expressionNodes = [System.Collections.Generic.List[object]]::new()
Get-ExpressionNodes $tir.properties $expressionNodes
$unloweredPast = @($expressionNodes | Where-Object { $_.kind -eq 'past' })
if ($unloweredPast.Count -ne 0) {
    throw "Expected $($unloweredPast.Count) `$past nodes to lower to history-state references"
}

$historyReferences = @($expressionNodes | Where-Object { $_.kind -eq 'history_ref' })
if ($historyReferences.Count -lt 2) {
    throw "Expected at least three lowered history references; found $($historyReferences.Count)"
}

$historyDataSignals = @($tir.signals | Where-Object { $_.role -eq 'history_data' })
$historyValidSignals = @($tir.signals | Where-Object { $_.role -eq 'history_valid' })
if ($historyDataSignals.Count -lt 2) {
    throw "Expected generated history data state, found $($historyDataSignals.Count) signals"
}
if ($historyValidSignals.Count -lt 2) {
    throw "Expected two validity state stages for maximum delay 2, found $($historyValidSignals.Count)"
}

$nextStateTargets = @($tir.next_state_equations | ForEach-Object { $_.target })
foreach ($signal in @($historyDataSignals) + @($historyValidSignals)) {
    if ($nextStateTargets -notcontains $signal.name) {
        throw "History state '$($signal.name)' has no next-state equation"
    }
}

foreach ($delay in @(1, 2)) {
    $guard = @($tir.history_guards | Where-Object { $_.delay -eq $delay })
    if ($guard.Count -ne 1 -or -not $guard[0].valid_signal) {
        throw "Expected one named history-valid state for delay $delay"
    }
    if ($guard[0].initially_valid -ne $false -or
        $guard[0].valid_after_samples -ne $delay -or
        $guard[0].state_chain_initial_value -ne '0' -or
        $guard[0].reset_behavior -ne 'retains_across_reset') {
        throw "History-valid semantics are incorrect for delay $delay"
    }
}

foreach ($property in $tir.properties) {
    if ($property.history_guard_delay -eq 0) {
        if ($property.history_guard_signal -ne $null) {
            throw "Property '$($property.name)' should not reference a history guard"
        }
    } elseif (-not $property.history_guard_signal) {
        throw "Property '$($property.name)' is missing its history guard reference"
    }
}

$nestedText = & $executable --lower-project (Join-Path $projectRoot 'lower-sva-nested-past.q3a')
if ($LASTEXITCODE -ne 0) {
    throw "Nested `$past vector failed to lower: $($nestedText -join "`n")"
}
$nested = ($nestedText -join "`n") | ConvertFrom-Json
if ($nested.properties.Count -ne 1 -or
    $nested.properties[0].history_guard_delay -ne 2) {
    throw 'Nested $past depth 2 must require a two-sample history guard'
}
if (@($nested.history_guards | Where-Object { $_.delay -eq 2 }).Count -ne 1) {
    throw 'Nested $past did not generate a two-sample validity state'
}

'PASS: $past expressions use generated history state and validity equations.'
