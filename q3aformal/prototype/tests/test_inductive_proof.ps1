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
    'q3aformal-induction-' + [guid]::NewGuid().ToString('N'))
$proofcheck = "$tempPrefix-proofcheck.exe"
$ErrorActionPreference = 'Stop'

try {
    if (!$UseExistingBuild) {
        & $buildScript -Compiler $Compiler
    }
    if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
        throw 'Q3AFormal sourcecheck build failed.'
    }

    $manifest = Join-Path $prototypeRoot 'known-pass-combinational.q3a'
    $proofOutput = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --output-prefix $tempPrefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($proofOutput -contains 'Q3A_INDUCTION_STATUS PROVEN') -or
        -not ($proofOutput -contains 'Q3A_INDUCTION_CERTIFICATE INDUCTIVE_PROOF_ACCEPTED') -or
        -not ($proofOutput -contains 'Q3A_INDUCTION_SCOPE GENERATED_TIR_MODEL') -or
        -not ($proofOutput | Where-Object {
            $_ -match '^Q3A_INDUCTION_OBLIGATION base CHECKED records=\d+$'
        }) -or
        -not ($proofOutput | Where-Object {
            $_ -match '^Q3A_INDUCTION_OBLIGATION step CHECKED records=\d+$'
        })) {
        throw "The known combinational invariant should produce checked base and step proofs:`n$($proofOutput -join "`n")"
    }

    foreach ($suffix in @('.base.cnf', '.base.q3adrat', '.step.cnf', '.step.q3adrat')) {
        if (-not (Test-Path -LiteralPath "$tempPrefix$suffix")) {
            throw "Induction evidence is missing $suffix"
        }
    }
    $modelMatch = $proofOutput | Where-Object {
        $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
    } | Select-Object -First 1
    if (-not $modelMatch) {
        throw "Induction result must identify the canonical T-IR hash:`n$($proofOutput -join "`n")"
    }
    $modelHash = ($modelMatch -split ' ')[1]
    if (-not ($proofOutput | Where-Object {
        $_ -match '^Q3A_INDUCTION_INPUT_SHA256 [0-9a-f]{64}$'
    })) {
        throw "Induction result must identify the source-set input hash:`n$($proofOutput -join "`n")"
    }

    & $proofBuildScript -Compiler $Compiler -Output $proofcheck
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $proofcheck)) {
        throw 'Standalone proof checker build failed.'
    }
    foreach ($obligation in @('base', 'step')) {
        $checked = & $proofcheck --check-drat `
            "$tempPrefix.$obligation.cnf" "$tempPrefix.$obligation.q3adrat" `
            --model-sha256 $modelHash --query-kind "induction-$obligation"
        if ($LASTEXITCODE -ne 0 -or
            -not ($checked -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
            throw "Standalone checker rejected the $obligation proof:`n$($checked -join "`n")"
        }
    }

    $k2Prefix = "$tempPrefix-k2"
    $k2Proof = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --k 2 --output-prefix $k2Prefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($k2Proof -contains 'Q3A_INDUCTION_DEPTH 2') -or
        -not ($k2Proof -contains 'Q3A_INDUCTION_BASE_FRAMES 0..1') -or
        -not ($k2Proof -contains 'Q3A_INDUCTION_STEP_FRAMES 0..2') -or
        -not ($k2Proof -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "A depth-2 induction must build the full base prefix and k-step obligation:`n$($k2Proof -join "`n")"
    }
    $k2ModelMatch = $k2Proof | Where-Object {
        $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
    } | Select-Object -First 1
    $k2ModelHash = ($k2ModelMatch -split ' ')[1]
    foreach ($obligation in @('base', 'step')) {
        $checkedK2 = & $proofcheck --check-drat `
            "$k2Prefix.$obligation.cnf" "$k2Prefix.$obligation.q3adrat" `
            --model-sha256 $k2ModelHash --query-kind "induction-k2-$obligation"
        if ($LASTEXITCODE -ne 0 -or
            -not ($checkedK2 -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
            throw "Standalone checker rejected the depth-2 $obligation proof:`n$($checkedK2 -join "`n")"
        }
    }
    $assumptionK2Prefix = "$tempPrefix-assumption-k2"
    $assumptionManifest = Join-Path $prototypeRoot 'bmc-assumption.q3a'
    $assumptionK2 = & $sourcecheck --prove-inductive $assumptionManifest `
        --property p_assert_a --k 2 --output-prefix $assumptionK2Prefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($assumptionK2 -match '^Q3A_INDUCTION_OBLIGATION base CHECKED records=\d+$') -or
        -not ($assumptionK2 -match '^Q3A_INDUCTION_OBLIGATION step CHECKED records=\d+$') -or
        -not ($assumptionK2 -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "Depth-2 assumptions must constrain each base frame and the terminal step frame:`n$($assumptionK2 -join "`n")"
    }
    $assumptionModelMatch = $assumptionK2 | Where-Object {
        $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
    } | Select-Object -First 1
    $assumptionModelHash = ($assumptionModelMatch -split ' ')[1]
    foreach ($obligation in @('base', 'step')) {
        $checkedAssumptionK2 = & $proofcheck --check-drat `
            "$assumptionK2Prefix.$obligation.cnf" `
            "$assumptionK2Prefix.$obligation.q3adrat" `
            --model-sha256 $assumptionModelHash `
            --query-kind "induction-k2-$obligation"
        if ($LASTEXITCODE -ne 0 -or
            -not ($checkedAssumptionK2 -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
            throw "Standalone checker rejected the assumed depth-2 $obligation proof:`n$($checkedAssumptionK2 -join "`n")"
        }
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $invalidDepth = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --k 0 --output-prefix "$tempPrefix-k0" 2>&1
    $invalidDepthExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($invalidDepthExitCode -eq 0 -or
        -not (($invalidDepth -join "`n") -match 'induction depth must be between 1 and 10000')) {
        throw "A zero induction depth must be rejected before creating evidence:`n$($invalidDepth -join "`n")"
    }

    $nonInductivePrefix = "$tempPrefix-noninductive"
    $scalarManifest = Join-Path $prototypeRoot 'bmc-scalar.q3a'
    $nonInductive = & $sourcecheck --prove-inductive $scalarManifest `
        --property p_can_fail --output-prefix $nonInductivePrefix
    if (-not ($nonInductive -contains 'Q3A_INDUCTION_STATUS FAIL') -or
        -not ($nonInductive -contains 'Q3A_INDUCTION_OBLIGATION base SAT') -or
        -not ($nonInductive -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
        throw "A replayed reachable base failure must be reported as FAIL:`n$($nonInductive -join "`n")"
    }
    if (Test-Path -LiteralPath "$nonInductivePrefix.base.q3adrat") {
        throw 'A SAT base obligation must not produce a DRAT artifact.'
    }
    $baseWitnessPath = "$nonInductivePrefix.base.witness.txt"
    if (-not (Test-Path -LiteralPath $baseWitnessPath)) {
        throw 'A SAT base obligation must preserve a frame-indexed witness.'
    }
    $baseWitness = Get-Content -LiteralPath $baseWitnessPath -Raw
    if ($baseWitness -notmatch 'signal a width=1 value=0x0') {
        throw "SAT witness must decode the violated scalar input value:`n$baseWitness"
    }

    $sequencePrefix = "$tempPrefix-sequence"
    $sequenceManifest = Join-Path $prototypeRoot 'lower-sva-alignment.q3a'
    $sequenceCounterexample = & $sourcecheck --prove-inductive $sequenceManifest `
        --property p_overlapped_chain --output-prefix $sequencePrefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($sequenceCounterexample -contains 'Q3A_INDUCTION_STATUS FAIL') -or
        -not ($sequenceCounterexample -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=0')) {
        throw "A fixed-delay implication counterexample must be found and replayed:`n$($sequenceCounterexample -join "`n")"
    }

    $pastPrefix = "$tempPrefix-past"
    $pastManifest = Join-Path $prototypeRoot 'bmc-past.q3a'
    $pastNonInductive = & $sourcecheck --prove-inductive $pastManifest `
        --property p_past_a --output-prefix $pastPrefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($pastNonInductive -contains 'Q3A_INDUCTION_OBLIGATION base UNSAT') -or
        -not ($pastNonInductive -contains 'Q3A_INDUCTION_OBLIGATION step SAT') -or
        -not ($pastNonInductive -contains 'Q3A_INDUCTION_REPLAY step VALIDATED frame=1') -or
        -not ($pastNonInductive -contains 'Q3A_INDUCTION_STATUS NOT_1_INDUCTIVE')) {
        throw "A guarded `$past property should be analyzed and report its failed induction step:`n$($pastNonInductive -join "`n")"
    }

    $pastK2Prefix = "$tempPrefix-past-k2"
    $pastK2 = & $sourcecheck --prove-inductive $pastManifest `
        --property p_past_a --k 2 --output-prefix $pastK2Prefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($pastK2 -contains 'Q3A_INDUCTION_OBLIGATION base SAT') -or
        -not ($pastK2 -contains 'Q3A_INDUCTION_REPLAY base VALIDATED frame=1') -or
        -not ($pastK2 -contains 'Q3A_INDUCTION_STATUS FAIL') -or
        -not (Test-Path -LiteralPath "$pastK2Prefix.base.witness.txt")) {
        throw "Depth-2 base checking must find the guarded-past property failure in the required prefix:`n$($pastK2 -join "`n")"
    }
    $pastK2Witness = Get-Content -LiteralPath "$pastK2Prefix.base.witness.txt" -Raw
    if ($pastK2Witness -notmatch 'property p_past_a frame=1 value=FALSE') {
        throw "The depth-2 base witness must identify the failing history-valid frame:`n$pastK2Witness"
    }

    $pastTautologyPrefix = "$tempPrefix-past-tautology"
    $pastTautology = & $sourcecheck --prove-inductive $pastManifest `
        --property p_past_tautology --output-prefix $pastTautologyPrefix
    if ($LASTEXITCODE -ne 0 -or
        -not ($pastTautology -match '^Q3A_INDUCTION_OBLIGATION base CHECKED records=\d+$') -or
        -not ($pastTautology -match '^Q3A_INDUCTION_OBLIGATION step CHECKED records=\d+$') -or
        -not ($pastTautology -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "A guarded tautological `$past property should produce checked base and step proofs:`n$($pastTautology -join "`n")"
    }
    $pastModelMatch = $pastTautology | Where-Object {
        $_ -match '^Q3A_INDUCTION_MODEL_SHA256 ([0-9a-f]{64})$'
    } | Select-Object -First 1
    $pastModelHash = ($pastModelMatch -split ' ')[1]
    foreach ($obligation in @('base', 'step')) {
        $checkedPast = & $proofcheck --check-drat `
            "$pastTautologyPrefix.$obligation.cnf" `
            "$pastTautologyPrefix.$obligation.q3adrat" `
            --model-sha256 $pastModelHash --query-kind "induction-$obligation"
        if ($LASTEXITCODE -ne 0 -or
            -not ($checkedPast -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
            throw "Standalone checker rejected guarded-past $obligation proof:`n$($checkedPast -join "`n")"
        }
    }

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $overwrite = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --output-prefix $tempPrefix 2>&1
    $overwriteExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($overwriteExitCode -eq 0 -or
        -not (($overwrite -join "`n") -match 'output already exists')) {
        throw "Induction command must refuse to overwrite evidence:`n$($overwrite -join "`n")"
    }
} finally {
    foreach ($path in @(
        $proofcheck,
        "$tempPrefix.base.cnf", "$tempPrefix.base.q3adrat",
        "$tempPrefix.step.cnf", "$tempPrefix.step.q3adrat",
        "$tempPrefix-noninductive.base.cnf", "$tempPrefix-noninductive.base.q3adrat",
        "$tempPrefix-noninductive.step.cnf", "$tempPrefix-noninductive.step.q3adrat",
        "$tempPrefix-noninductive.base.witness.txt",
        "$tempPrefix-noninductive.step.witness.txt",
        "$tempPrefix-k2.base.cnf", "$tempPrefix-k2.base.q3adrat",
        "$tempPrefix-k2.step.cnf", "$tempPrefix-k2.step.q3adrat",
        "$tempPrefix-assumption-k2.base.cnf", "$tempPrefix-assumption-k2.base.q3adrat",
        "$tempPrefix-assumption-k2.step.cnf", "$tempPrefix-assumption-k2.step.q3adrat",
        "$tempPrefix-sequence.base.cnf", "$tempPrefix-sequence.base.q3adrat",
        "$tempPrefix-sequence.step.cnf", "$tempPrefix-sequence.step.q3adrat",
        "$tempPrefix-past.base.cnf", "$tempPrefix-past.base.q3adrat",
        "$tempPrefix-past.step.cnf", "$tempPrefix-past.step.q3adrat",
        "$tempPrefix-past.step.witness.txt",
        "$tempPrefix-past-tautology.base.cnf", "$tempPrefix-past-tautology.base.q3adrat",
        "$tempPrefix-past-tautology.step.cnf", "$tempPrefix-past-tautology.step.q3adrat",
        "$tempPrefix-past-k2.base.cnf", "$tempPrefix-past-k2.base.q3adrat",
        "$tempPrefix-past-k2.step.cnf", "$tempPrefix-past-k2.step.q3adrat",
        "$tempPrefix-past-k2.base.witness.txt", "$tempPrefix-past-k2.step.witness.txt"
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

'PASS: one- and two-step induction base/step obligations, guarded $past cases, witnesses, and standalone DRAT checks behave as expected.'
