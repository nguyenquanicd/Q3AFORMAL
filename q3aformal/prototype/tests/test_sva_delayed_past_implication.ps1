$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'delayed-past-implication.q3a'

$loweredText = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Delayed `$past implication fixture did not lower:`n$($loweredText -join "`n")"
}
$model = ($loweredText -join "`n") | ConvertFrom-Json
if ($model.schema_version -ne 'Q3A-TIR-0.4') {
    throw "Expected split-history T-IR schema 0.4; found '$($model.schema_version)'"
}
$assertion = @($model.properties | Where-Object { $_.name -eq 'p_delayed_consequent_past_fails' })
$cover = @($model.properties | Where-Object { $_.name -eq 'c_delayed_consequent_past_hits' })
$immediateAssertion = @($model.properties | Where-Object { $_.name -eq 'p_immediate_consequent_past_fails' })
$immediateCover = @($model.properties | Where-Object { $_.name -eq 'c_immediate_consequent_past_hits' })
$delayedAntecedentAssertion = @($model.properties | Where-Object { $_.name -eq 'p_delayed_antecedent_past_fails' })
$delayedAntecedentCover = @($model.properties | Where-Object { $_.name -eq 'c_delayed_antecedent_past_hits' })
$immediateAntecedentAssertion = @($model.properties | Where-Object { $_.name -eq 'p_immediate_antecedent_past_fails' })
if ($assertion.Count -ne 1 -or $cover.Count -ne 1 -or
    -not $assertion[0].split_history_guards -or
    $assertion[0].antecedent_history_guard_delay -ne 0 -or
    $assertion[0].antecedent_history_guard_signal -ne $null -or
    $assertion[0].consequent_history_guard_delay -ne 0 -or
    $assertion[0].consequent_history_guard_signal -ne $null -or
    $immediateAssertion.Count -ne 1 -or
    $immediateAssertion[0].consequent_history_guard_delay -ne 1 -or
    -not $immediateAssertion[0].consequent_history_guard_signal -or
    $immediateCover.Count -ne 1 -or
    $immediateCover[0].consequent_history_guard_delay -ne 1 -or
    -not $immediateCover[0].consequent_history_guard_signal -or
    $delayedAntecedentAssertion.Count -ne 1 -or
    $delayedAntecedentAssertion[0].antecedent_history_guard_delay -ne 0 -or
    $delayedAntecedentAssertion[0].antecedent_history_guard_signal -ne $null -or
    $delayedAntecedentCover.Count -ne 1 -or
    $delayedAntecedentCover[0].antecedent_history_guard_delay -ne 0 -or
    $delayedAntecedentCover[0].antecedent_history_guard_signal -ne $null -or
    $immediateAntecedentAssertion.Count -ne 1 -or
    $immediateAntecedentAssertion[0].antecedent_history_guard_delay -ne 1 -or
    -not $immediateAntecedentAssertion[0].antecedent_history_guard_signal) {
    throw 'The implication operands do not retain independent $past validity guards'
}

$assertionResult = & $executable --bmc $manifest `
    --property p_delayed_consequent_past_fails --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($assertionResult -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($assertionResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A consequent `$past failure at frame 1 must be found and replayed:`n$($assertionResult -join "`n")"
}

$coverResult = & $executable --bmc $manifest `
    --property c_delayed_consequent_past_hits --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($coverResult -contains 'Q3A_BMC_STATUS COVERED') -or
    -not ($coverResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A consequent `$past cover at frame 1 must be found and replayed:`n$($coverResult -join "`n")"
}

$immediateAssertionResult = & $executable --bmc $manifest `
    --property p_immediate_consequent_past_fails --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($immediateAssertionResult -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($immediateAssertionResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "An immediate consequent `$past failure must wait for history then be replayed:`n$($immediateAssertionResult -join "`n")"
}

$immediateCoverResult = & $executable --bmc $manifest `
    --property c_immediate_consequent_past_hits --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($immediateCoverResult -contains 'Q3A_BMC_STATUS COVERED') -or
    -not ($immediateCoverResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "An immediate consequent `$past cover must wait for history then be replayed:`n$($immediateCoverResult -join "`n")"
}

$delayedAntecedentAssertionResult = & $executable --bmc $manifest `
    --property p_delayed_antecedent_past_fails --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedAntecedentAssertionResult -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($delayedAntecedentAssertionResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A delayed antecedent `$past failure must use validity at its term sample:`n$($delayedAntecedentAssertionResult -join "`n")"
}

$delayedAntecedentCoverResult = & $executable --bmc $manifest `
    --property c_delayed_antecedent_past_hits --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedAntecedentCoverResult -contains 'Q3A_BMC_STATUS COVERED') -or
    -not ($delayedAntecedentCoverResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A delayed antecedent `$past cover must use validity at its term sample:`n$($delayedAntecedentCoverResult -join "`n")"
}

$immediateAntecedentAssertionResult = & $executable --bmc $manifest `
    --property p_immediate_antecedent_past_fails --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($immediateAntecedentAssertionResult -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($immediateAntecedentAssertionResult -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "An immediate antecedent `$past failure must wait for history then replay:`n$($immediateAntecedentAssertionResult -join "`n")"
}

'PASS: antecedent/consequent history guards align to immediate and delayed sequence terms across assertion, cover, BMC, and replay.'
