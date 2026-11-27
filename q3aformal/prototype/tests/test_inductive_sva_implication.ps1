param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$proofBuildScript = Join-Path $prototypeRoot 'checker\build.ps1'
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$tempPrefix = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-sva-induction-' + [guid]::NewGuid().ToString('N'))
$proofcheck = "$tempPrefix-proofcheck.exe"

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
    if ($LASTEXITCODE -ne 0) { throw 'Q3AFormal sourcecheck build failed.' }
}
if (-not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

$manifest = Join-Path $prototypeRoot 'sva-induction-overlapped.q3a'
$pass = & $sourcecheck --prove-inductive $manifest `
    --property p_y_implies_a --output-prefix "$tempPrefix-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($pass -match '^Q3A_INDUCTION_OBLIGATION base CHECKED records=\d+$') -or
    -not ($pass -match '^Q3A_INDUCTION_OBLIGATION step CHECKED records=\d+$') -or
    -not ($pass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Same-cycle overlapped implication should produce checked base/step proofs:`n$($pass -join "`n")"
}

foreach ($suffix in @('.base.cnf', '.base.q3adrat', '.step.cnf', '.step.q3adrat')) {
    if (-not (Test-Path -LiteralPath "$tempPrefix-pass$suffix")) {
        throw "Overlapped implication proof is missing $suffix"
    }
}

$modelMatch = $pass | Where-Object {
    $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
} | Select-Object -First 1
if (-not $modelMatch) {
    throw "Overlapped implication proof must report its T-IR identity:`n$($pass -join "`n")"
}
$modelHash = ($modelMatch -split ' ')[1]
& $proofBuildScript -Compiler $Compiler -Output $proofcheck
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $proofcheck)) {
    throw 'Standalone proof checker build failed.'
}
foreach ($obligation in @('base', 'step')) {
    $checked = & $proofcheck --check-drat `
        "$tempPrefix-pass.$obligation.cnf" `
        "$tempPrefix-pass.$obligation.q3adrat" `
        --model-sha256 $modelHash --query-kind "induction-$obligation"
    if ($LASTEXITCODE -ne 0 -or
        -not ($checked -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
        throw "Standalone checker rejected the overlapped implication $obligation proof:`n$($checked -join "`n")"
    }
}

$k2Pass = & $sourcecheck --prove-inductive $manifest `
    --property p_y_implies_a --k 2 --output-prefix "$tempPrefix-pass-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($k2Pass -contains 'Q3A_INDUCTION_DEPTH 2') -or
    -not ($k2Pass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Depth-2 overlapped implication should produce a checked proof:`n$($k2Pass -join "`n")"
}

$falseProperty = & $sourcecheck --prove-inductive $manifest `
    --property p_false_implication --output-prefix "$tempPrefix-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($falseProperty -match '^Q3A_INDUCTION_OBLIGATION base SAT$') -or
    -not ($falseProperty -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0') -or
    -not ($falseProperty -contains 'Q3A_INDUCTION_STATUS FAIL')) {
    throw "False overlapped implication should produce a replayed base counterexample:`n$($falseProperty -join "`n")"
}

$falseWitness = Get-Content -LiteralPath "$tempPrefix-fail.base.witness.txt" -Raw
if ($falseWitness -notmatch 'property p_false_implication frame=0 value=FALSE') {
    throw "Implication counterexample witness must identify the failing sample:`n$falseWitness"
}

$assumptionManifest = Join-Path $prototypeRoot 'sva-induction-overlapped-assumption.q3a'
$assumptionProof = & $sourcecheck --prove-inductive $assumptionManifest `
    --property p_assumption_consequence --output-prefix "$tempPrefix-assumption"
if ($LASTEXITCODE -ne 0 -or
    -not ($assumptionProof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Same-cycle overlapped assumption should constrain the induction query:`n$($assumptionProof -join "`n")"
}

$pastManifest = Join-Path $prototypeRoot 'sva-induction-overlapped-past.q3a'
$pastProof = & $sourcecheck --prove-inductive $pastManifest `
    --property p_q_tracks_past --output-prefix "$tempPrefix-past"
if ($LASTEXITCODE -ne 0 -or
    -not ($pastProof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Stateful overlapped implication with a guarded `$past consequent should prove inductively:`n$($pastProof -join "`n")"
}

