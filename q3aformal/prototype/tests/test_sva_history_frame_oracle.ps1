$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'

function Read-Tir([string] $manifestName) {
    $manifest = Join-Path $projectRoot $manifestName
    $text = & $executable --lower-project $manifest
    if ($LASTEXITCODE -ne 0) {
        throw "History vector failed to lower: $manifestName`n$($text -join "`n")"
    }
    return (($text -join "`n") | ConvertFrom-Json)
}

function Convert-IntegerLiteral([string] $text) {
    if ($text -notmatch "^(?<width>\d+)'(?<signed>s)?(?<base>[bBoOdDhH])(?<digits>[0-9a-fA-F_]+)$") {
        throw "Unsupported literal in history oracle: $text"
    }
    $base = switch ($Matches.base.ToLowerInvariant()) {
        'b' { 2 }
        'o' { 8 }
        'd' { 10 }
        'h' { 16 }
    }
    return [long][Convert]::ToInt64($Matches.digits.Replace('_', ''), $base)
}

function Evaluate-Expression($expression, [hashtable] $values) {
    switch ($expression.kind) {
        'signal' {
            if (-not $values.ContainsKey($expression.value)) {
                throw "History oracle has no value for signal '$($expression.value)'"
            }
            return [long]$values[$expression.value]
        }
        'history_ref' {
            if (-not $values.ContainsKey($expression.value)) {
                throw "History oracle has no value for history state '$($expression.value)'"
            }
            return [long]$values[$expression.value]
        }
        'literal' { return Convert-IntegerLiteral $expression.value }
        default { throw "Unsupported expression kind '$($expression.kind)' in history oracle" }
    }
}

$nested = Read-Tir '.\lower-sva-nested-past.q3a'
$nestedData = @($nested.signals | Where-Object { $_.role -eq 'history_data' })
$nestedValid = @($nested.signals | Where-Object { $_.role -eq 'history_valid' })
if ($nestedData.Count -ne 2 -or $nestedValid.Count -ne 2) {
    throw 'Nested $past oracle requires exactly two data and two validity stages'
}

$state = @{}
$state[$nestedData[0].name] = 1
$state[$nestedData[1].name] = 0
$state[$nestedValid[0].name] = 0
$state[$nestedValid[1].name] = 0
$samples = @(1, 0, 1, 0, 1, 1)
for ($frame = 0; $frame -lt $samples.Count; $frame++) {
    $expectedValid = [long]($frame -ge 2)
    if ($state[$nestedValid[1].name] -ne $expectedValid) {
        throw "Nested history guard at sample $frame should be $expectedValid"
    }
    if ($frame -ge 1 -and $state[$nestedData[0].name] -ne $samples[$frame - 1]) {
        throw "One-sample history mismatch at sample $frame"
    }
    if ($frame -ge 2 -and $state[$nestedData[1].name] -ne $samples[$frame - 2]) {
        throw "Two-sample `$past history mismatch at sample $frame"
    }

    $values = @{ a = $samples[$frame] }
    foreach ($name in $state.Keys) { $values[$name] = $state[$name] }
    $next = @{}
    foreach ($equation in $nested.next_state_equations) {
        $next[$equation.target] = Evaluate-Expression $equation.expression $values
    }
    foreach ($name in $next.Keys) { $state[$name] = $next[$name] }
}

$handshake = Read-Tir '.\lower-handshake1.q3a'
$validSignal = @($handshake.signals | Where-Object { $_.role -eq 'history_valid' })[0]
$validEquation = @($handshake.next_state_equations | Where-Object { $_.target -eq $validSignal.name })[0]
if ($null -eq $validEquation) { throw 'Handshake history-valid next-state equation is missing' }
$validState = 0
foreach ($reset in @(1, 1, 0, 1, 0)) {
    $values = @{ rst = $reset }
    $values[$validSignal.name] = $validState
    $nextValid = Evaluate-Expression $validEquation.expression $values
    if ($nextValid -ne 1) {
        throw "History validity must advance through reset; got $nextValid while rst=$reset"
    }
    $validState = $nextValid
}

$resetPastManifest = Join-Path $projectRoot 'lower-sva-past-two-reset.q3a'
$resetPast = Read-Tir 'lower-sva-past-two-reset.q3a'
$pastOne = @($resetPast.properties | Where-Object { $_.name -eq 'p_past_one' })[0]
$pastTwo = @($resetPast.properties | Where-Object { $_.name -eq 'p_past_two' })[0]
$pastData = @($resetPast.signals | Where-Object { $_.role -eq 'history_data' })
$pastValid = @($resetPast.signals | Where-Object { $_.role -eq 'history_valid' })
$pastDataStage0 = @($pastData | Where-Object { $_.name -match 'stage_0$' })[0]
$pastDataStage1 = @($pastData | Where-Object { $_.name -match 'stage_1$' })[0]
$pastValidStage0 = @($pastValid | Where-Object { $_.name -match 'stage_0$' })[0]
$pastValidStage1 = @($pastValid | Where-Object { $_.name -match 'stage_1$' })[0]
$pastTwoGuard = @($resetPast.history_guards | Where-Object { $_.delay -eq 2 })[0]
if ($null -eq $pastOne -or $null -eq $pastTwo -or
    $pastOne.antecedent_history_guard_delay -ne 1 -or
    $pastOne.antecedent.terms[0].predicate.kind -ne 'history_ref' -or
    $pastOne.antecedent.terms[0].predicate.value -ne $pastDataStage0.name -or
    $pastTwo.antecedent_history_guard_delay -ne 2 -or
    $pastTwo.antecedent.terms[0].predicate.kind -ne 'history_ref' -or
    $pastTwo.antecedent.terms[0].predicate.value -ne $pastDataStage1.name -or
    $pastOne.antecedent.terms[0].predicate.source.file -ne 'corpus/sva-vectors/sva_past_two_reset.sv' -or
    $pastTwo.antecedent.terms[0].predicate.source.file -ne 'corpus/sva-vectors/sva_past_two_reset.sv' -or
    $null -eq $pastTwoGuard -or
    $pastTwoGuard.valid_after_samples -ne 2 -or
    $pastTwoGuard.reset_behavior -ne 'retains_across_reset' -or
    $pastData.Count -ne 2 -or $pastValid.Count -ne 2) {
    throw 'Explicit $past(a) and $past(a,2) properties must map to the expected data and validity stages'
}

$historyNames = @($pastData | ForEach-Object { $_.name }) +
    @($pastValid | ForEach-Object { $_.name })
$historyEquations = @($resetPast.next_state_equations | Where-Object { $historyNames -contains $_.target })
if ($historyEquations.Count -ne 4) {
    throw "Expected four reset-independent history equations, found $($historyEquations.Count)"
}
$resetState = @{
    $pastDataStage0.name = 1
    $pastDataStage1.name = 0
    $pastValidStage0.name = 0
    $pastValidStage1.name = 0
}
$pastSamples = @(1, 0, 1, 0, 1, 1)
$resetSamples = @(0, 1, 0, 1, 0, 0)
for ($frame = 0; $frame -lt $pastSamples.Count; $frame++) {
    $validOne = [long]($frame -ge 1)
    $validTwo = [long]($frame -ge 2)
    if ($resetState[$pastValidStage0.name] -ne $validOne -or
        $resetState[$pastValidStage1.name] -ne $validTwo) {
        throw "Explicit $past history guard mismatch at sample $frame under reset=$($resetSamples[$frame])"
    }
    if ($frame -ge 1 -and $resetState[$pastDataStage0.name] -ne $pastSamples[$frame - 1]) {
        throw "Explicit one-sample $past data mismatch at sample $frame"
    }
    if ($frame -ge 2 -and $resetState[$pastDataStage1.name] -ne $pastSamples[$frame - 2]) {
        throw "Explicit two-sample $past data mismatch at sample $frame"
    }

    $values = @{ a = $pastSamples[$frame]; rst = $resetSamples[$frame] }
    foreach ($name in $resetState.Keys) { $values[$name] = $resetState[$name] }
    $nextHistory = @{}
    foreach ($equation in $historyEquations) {
        $nextHistory[$equation.target] = Evaluate-Expression $equation.expression $values
    }
    foreach ($name in $nextHistory.Keys) { $resetState[$name] = $nextHistory[$name] }
}

$pastOneWarmup = & $executable --bmc $resetPastManifest --property p_past_one --frames 0
if ($LASTEXITCODE -ne 0 -or
    $pastOneWarmup -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $pastOneWarmup -notcontains 'Q3A_BMC_VACUITY VACUOUS' -or
    $pastOneWarmup -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS COMPLETE') {
    throw "One-sample `$past must be suppressed before its first prior sample exists:`n$($pastOneWarmup -join "`n")"
}
$pastOneFailure = & $executable --bmc $resetPastManifest --property p_past_one --frames 1
if ($LASTEXITCODE -ne 0 -or
    $pastOneFailure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $pastOneFailure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $pastOneFailure -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=1 name=rst width=1 value=0x1') {
    throw "One-sample `$past must become active across reset and replay its failing witness:`n$($pastOneFailure -join "`n")"
}
$pastTwoWarmup = & $executable --bmc $resetPastManifest --property p_past_two --frames 1
if ($LASTEXITCODE -ne 0 -or
    $pastTwoWarmup -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $pastTwoWarmup -notcontains 'Q3A_BMC_VACUITY VACUOUS' -or
    $pastTwoWarmup -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS COMPLETE') {
    throw "Two-sample `$past must remain suppressed until two prior samples exist:`n$($pastTwoWarmup -join "`n")"
}
$pastTwoFailure = & $executable --bmc $resetPastManifest --property p_past_two --frames 2
if ($LASTEXITCODE -ne 0 -or
    $pastTwoFailure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_VACUITY NONVACUOUS' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS COMPLETE' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=2 name=rst width=1 value=0x1' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=2 name=b width=1 value=0x0' -or
    $pastTwoFailure -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=2 name=__q3a_history_valid_stage_1 width=1 value=0x1') {
    throw "Two-sample `$past must become active across reset and replay its failing frame-2 witness:`n$($pastTwoFailure -join "`n")"
}

'PASS: nested and explicit one-/two-sample $past data and guards match frame history across reset; warm-up, BMC statuses, and replayed failures are valid.'