$zeroDelayManifest = Join-Path $prototypeRoot 'sva-induction-zero-delay.q3a'
$zeroDelayPass = & $sourcecheck --prove-inductive $zeroDelayManifest `
    --property p_y_pair_implies_pair --output-prefix "$tempPrefix-zero-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroDelayPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Same-sample `##0` conjunction implication should prove:`n$($zeroDelayPass -join "`n")"
}

$zeroDelayFail = & $sourcecheck --prove-inductive $zeroDelayManifest `
    --property p_false_zero_delay --output-prefix "$tempPrefix-zero-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroDelayFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($zeroDelayFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "False same-sample `##0` implication should replay its base counterexample:`n$($zeroDelayFail -join "`n")"
}

$zeroDelayScalarFail = & $sourcecheck --prove-inductive $zeroDelayManifest `
    --property p_scalar_zero_delay_pair --output-prefix "$tempPrefix-zero-scalar-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroDelayScalarFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($zeroDelayScalarFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "False scalar same-sample `##0` sequence should replay its base counterexample:`n$($zeroDelayScalarFail -join "`n")"
}

$zeroDelayScalarPass = & $sourcecheck --prove-inductive $zeroDelayManifest `
    --property p_scalar_zero_delay_true --output-prefix "$tempPrefix-zero-scalar-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroDelayScalarPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "True scalar same-sample `##0` sequence should prove:`n$($zeroDelayScalarPass -join "`n")"
}

$zeroAssumptionManifest = Join-Path $prototypeRoot 'sva-induction-zero-delay-assumption.q3a'
$zeroAssumptionProof = & $sourcecheck --prove-inductive $zeroAssumptionManifest `
    --property p_assumption_pair_consequence --output-prefix "$tempPrefix-zero-assumption"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroAssumptionProof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Same-sample `##0` implication assumption should constrain induction:`n$($zeroAssumptionProof -join "`n")"
}

$zeroScalarAssumptionProof = & $sourcecheck --prove-inductive $zeroAssumptionManifest `
    --property p_scalar_assumption_consequence --output-prefix "$tempPrefix-zero-scalar-assumption"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroScalarAssumptionProof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Same-sample `##0` scalar assumption should constrain induction:`n$($zeroScalarAssumptionProof -join "`n")"
}

$zeroAssumptionReplayFail = & $sourcecheck --prove-inductive $zeroAssumptionManifest `
    --property p_false_under_zero_delay_assumption `
    --output-prefix "$tempPrefix-zero-assumption-replay-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($zeroAssumptionReplayFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($zeroAssumptionReplayFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "Same-sample assumptions must be checked during independent replay of a reachable failure:`n$($zeroAssumptionReplayFail -join "`n")"
}

$nonoverlappedManifest = Join-Path $prototypeRoot 'sva-induction-nonoverlapped.q3a'
$nonoverlappedPass = & $sourcecheck --prove-inductive $nonoverlappedManifest `
    --property p_pair_implies_next_q --output-prefix "$tempPrefix-nonoverlap-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A one-cycle non-overlapped implication over same-sample sequences should prove:`n$($nonoverlappedPass -join "`n")"
}
$nonoverlappedModelMatch = $nonoverlappedPass | Where-Object {
    $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
} | Select-Object -First 1
if (-not $nonoverlappedModelMatch) {
    throw "Non-overlapped proof must report its T-IR identity:`n$($nonoverlappedPass -join "`n")"
}
$nonoverlappedModelHash = ($nonoverlappedModelMatch -split ' ')[1]
foreach ($obligation in @('base', 'step')) {
    $nonoverlappedChecked = & $proofcheck --check-drat `
        "$tempPrefix-nonoverlap-pass.$obligation.cnf" `
        "$tempPrefix-nonoverlap-pass.$obligation.q3adrat" `
        --model-sha256 $nonoverlappedModelHash --query-kind "induction-$obligation"
    if ($LASTEXITCODE -ne 0 -or
        -not ($nonoverlappedChecked -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
        throw "Standalone checker rejected the non-overlapped $obligation proof:`n$($nonoverlappedChecked -join "`n")"
    }
}

$nonoverlappedK2Pass = & $sourcecheck --prove-inductive $nonoverlappedManifest `
    --property p_pair_implies_next_q --k 2 `
    --output-prefix "$tempPrefix-nonoverlap-pass-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedK2Pass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Depth-2 one-cycle non-overlapped implication should prove:`n$($nonoverlappedK2Pass -join "`n")"
}

$nonoverlappedFail = & $sourcecheck --prove-inductive $nonoverlappedManifest `
    --property p_false_next_input --output-prefix "$tempPrefix-nonoverlap-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($nonoverlappedFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A false non-overlapped implication should produce a replayed base failure at its start frame:`n$($nonoverlappedFail -join "`n")"
}

$nonoverlappedAssumptionManifest = Join-Path $prototypeRoot 'sva-induction-nonoverlapped-assumption.q3a'
$nonoverlappedAssumptionProof = & $sourcecheck --prove-inductive `
    $nonoverlappedAssumptionManifest --property p_target_next `
    --output-prefix "$tempPrefix-nonoverlap-assumption"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedAssumptionProof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A one-sample non-overlapped assumption must constrain induction through its in-bound successor:`n$($nonoverlappedAssumptionProof -join "`n")"
}

$nonoverlappedAssumptionK2 = & $sourcecheck --prove-inductive `
    $nonoverlappedAssumptionManifest --property p_target_next --k 2 `
    --output-prefix "$tempPrefix-nonoverlap-assumption-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedAssumptionK2 -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "Depth-2 non-overlapped assumptions must cover complete successor pairs in the step window:`n$($nonoverlappedAssumptionK2 -join "`n")"
}

$nonoverlappedAssumptionFail = & $sourcecheck --prove-inductive `
    $nonoverlappedAssumptionManifest --property p_false_target_under_next_assumption `
    --output-prefix "$tempPrefix-nonoverlap-assumption-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlappedAssumptionFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($nonoverlappedAssumptionFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "Non-overlapped assumptions must be checked when replaying a reachable failure:`n$($nonoverlappedAssumptionFail -join "`n")"
}

$nonoverlappedPastManifest = Join-Path $prototypeRoot 'sva-induction-nonoverlapped-past.q3a'
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$nonoverlappedPast = & $sourcecheck --prove-inductive `
    $nonoverlappedPastManifest --property p_next_past `
    --output-prefix "$tempPrefix-nonoverlap-past" 2>&1
$nonoverlappedPastExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedPreference
if ($nonoverlappedPastExitCode -ne 0 -or
    -not ($nonoverlappedPast -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A non-overlapped target using `$past in its consequent must prove when its history guard is active at the consequent sample:`n$($nonoverlappedPast -join "`n")"
}

$delayOneManifest = Join-Path $prototypeRoot 'sva-induction-delay-one.q3a'
$singleDelayPass = & $sourcecheck --prove-inductive $delayOneManifest `
    --property p_constant_one_delay --output-prefix "$tempPrefix-one-delay-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($singleDelayPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A tautologically true one-sample delayed sequence should prove:`n$($singleDelayPass -join "`n")"
}

$delayOnePass = & $sourcecheck --prove-inductive $delayOneManifest `
    --property p_constant_delayed_sequence --output-prefix "$tempPrefix-delay-one-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayOnePass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A tautologically true scalar sequence with fixed delay and repetition should prove:`n$($delayOnePass -join "`n")"
}

$delayOneK2Pass = & $sourcecheck --prove-inductive $delayOneManifest `
    --property p_constant_delayed_sequence --k 2 `
    --output-prefix "$tempPrefix-delay-one-pass-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayOneK2Pass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A tautologically true fixed-delay/repetition sequence should prove at depth 2:`n$($delayOneK2Pass -join "`n")"
}

$delayOneFail = & $sourcecheck --prove-inductive $delayOneManifest `
    --property p_false_delayed_sequence --output-prefix "$tempPrefix-delay-one-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayOneFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($delayOneFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A false fixed-delay/repetition assertion should replay its failure at the property start frame:`n$($delayOneFail -join "`n")"
}

$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$tooLongHorizon = & $sourcecheck --prove-inductive $delayOneManifest `
    --property p_constant_delayed_sequence --k 9997 `
    --output-prefix "$tempPrefix-too-long-horizon" 2>&1
$tooLongHorizonExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedPreference
if ($tooLongHorizonExitCode -ne 1 -or
    -not (($tooLongHorizon -join "`n") -match 'induction depth plus the target horizon exceeds the supported profile')) {
    throw "A target horizon that exceeds the transition limit must be rejected:`n$($tooLongHorizon -join "`n")"
}

$variableRepeatManifest = Join-Path $prototypeRoot 'sva-induction-variable-repeat.q3a'
$variableRepeatPass = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_any_repeat_path_matches_q `
    --output-prefix "$tempPrefix-variable-repeat-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($variableRepeatPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A bounded-repetition sequence with one satisfying match path should prove:`n$($variableRepeatPass -join "`n")"
}

$variableRepeatK2Pass = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_any_repeat_path_matches_q --k 2 `
    --output-prefix "$tempPrefix-variable-repeat-pass-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($variableRepeatK2Pass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A bounded-repetition sequence should preserve its path semantics at depth 2:`n$($variableRepeatK2Pass -join "`n")"
}

$variableRepeatFail = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_false_variable_repetition `
    --output-prefix "$tempPrefix-variable-repeat-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($variableRepeatFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($variableRepeatFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A false variable-repetition assertion should replay at its property-start frame:`n$($variableRepeatFail -join "`n")"
}

$delayedOverlappedPass = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_delayed_overlapped_implication `
    --output-prefix "$tempPrefix-delayed-overlapped-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedOverlappedPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A delayed/repeated overlapped implication should prove against its match endpoint:`n$($delayedOverlappedPass -join "`n")"
}

$delayedOverlappedK2 = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_delayed_overlapped_implication --k 2 `
    --output-prefix "$tempPrefix-delayed-overlapped-k2"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedOverlappedK2 -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A delayed/repeated overlapped implication should preserve its horizon at depth 2:`n$($delayedOverlappedK2 -join "`n")"
}

$delayedNonoverlappedPass = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_delayed_nonoverlapped_implication `
    --output-prefix "$tempPrefix-delayed-nonoverlapped-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedNonoverlappedPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A delayed/repeated non-overlapped implication should prove with successor sampling:`n$($delayedNonoverlappedPass -join "`n")"
}

$delayedImplicationFail = & $sourcecheck --prove-inductive $variableRepeatManifest `
    --property p_false_delayed_implication `
    --output-prefix "$tempPrefix-delayed-implication-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedImplicationFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($delayedImplicationFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A false fixed-delay implication should replay at its property-start frame:`n$($delayedImplicationFail -join "`n")"
}

$delayedAssumptionManifest = Join-Path $prototypeRoot 'sva-induction-delayed-assumptions.q3a'
$delayedSequenceAssumptionPass = & $sourcecheck --prove-inductive `
    $delayedAssumptionManifest --property p_sequence_target `
    --output-prefix "$tempPrefix-delayed-sequence-assumption-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedSequenceAssumptionPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A delayed sequence assumption must constrain each complete proof-window start:`n$($delayedSequenceAssumptionPass -join "`n")"
}

$delayedImplicationAssumptionPass = & $sourcecheck --prove-inductive `
    $delayedAssumptionManifest --property p_implication_target `
    --output-prefix "$tempPrefix-delayed-implication-assumption-pass"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedImplicationAssumptionPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
    throw "A delayed implication assumption must constrain every complete antecedent match:`n$($delayedImplicationAssumptionPass -join "`n")"
}

$delayedAssumptionReplayFail = & $sourcecheck --prove-inductive `
    $delayedAssumptionManifest --property p_false_target_under_delayed_assumptions `
    --output-prefix "$tempPrefix-delayed-assumption-replay-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($delayedAssumptionReplayFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($delayedAssumptionReplayFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A delayed-assumption counterexample must satisfy both assumptions during independent replay:`n$($delayedAssumptionReplayFail -join "`n")"
}

$guardedDelayedAssumptionManifest = Join-Path $prototypeRoot 'sva-induction-delayed-guarded-assumption.q3a'
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$guardedDelayedAssumption = & $sourcecheck --prove-inductive `
    $guardedDelayedAssumptionManifest --property p_target `
    --output-prefix "$tempPrefix-guarded-delayed-assumption" 2>&1
$guardedDelayedAssumptionExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedPreference
if ($guardedDelayedAssumptionExitCode -ne 0 -or
    -not ($guardedDelayedAssumption -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($guardedDelayedAssumption -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A delayed assumption with guarded `$past must be modeled and independently replayed:`n$($guardedDelayedAssumption -join "`n")"
}

$variableDelayManifest = Join-Path $prototypeRoot 'sva-induction-variable-delay.q3a'
foreach ($property in @(
    'p_delay_1_to_2_matches_q',
    'p_delay_0_to_1_matches_q',
    'p_exact_delay_range',
    'p_parameterized_delay_range',
    'p_range_overlapped_implication',
    'p_range_nonoverlapped_implication',
    'p_range_in_consequent'
)) {
    $rangePass = & $sourcecheck --prove-inductive $variableDelayManifest `
        --property $property --output-prefix "$tempPrefix-range-$property"
    if ($LASTEXITCODE -ne 0 -or
        -not ($rangePass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "A finite delay-range property should prove: $property`n$($rangePass -join "`n")"
    }
}

$rangeBmcFail = & $sourcecheck --bmc $variableDelayManifest `
    --property p_false_variable_delay --frames 2
if ($LASTEXITCODE -ne 0 -or
    -not ($rangeBmcFail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($rangeBmcFail -contains 'Q3A_BMC_REPLAY VALIDATED') -or
    -not ($rangeBmcFail -contains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE')) {
    throw "A standalone variable-delay sequence counterexample must pass independent replay:`n$($rangeBmcFail -join "`n")"
}

$variableDelayAssumptionManifest = Join-Path $prototypeRoot `
    'sva-induction-variable-delay-assumptions.q3a'
foreach ($property in @('p_sequence_target', 'p_implication_target')) {
    $rangeAssumptionPass = & $sourcecheck --prove-inductive `
        $variableDelayAssumptionManifest --property $property `
        --output-prefix "$tempPrefix-range-assumption-$property"
    if ($LASTEXITCODE -ne 0 -or
        -not ($rangeAssumptionPass -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "A finite delay-range assumption should prove $property`n$($rangeAssumptionPass -join "`n")"
    }
}

$rangeAssumptionReplayFail = & $sourcecheck --prove-inductive `
    $variableDelayAssumptionManifest `
    --property p_false_target_under_delay_assumptions `
    --output-prefix "$tempPrefix-range-assumption-replay-fail"
if ($LASTEXITCODE -ne 0 -or
    -not ($rangeAssumptionReplayFail -contains 'Q3A_INDUCTION_STATUS FAIL') -or
    -not ($rangeAssumptionReplayFail -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
    throw "A delay-range assumption counterexample must replay against the complete environment:`n$($rangeAssumptionReplayFail -join "`n")"
}

$compoundManifest = Join-Path $prototypeRoot 'lower-sva-compound-exact-repeat.q3a'
$compoundBundle = "$tempPrefix-compound-bundle"
$compoundPass = @(& $sourcecheck --prove-inductive $compoundManifest --property p_range_guarded `
    --output-prefix "$tempPrefix-compound-pass" --bundle-dir $compoundBundle)
if ($LASTEXITCODE -ne 0 -or $compoundPass -notcontains 'Q3A_INDUCTION_STATUS PROVEN' -or
    ($compoundPass -join "`n") -notmatch '(?m)^Q3A_INDUCTION_OBLIGATION base CHECKED records=' -or
    ($compoundPass -join "`n") -notmatch '(?m)^Q3A_INDUCTION_OBLIGATION step CHECKED records=') {
    throw "Compound repeat with guarded history did not produce a checked proof:`n$($compoundPass -join "`n")"
}
$compoundReopened = @(& $sourcecheck --verify-bundle $compoundBundle)
if ($LASTEXITCODE -ne 0 -or $compoundReopened -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
    throw "Compound repeat proof bundle did not revalidate:`n$($compoundReopened -join "`n")"
}
$compoundFail = @(& $sourcecheck --prove-inductive $compoundManifest --property p_range_wrong `
    --output-prefix "$tempPrefix-compound-fail")
if ($LASTEXITCODE -ne 0 -or $compoundFail -notcontains 'Q3A_INDUCTION_STATUS FAIL' -or
    $compoundFail -notcontains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0') {
    throw "Compound repeat did not replay the incorrect implication:`n$($compoundFail -join "`n")"
}

'PASS: scalar, delay range, ranged compound repeat, implication and assumption induction, with checked evidence and replay.'
