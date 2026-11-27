param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $prototypeRoot 'bin'
$repoRoot = Split-Path -Parent $prototypeRoot
$sourcecheck = Join-Path $outputRoot 'q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$archivedPassBundle = Join-Path $repoRoot 'evidence\known-pass\run-bundle-2026-11-19-v3'
$failBundle = Join-Path $repoRoot 'evidence\known-fail\run-bundle-2026-11-16-v2'
$tempRoot = Join-Path $outputRoot ('q3a-open-' + [guid]::NewGuid().ToString('N'))
$passBundle = Join-Path $tempRoot 'fresh'
$longBundle = Join-Path (Join-Path $tempRoot ('deep-' + ('x' * 95))) ('bundle-' + ('y' * 95))
$pastBundle = Join-Path $outputRoot ('q3a-past-reopen-' + [guid]::NewGuid().ToString('N'))
$coverBundle = Join-Path $outputRoot ('q3a-cover-reopen-' + [guid]::NewGuid().ToString('N'))
$boundedPassBundle = Join-Path $outputRoot ('q3a-bmc-pass-reopen-' + [guid]::NewGuid().ToString('N'))
$vacuousBundle = Join-Path $tempRoot 'vacuous'
$coverMissBundle = Join-Path $outputRoot ('q3a-cover-miss-reopen-' + [guid]::NewGuid().ToString('N'))
$tamperedBundle = Join-Path $tempRoot 'tampered'
$tamperedTraceBundle = Join-Path $tempRoot 'tampered-trace'
$escapedBundle = Join-Path $tempRoot 'escaped'
$incompatibleBundle = Join-Path $tempRoot 'incompatible'
$incompatibleSatBundle = Join-Path $tempRoot 'incompatible-sat'

try {
    if (!$UseExistingBuild) {
        & $buildScript -Compiler $Compiler
        if ($LASTEXITCODE -ne 0) { throw 'Q3AFormal sourcecheck build failed.' }
    }
    if (-not (Test-Path -LiteralPath $sourcecheck)) {
        throw 'Q3AFormal sourcecheck build failed.'
    }
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    if ($longBundle.Length -le 260) { throw 'The long bundle test path is too short.' }
    $longProof = @(& $sourcecheck --prove-inductive (Join-Path $prototypeRoot 'counter4.q3a') `
        --property p_wraps_to_zero --output-prefix (Join-Path $tempRoot 'long-proof') --bundle-dir $longBundle)
    if ($LASTEXITCODE -ne 0 -or $longProof -notcontains 'Q3A_INDUCTION_STATUS PROVEN') {
        throw "Could not publish the proof bundle at a long Windows path:`n$($longProof -join "`n")"
    }
    $longReopen = @(& $sourcecheck --verify-bundle $longBundle)
    if ($LASTEXITCODE -ne 0 -or $longReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $longReopen -notcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        @($longReopen | Where-Object { $_ -match '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED ' }).Count -ne 2) {
        throw "Long-path bundle did not revalidate:`n$($longReopen -join "`n")"
    }
    $nativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $alreadyExists = @(& $sourcecheck --prove-inductive (Join-Path $prototypeRoot 'counter4.q3a') `
            --property p_wraps_to_zero --output-prefix (Join-Path $tempRoot 'blocked-proof') `
            --bundle-dir $longBundle 2>&1)
        if ($LASTEXITCODE -ne 1 -or $alreadyExists -contains 'Q3A_INDUCTION_STATUS PROVEN' -or
            !($alreadyExists -match 'bundle output already exists')) {
            throw "Publication failure emitted a successful final status:`n$($alreadyExists -join "`n")"
        }
        $occupiedBundle = Join-Path $tempRoot 'occupied-bmc'
        New-Item -ItemType Directory -Path $occupiedBundle | Out-Null
        $sentinel = Join-Path $occupiedBundle 'existing.txt'
        Set-Content -LiteralPath $sentinel -Value 'preserve existing output' -NoNewline
        foreach ($case in @(
            @{ Manifest = 'bmc-scalar.q3a'; Property = 'p_always_true'; Frames = 1 },
            @{ Manifest = 'counter4-fail.q3a'; Property = 'p_wraps_to_zero'; Frames = 1 },
            @{ Manifest = 'lower-sva-sequences.q3a'; Property = 'property_check_12'; Frames = 2 },
            @{ Manifest = 'lower-sva-sequences.q3a'; Property = 'property_check_12'; Frames = 0 },
            @{ Manifest = 'bmc-conflict.q3a'; Property = 'p_assert_a'; Frames = 1 }
        )) {
            $collision = @(& $sourcecheck --bmc (Join-Path $prototypeRoot $case.Manifest) `
                --property $case.Property --frames $case.Frames --bundle-dir $occupiedBundle 2>&1)
            if ($LASTEXITCODE -ne 1 -or
                ($collision -match '^Q3A_(BMC_STATUS |BMC_REPLAY |BMC_TRACE_|BUNDLE_CREATED )') -or
                !($collision -match 'bundle output already exists')) {
                throw "BMC publication failure reported a result for $($case.Property) at $($case.Frames) frames:`n$($collision -join "`n")"
            }
        }
        if ((Get-Content -Raw -LiteralPath $sentinel) -ne 'preserve existing output' -or
            @(Get-ChildItem -LiteralPath $occupiedBundle -Force).Count -ne 1) {
            throw 'A BMC publication collision changed the existing destination.'
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativePreference
    }
    $generated = @(& $sourcecheck --prove-inductive (Join-Path $prototypeRoot 'known-pass-combinational.q3a') `
        --property p_y_implies_a --output-prefix (Join-Path $tempRoot 'proof') --bundle-dir $passBundle)
    if ($LASTEXITCODE -ne 0 -or $generated -notcontains 'Q3A_INDUCTION_STATUS PROVEN') {
        throw "Could not generate a proof bundle for the current checker:`n$($generated -join "`n")"
    }

    $pass = & $sourcecheck --verify-bundle $passBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($pass -contains 'Q3A_BUNDLE_INTEGRITY VERIFIED') -or
        -not ($pass -contains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED') -or
        -not ($pass -contains 'Q3A_BUNDLE_STATUS REVALIDATED') -or
        (@($pass | Where-Object { $_ -match '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED ' }).Count -ne 2)) {
        throw "Compatible induction proof bundles must be integrity-checked and revalidated:`n$($pass -join "`n")"
    }
    $archived = @(& $sourcecheck --verify-bundle $archivedPassBundle)
    if ($LASTEXITCODE -ne 0 -or $archived -notcontains 'Q3A_BUNDLE_INTEGRITY VERIFIED' -or
        $archived -notcontains 'Q3A_BUNDLE_SOURCE_MODEL UNVERIFIED' -or
        ($archived -notcontains 'Q3A_BUNDLE_STATUS HISTORIC' -and
         $archived -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "Archived evidence must retain its integrity verdict:`n$($archived -join "`n")"
    }

    $contextProject = Join-Path $tempRoot 'context.q3a'
    @('Q3AFORMAL_PROJECT 2', 'top context_top', 'source systemverilog "context.sv"') |
        Set-Content -LiteralPath $contextProject
    @'
module context_top(input logic sample_clk, input logic reset_n, input logic data);
    logic q;
    always_ff @(posedge sample_clk) begin
        if (!reset_n) q <= 1'b0;
        else q <= data;
    end
    env_reset: assume property (@(posedge sample_clk) !reset_n);
    env_data: assume property (@(posedge sample_clk) !data);
    p_fail: assert property (@(posedge sample_clk) data && q);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'context.sv')
    foreach ($case in @(
        @{ Engine = 'bmc'; Options = @('--frames', '1'); Status = 'BOUNDED_FAIL' },
        @{ Engine = 'induction'; Options = @('--output-prefix', (Join-Path $tempRoot 'context-proof')); Status = 'FAIL' },
        @{ Engine = 'pdr'; Options = @('--evidence-dir', (Join-Path $tempRoot 'context-certificate')); Status = 'FAIL' }
    )) {
        $contextBundle = Join-Path $tempRoot ("context-" + $case.Engine)
        $options = @('--engine', $case.Engine, '--property', 'p_fail') + $case.Options + @('--bundle-dir', $contextBundle)
        $contextLog = Join-Path $tempRoot 'context.stderr'
        $result = & $sourcecheck prove $contextProject @options 2>$contextLog | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $result.status -cne $case.Status) {
            throw "Could not produce a $($case.Engine) witness: $(Get-Content -LiteralPath $contextLog -Raw)"
        }
        $contextManifestPath = Join-Path $contextBundle 'manifest.json'
        $contextManifest = Get-Content -LiteralPath $contextManifestPath -Raw | ConvertFrom-Json
        if ($contextManifest.sampling_context.clock -cne 'sample_clk' -or
            $contextManifest.sampling_context.edge -cne 'posedge' -or
            ($contextManifest.assumptions -join ',') -cne 'env_reset,env_data' -or
            $contextManifest.reset_initial_policy -cnotmatch 'RTL initial state is unconstrained') {
            throw "Incorrect stored model context for $($case.Engine)."
        }
        $contextVerified = @(& $sourcecheck --verify-bundle $contextBundle)
        if ($LASTEXITCODE -ne 0 -or $contextVerified -cnotcontains 'Q3A_BUNDLE_MODEL_CONTEXT VERIFIED' -or
            $contextVerified -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $contextVerified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Could not revalidate model context for $($case.Engine): $contextVerified"
        }
    }
    $pristineContext = Get-Content -LiteralPath $contextManifestPath -Raw
    foreach ($mutation in @(
        @{ Apply = { param($m) $m.assumptions = @('env_data') }; Error = 'bundle manifest assumptions' },
        @{ Apply = { param($m) $m.assumptions = @('env_data','env_reset') }; Error = 'bundle manifest assumptions' },
        @{ Apply = { param($m) $m.sampling_context.clock = 'other_clk' }; Error = 'sampling clock or edge' },
        @{ Apply = { param($m) $m.sampling_context.edge = 'negedge' }; Error = 'sampling clock or edge' },
        @{ Apply = { param($m) $m.reset_initial_policy = 'RTL initial state is zero' }; Error = 'reset and initial-state policy' },
        @{ Apply = {
            param($m)
            $entry = $m.artifacts | Where-Object role -CEQ property_result
            $propertyPath = Join-Path $contextBundle $entry.path
            $property = Get-Content -LiteralPath $propertyPath -Raw | ConvertFrom-Json
            $property.assumptions = @('env_reset','env_reset')
            $property | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $propertyPath
            $entry.size_bytes = (Get-Item -LiteralPath $propertyPath).Length
            $entry.sha256 = (Get-FileHash -LiteralPath $propertyPath).Hash.ToLowerInvariant()
        }; Error = 'property report assumptions' }
    )) {
        $modified = $pristineContext | ConvertFrom-Json
        & $mutation.Apply $modified
        $modified | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $contextManifestPath
        (Get-FileHash -LiteralPath $contextManifestPath).Hash.ToLowerInvariant() |
            Set-Content -LiteralPath (Join-Path $contextBundle 'manifest.sha256') -Encoding ascii -NoNewline
        $denied = @(& $sourcecheck --verify-bundle $contextBundle 2>&1)
        if ($LASTEXITCODE -ne 1 -or !($denied -match $mutation.Error) -or
            $denied -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Reopen accepted or misdiagnosed an inconsistent model context: $denied"
        }
    }
    'PASS: BMC, k-induction, and PDR model context revalidated; six rehashed metadata mutations were rejected.'

    $sourceModelBundle = Join-Path $tempRoot 'source-model'
    $sourceModelRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'lower-sva-parameter-bounds.q3a') `
        --property p_parameter_delay --frames 0 --bundle-dir $sourceModelBundle
    if ($LASTEXITCODE -ne 0 -or $sourceModelRun -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS') {
        throw "Expected a saved parameterized assertion run:`n$($sourceModelRun -join "`n")"
    }
    $sourceModelCheck = & $sourcecheck --verify-bundle $sourceModelBundle
    if ($LASTEXITCODE -ne 0 -or $sourceModelCheck -notcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $sourceModelCheck -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Parameterized source did not regenerate the saved model:`n$($sourceModelCheck -join "`n")"
    }
    $sourceModelManifestPath = Join-Path $sourceModelBundle 'manifest.json'
    $sourceModelManifest = Get-Content -LiteralPath $sourceModelManifestPath -Raw | ConvertFrom-Json
    $sourceModelPath = Join-Path $sourceModelBundle $sourceModelManifest.model.path
    $changedModel = Get-Content -LiteralPath $sourceModelPath -Raw | ConvertFrom-Json
    $changedProperty = $changedModel.properties | Where-Object name -eq 'p_parameter_repeat'
    if ($null -eq $changedProperty) { throw 'Expected a second property in the saved model.' }
    $changedProperty.name = 'different_property'
    [IO.File]::WriteAllText($sourceModelPath, ($changedModel | ConvertTo-Json -Depth 100))
    $sourceModelManifest.model.sha256 = (Get-FileHash -LiteralPath $sourceModelPath).Hash.ToLowerInvariant()
    $sourceModelManifest.model.size_bytes = (Get-Item -LiteralPath $sourceModelPath).Length
    $sourceModelArtifact = $sourceModelManifest.artifacts | Where-Object path -eq $sourceModelManifest.model.path
    $sourceModelArtifact.sha256 = $sourceModelManifest.model.sha256
    $sourceModelArtifact.size_bytes = $sourceModelManifest.model.size_bytes
    [IO.File]::WriteAllText($sourceModelManifestPath, ($sourceModelManifest | ConvertTo-Json -Depth 100))
    $sourceModelManifestHash = (Get-FileHash -LiteralPath $sourceModelManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $sourceModelBundle 'manifest.sha256') `
        -Value $sourceModelManifestHash -NoNewline -Encoding ascii
    $changedModelCheck = @(& $sourcecheck --verify-bundle $sourceModelBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($changedModelCheck -join "`n") -notmatch 'regenerated T-IR differs from the saved model' -or
        $changedModelCheck -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "A different model with matching file hashes must fail source revalidation:`n$($changedModelCheck -join "`n")"
    }

    $fail = & $sourcecheck --verify-bundle $failBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($fail -contains 'Q3A_BUNDLE_INTEGRITY VERIFIED') -or
        -not ($fail -contains 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=2 candidate_frame=1') -or
        -not ($fail -contains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS UNVERIFIED') -or
        -not ($fail -contains 'Q3A_BUNDLE_BMC_WITNESS_QUERY UNVERIFIED') -or
        -not ($fail -contains 'Q3A_BUNDLE_SCOPE REPLAYED_BMC_WITNESS_FOR_SERIALIZED_TIR') -or
        -not ($fail -contains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "A saved BMC witness must replay independently against the bundled T-IR:`n$($fail -join "`n")"
    }

    foreach ($case in @(
        @{ Manifest = 'bmc-scalar.q3a'; Property = 'p_can_fail'; Status = 'FAIL'; Obligation = 'base' },
        @{ Manifest = 'bmc-past.q3a'; Property = 'p_past_a'; Status = 'NOT_1_INDUCTIVE'; Obligation = 'step' }
    )) {
        $witnessBundle = Join-Path $tempRoot ("induction-" + $case.Obligation)
        $witnessRun = & $sourcecheck --prove-inductive (Join-Path $prototypeRoot $case.Manifest) `
            --property $case.Property --output-prefix (Join-Path $tempRoot ("query-" + $case.Obligation)) `
            --bundle-dir $witnessBundle
        if ($LASTEXITCODE -ne 0 -or $witnessRun -notcontains "Q3A_INDUCTION_STATUS $($case.Status)") {
            throw "Unexpected induction result:`n$($witnessRun -join "`n")"
        }
        $witnessReopen = & $sourcecheck --verify-bundle $witnessBundle
        if ($LASTEXITCODE -ne 0 -or
            $witnessReopen -notcontains "Q3A_BUNDLE_INDUCTION_REPLAY VALIDATED id=$($case.Obligation)" -or
            $witnessReopen -notcontains "Q3A_BUNDLE_INDUCTION_INDEXED_TRACE VERIFIED id=$($case.Obligation)" -or
            $witnessReopen -notcontains "Q3A_BUNDLE_INDUCTION_WITNESS_QUERY VERIFIED id=$($case.Obligation)" -or
            $witnessReopen -notcontains "Q3A_BUNDLE_RESULT_STATUS $($case.Status)" -or
            $witnessReopen -notcontains 'Q3A_BUNDLE_SCOPE REPLAYED_INDUCTION_WITNESS_FOR_SERIALIZED_TIR' -or
            $witnessReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Induction witness did not reproduce its recorded scope:`n$($witnessReopen -join "`n")"
        }
        $witnessManifestPath = Join-Path $witnessBundle 'manifest.json'
        $witnessManifest = Get-Content -LiteralPath $witnessManifestPath -Raw | ConvertFrom-Json
        # Keep the historic text-only tamper cases below on the old verification path.
        $indexed = @($witnessManifest.artifacts | Where-Object role -CEQ 'indexed_induction_witness')
        foreach ($artifact in $indexed) {
            Remove-Item -LiteralPath (Join-Path $witnessBundle $artifact.path)
        }
        $witnessManifest.artifacts = @(
            $witnessManifest.artifacts | Where-Object role -CNE 'indexed_induction_witness')
        $witnessSuffix = '/' + $case.Obligation + '.witness.txt'
        $witnessArtifact = $witnessManifest.artifacts |
            Where-Object { $_.role -eq 'replay_validated_witness' -and $_.path.EndsWith($witnessSuffix) }
        $witnessFile = Join-Path $witnessBundle $witnessArtifact.path
        $originalWitness = [IO.File]::ReadAllText($witnessFile)
        if ($case.Obligation -eq 'base') {
            $changedWitness = $originalWitness.Replace('signal a width=1 value=0x0', 'signal a width=1 value=0x1')
            $expectedError = 'induction witness replay failed'
        } else {
            $witnessQuery = $witnessManifest.queries | Where-Object id -eq $case.Obligation
            $witnessCnf = Join-Path $witnessBundle $witnessQuery.cnf_path
            $originalWitnessDigest = $witnessQuery.cnf_sha256
            [IO.File]::AppendAllText($witnessCnf, "`n")
            $witnessQuery.cnf_sha256 = (Get-FileHash -LiteralPath $witnessCnf).Hash.ToLowerInvariant()
            $witnessCnfRecord = $witnessManifest.artifacts | Where-Object path -eq $witnessQuery.cnf_path
            $witnessCnfRecord.sha256 = $witnessQuery.cnf_sha256
            $witnessCnfRecord.size_bytes = (Get-Item -LiteralPath $witnessCnf).Length
            $changedWitness = $originalWitness.Replace($originalWitnessDigest, $witnessQuery.cnf_sha256)
            $expectedError = 'regenerated induction query CNF differs from the saved step obligation'
        }
        if ($changedWitness -ceq $originalWitness) { throw 'Expected the test to modify the witness.' }
        [IO.File]::WriteAllText($witnessFile, $changedWitness)
        $witnessArtifact.sha256 = (Get-FileHash -LiteralPath $witnessFile).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($witnessManifestPath, ($witnessManifest | ConvertTo-Json -Depth 100))
        $witnessManifestHash = (Get-FileHash -LiteralPath $witnessManifestPath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $witnessBundle 'manifest.sha256') `
            -Value $witnessManifestHash -NoNewline -Encoding ascii
        $invalidWitness = @(& $sourcecheck --verify-bundle $witnessBundle 2>&1)
        if ($LASTEXITCODE -ne 1 -or
            ($invalidWitness -join "`n") -notmatch $expectedError -or
            $invalidWitness -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "A rehashed witness or noncanonical query must fail revalidation:`n$($invalidWitness -join "`n")"
        }
    }

    $temporalInductionBundle = Join-Path $tempRoot 'temporal-k2'
    $temporalRun = & $sourcecheck --prove-inductive (Join-Path $prototypeRoot 'sva-induction-nonoverlapped.q3a') `
        --property p_pair_implies_next_q --k 2 --output-prefix (Join-Path $tempRoot 'temporal') `
        --bundle-dir $temporalInductionBundle
    if ($LASTEXITCODE -ne 0 -or $temporalRun -notcontains 'Q3A_INDUCTION_STATUS PROVEN') {
        throw "Expected a checked depth-2 temporal proof:`n$($temporalRun -join "`n")"
    }
    $temporalReopen = & $sourcecheck --verify-bundle $temporalInductionBundle
    if ($LASTEXITCODE -ne 0 -or $temporalReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        @($temporalReopen -match '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED ').Count -ne 2) {
        throw "Depth-2 temporal CNFs and proofs did not revalidate:`n$($temporalReopen -join "`n")"
    }

    $wrongInductionBundle = Join-Path $tempRoot 'wrong-induction-query'
    Copy-Item -LiteralPath $passBundle -Destination $wrongInductionBundle -Recurse
    $wrongInductionManifestPath = Join-Path $wrongInductionBundle 'manifest.json'
    $wrongInduction = Get-Content -LiteralPath $wrongInductionManifestPath -Raw | ConvertFrom-Json
    $baseQuery = $wrongInduction.queries | Where-Object id -eq 'base'
    $baseCnf = Join-Path $wrongInductionBundle $baseQuery.cnf_path
    $originalCnfDigest = $baseQuery.cnf_sha256
    [IO.File]::AppendAllText($baseCnf, "`n")
    $baseQuery.cnf_sha256 = (Get-FileHash -LiteralPath $baseCnf).Hash.ToLowerInvariant()
    $baseCnfRecord = $wrongInduction.artifacts | Where-Object path -eq $baseQuery.cnf_path
    $baseCnfRecord.sha256 = $baseQuery.cnf_sha256
    $baseCnfRecord.size_bytes = (Get-Item -LiteralPath $baseCnf).Length
    $baseProofRecord = $wrongInduction.artifacts |
        Where-Object { $_.role -eq 'checked_drat_proof' -and $_.path.EndsWith('/base.q3adrat') }
    $baseProof = Join-Path $wrongInductionBundle $baseProofRecord.path
    $baseProofBytes = [IO.File]::ReadAllText($baseProof).Replace(
        $originalCnfDigest, $baseQuery.cnf_sha256)
    [IO.File]::WriteAllText($baseProof, $baseProofBytes)
    $baseProofRecord.sha256 = (Get-FileHash -LiteralPath $baseProof).Hash.ToLowerInvariant()
    $baseProofRecord.size_bytes = (Get-Item -LiteralPath $baseProof).Length
    [IO.File]::WriteAllText($wrongInductionManifestPath, ($wrongInduction | ConvertTo-Json -Depth 100))
    $wrongInductionHash = (Get-FileHash -LiteralPath $wrongInductionManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $wrongInductionBundle 'manifest.sha256') `
        -Value $wrongInductionHash -NoNewline -Encoding ascii
    $wrongInductionResult = @(& $sourcecheck --verify-bundle $wrongInductionBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($wrongInductionResult -join "`n") -notmatch 'regenerated induction query CNF differs from the saved base obligation' -or
        $wrongInductionResult -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Induction should require the exact canonical base query:`n$($wrongInductionResult -join "`n")"
    }
    $missingStep = $wrongInduction.queries | Where-Object id -eq 'step'
    $missingStep.status = 'UNKNOWN'
    [IO.File]::WriteAllText($wrongInductionManifestPath, ($wrongInduction | ConvertTo-Json -Depth 100))
    $missingStepHash = (Get-FileHash -LiteralPath $wrongInductionManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $wrongInductionBundle 'manifest.sha256') `
        -Value $missingStepHash -NoNewline -Encoding ascii
    $missingStepResult = @(& $sourcecheck --verify-bundle $wrongInductionBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($missingStepResult -join "`n") -notmatch 'requires a checked base and step') {
        throw "A missing checked step must invalidate a saved PROVEN status:`n$($missingStepResult -join "`n")"
    }

    $largeProofBundle = Join-Path $tempRoot 'large-proof'
    Copy-Item -LiteralPath $passBundle -Destination $largeProofBundle -Recurse
    $largeProofManifestPath = Join-Path $largeProofBundle 'manifest.json'
    $largeProofManifest = Get-Content -LiteralPath $largeProofManifestPath -Raw | ConvertFrom-Json
    $proofRecord = $largeProofManifest.artifacts |
        Where-Object role -eq 'checked_drat_proof' | Select-Object -First 1
    $largeProofPath = Join-Path $largeProofBundle $proofRecord.path
    $proofText = [IO.File]::ReadAllText($largeProofPath)
    $bodyStart = $proofText.IndexOf("proof_begin`n") + "proof_begin`n".Length
    if ($bodyStart -lt "proof_begin`n".Length) { throw 'Missing proof body marker.' }
    $encoding = [Text.Encoding]::ASCII
    $block = $encoding.GetBytes(("c " + ('p' * 1021) + "`n") * 1024)
    $file = [IO.File]::Open($largeProofPath, [IO.FileMode]::Create)
    try {
        $prefix = $encoding.GetBytes($proofText.Substring(0, $bodyStart))
        $file.Write($prefix, 0, $prefix.Length)
        for ($blockIndex = 0; $blockIndex -lt 24; $blockIndex++) {
            $file.Write($block, 0, $block.Length)
        }
        $suffix = $encoding.GetBytes($proofText.Substring($bodyStart))
        $file.Write($suffix, 0, $suffix.Length)
    } finally {
        $file.Dispose()
    }
    $proofRecord.size_bytes = (Get-Item -LiteralPath $largeProofPath).Length
    $proofRecord.sha256 = (Get-FileHash -LiteralPath $largeProofPath).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($largeProofManifestPath, ($largeProofManifest | ConvertTo-Json -Depth 100))
    $largeProofHash = (Get-FileHash -LiteralPath $largeProofManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $largeProofBundle 'manifest.sha256') `
        -Value $largeProofHash -NoNewline -Encoding ascii
    $priorProofBudget = $env:Q3A_MEMORY_LIMIT_MIB
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '16'
        $streamedProof = @(& $sourcecheck --verify-bundle $largeProofBundle 2>&1)
        if ($LASTEXITCODE -ne 0 -or
            $streamedProof -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            @($streamedProof -match '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED ').Count -ne 2) {
            throw "The 24 MiB certificate should revalidate within a 16 MiB budget:`n$($streamedProof -join "`n")"
        }
    } finally {
        $env:Q3A_MEMORY_LIMIT_MIB = $priorProofBudget
    }
    $writer = [IO.File]::Open($largeProofPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
        $unlockedProof = @(& $sourcecheck --verify-bundle $largeProofBundle 2>&1)
        if ($LASTEXITCODE -ne 1 -or
            ($unlockedProof -join "`n") -notmatch 'with writes denied' -or
            $unlockedProof -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "An open writable certificate must not be accepted:`n$($unlockedProof -join "`n")"
        }
    } finally {
        $writer.Dispose()
    }

    $pastRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-past.q3a') `
        --property p_past_a --frames 1 --bundle-dir $pastBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($pastRun -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($pastRun | Where-Object { $_ -match '^Q3A_BUNDLE_CREATED ' })) {
        throw "Guarded `$past BMC run should preserve its validated bundle:`n$($pastRun -join "`n")"
    }
    $pastReopen = & $sourcecheck --verify-bundle $pastBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($pastReopen -contains 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=2 candidate_frame=1') -or
        -not ($pastReopen -contains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS COMPLETE') -or
        -not ($pastReopen -contains 'Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED') -or
        -not ($pastReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "Reopened guarded `$past trace should replay against its generated history state:`n$($pastReopen -join "`n")"
    }

    $coverRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'lower-sva-sequences.q3a') `
        --property property_check_12 --frames 2 --bundle-dir $coverBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($coverRun -contains 'Q3A_BMC_STATUS COVERED') -or
        -not ($coverRun | Where-Object { $_ -match '^Q3A_BUNDLE_CREATED ' })) {
        throw "A bounded sequence cover should preserve its replay-validated witness:`n$($coverRun -join "`n")"
    }
    $coverReopen = & $sourcecheck --verify-bundle $coverBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($coverReopen | Where-Object { $_ -match '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=3 candidate_frame=\d+$' }) -or
        -not ($coverReopen -contains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE') -or
        -not ($coverReopen -contains 'Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED') -or
        -not ($coverReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "Reopened sequence-cover trace should replay as a cover witness:`n$($coverReopen -join "`n")"
    }
    $coverWitnessManifest = Join-Path $coverBundle 'manifest.json'
    $coverWitnessText = [IO.File]::ReadAllText($coverWitnessManifest)
    $wrongWitnessBoundary = $coverWitnessText.Replace('"boundary_obligations":"INCOMPLETE"',
        '"boundary_obligations":"COMPLETE"')
    if ($wrongWitnessBoundary -ceq $coverWitnessText) {
        throw 'Expected the saved cover witness to have an incomplete temporal boundary.'
    }
    [IO.File]::WriteAllText($coverWitnessManifest, $wrongWitnessBoundary)
    $wrongWitnessHash = (Get-FileHash -LiteralPath $coverWitnessManifest).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $coverBundle 'manifest.sha256') `
        -Value $wrongWitnessHash -NoNewline -Encoding ascii
    $wrongWitness = @(& $sourcecheck --verify-bundle $coverBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($wrongWitness -join "`n") -notmatch 'BMC boundary obligations do not match the saved result' -or
        $wrongWitness -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The replayed cover accepted an incorrect boundary claim:`n$($wrongWitness -join "`n")"
    }
    $coverQueryManifest = $coverWitnessText | ConvertFrom-Json
    $coverWitnessQuery = $coverQueryManifest.queries[0]
    $coverWitnessCnf = Join-Path $coverBundle $coverWitnessQuery.cnf_path
    [IO.File]::AppendAllText($coverWitnessCnf, "`n")
    $coverWitnessQuery.cnf_sha256 = (Get-FileHash -LiteralPath $coverWitnessCnf).Hash.ToLowerInvariant()
    $coverWitnessCnfRecord = $coverQueryManifest.artifacts | Where-Object path -eq $coverWitnessQuery.cnf_path
    $coverWitnessCnfRecord.sha256 = $coverWitnessQuery.cnf_sha256
    $coverWitnessCnfRecord.size_bytes = (Get-Item -LiteralPath $coverWitnessCnf).Length
    [IO.File]::WriteAllText($coverWitnessManifest, ($coverQueryManifest | ConvertTo-Json -Depth 100))
    $wrongQueryHash = (Get-FileHash -LiteralPath $coverWitnessManifest).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $coverBundle 'manifest.sha256') `
        -Value $wrongQueryHash -NoNewline -Encoding ascii
    $wrongWitnessQuery = @(& $sourcecheck --verify-bundle $coverBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($wrongWitnessQuery -join "`n") -notmatch 'regenerated BMC query CNF differs from the saved query' -or
        $wrongWitnessQuery -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The replayed cover accepted a noncanonical CNF:`n$($wrongWitnessQuery -join "`n")"
    }

    $boundedPassRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-scalar.q3a') `
        --property p_always_true --frames 1 --bundle-dir $boundedPassBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($boundedPassRun -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
        -not ($boundedPassRun | Where-Object { $_ -match '^Q3A_BUNDLE_CREATED ' })) {
        throw "A bounded pass should preserve its exact query for reopening:`n$($boundedPassRun -join "`n")"
    }
    $boundedPassReopen = & $sourcecheck --verify-bundle $boundedPassBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($boundedPassReopen -contains 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=BOUNDED_PASS bound=1') -or
        -not ($boundedPassReopen -contains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS COMPLETE') -or
        -not ($boundedPassReopen -contains 'Q3A_BUNDLE_BMC_VACUITY NONVACUOUS') -or
        -not ($boundedPassReopen -contains 'Q3A_BUNDLE_SCOPE REEXECUTED_BOUNDED_QUERY_FOR_SERIALIZED_TIR') -or
        -not ($boundedPassReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED')) {
        throw "The saved bounded-pass query should regenerate and re-execute against bundled T-IR:`n$($boundedPassReopen -join "`n")"
    }

    $shortCoverBundle = Join-Path $tempRoot 'short-consequent-cover'
    $shortCoverRun = @(& $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-cover-implication.q3a') `
        --property c_nonoverlapped_range --frames 1 --bundle-dir $shortCoverBundle)
    if ($LASTEXITCODE -ne 0 -or $shortCoverRun -notcontains 'Q3A_BMC_STATUS COVERED' -or
        $shortCoverRun -notcontains 'Q3A_BMC_COVER_SCOPE BOUNDED boundary_limited=yes') {
        throw "A completed short consequent did not produce a cover bundle:`n$($shortCoverRun -join "`n")"
    }
    $shortCoverReopen = @(& $sourcecheck --verify-bundle $shortCoverBundle)
    if ($LASTEXITCODE -ne 0 -or $shortCoverReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        !($shortCoverReopen -match '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED .*candidate_frame=1$')) {
        throw "The short-consequent cover bundle did not replay:`n$($shortCoverReopen -join "`n")"
    }

    $farFutureBundle = Join-Path $tempRoot 'far-future-assumption'
    $farFutureRun = @(& $sourcecheck --bmc (Join-Path $prototypeRoot 'rtl-far-future-assumption.q3a') `
        --property p_grant --frames 1 --bundle-dir $farFutureBundle)
    if ($LASTEXITCODE -ne 0 -or $farFutureRun -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $farFutureRun -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE') {
        throw "Pending long-delay assumption prevented a completed counterexample:`n$($farFutureRun -join "`n")"
    }
    $farFutureReopen = @(& $sourcecheck --verify-bundle $farFutureBundle)
    if ($LASTEXITCODE -ne 0 -or $farFutureReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $farFutureReopen -notcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        !($farFutureReopen -match '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED ')) {
        throw "The far-future assumption bundle did not replay:`n$($farFutureReopen -join "`n")"
    }

    $conflictBundle = Join-Path $tempRoot 'conflict'
    $conflictRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-conflict.q3a') `
        --property p_assert_a --frames 1 --bundle-dir $conflictBundle
    if ($LASTEXITCODE -ne 0 -or
        $conflictRun -notcontains 'Q3A_BMC_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS') {
        throw "Expected contradictory assumptions:`n$($conflictRun -join "`n")"
    }
    $conflictReopen = & $sourcecheck --verify-bundle $conflictBundle
    if ($LASTEXITCODE -ne 0 -or
        $conflictReopen -notcontains 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=INCONSISTENT_MODEL_OR_ASSUMPTIONS bound=1' -or
        $conflictReopen -notcontains 'Q3A_BUNDLE_SCOPE REEXECUTED_BOUNDED_QUERY_FOR_SERIALIZED_TIR' -or
        $conflictReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        ($conflictReopen -match '^Q3A_BUNDLE_BMC_VACUITY ')) {
        throw "The feasibility bundle must reproduce UNSAT without a vacuity claim:`n$($conflictReopen -join "`n")"
    }

    $conflictCoverBundle = Join-Path $tempRoot 'conflict-cover'
    $conflictCoverRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-conflict.q3a') `
        --property p_cover_a --frames 1 --bundle-dir $conflictCoverBundle
    if ($LASTEXITCODE -ne 0 -or
        $conflictCoverRun -notcontains 'Q3A_BMC_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS' -or
        $conflictCoverRun -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE') {
        throw "Expected a contradictory delayed cover feasibility query:`n$($conflictCoverRun -join "`n")"
    }
    $conflictCover = & $sourcecheck --verify-bundle $conflictCoverBundle
    if ($LASTEXITCODE -ne 0 -or
        $conflictCover -notcontains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE' -or
        $conflictCover -notcontains 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=INCONSISTENT_MODEL_OR_ASSUMPTIONS bound=1') {
        throw "Reopening the contradictory cover must preserve its incomplete boundary:`n$($conflictCover -join "`n")"
    }

    $feasibleBundle = Join-Path $tempRoot 'feasible'
    $feasibleRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-assumption.q3a') `
        --property p_assert_a --frames 0 --bundle-dir $feasibleBundle
    if ($LASTEXITCODE -ne 0 -or $feasibleRun -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS') {
        throw "Expected a bounded pass under satisfiable assumptions:`n$($feasibleRun -join "`n")"
    }
    $feasibleManifestPath = Join-Path $feasibleBundle 'manifest.json'
    $falseConflict = Get-Content -LiteralPath $feasibleManifestPath -Raw | ConvertFrom-Json
    $falseConflict.result.status = 'INCONSISTENT_MODEL_OR_ASSUMPTIONS'
    $falseConflict.result.vacuity = 'NOT_APPLICABLE'
    $query = $falseConflict.queries[0]
    $query.id = 'feasibility'
    $query.kind = 'model-feasibility'
    $cnf = Join-Path $feasibleBundle $query.cnf_path
    $cnfLines = [IO.File]::ReadAllLines($cnf)
    $cnfHeader = [regex]::Match($cnfLines[0], '^p cnf (\d+) (\d+)$')
    if ($cnfLines.Count -lt 3 -or -not $cnfHeader.Success -or
        $cnfLines[-1] -notmatch '^-\d+ 0$') {
        throw 'Expected the bounded query to end with one negative property literal.'
    }
    $cnfLines[0] = "p cnf $($cnfHeader.Groups[1].Value) $([int]$cnfHeader.Groups[2].Value - 1)"
    [IO.File]::WriteAllText($cnf, ($cnfLines[0..($cnfLines.Count - 2)] -join "`n") + "`n")
    $query.cnf_sha256 = (Get-FileHash -LiteralPath $cnf).Hash.ToLowerInvariant()
    $cnfRecord = $falseConflict.artifacts | Where-Object path -eq $query.cnf_path
    $cnfRecord.sha256 = $query.cnf_sha256
    $cnfRecord.size_bytes = (Get-Item -LiteralPath $cnf).Length
    [IO.File]::WriteAllText($feasibleManifestPath, ($falseConflict | ConvertTo-Json -Depth 100))
    $falseConflictHash = (Get-FileHash -LiteralPath $feasibleManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $feasibleBundle 'manifest.sha256') `
        -Value $falseConflictHash -NoNewline -Encoding ascii
    $falseReopen = @(& $sourcecheck --verify-bundle $feasibleBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($falseReopen -join "`n") -notmatch 'did not reproduce its recorded UNSAT result' -or
        $falseReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "A hash-consistent, satisfiable feasibility query must be rejected:`n$($falseReopen -join "`n")"
    }

    $wideQueryBundle = Join-Path $tempRoot 'wide-query'
    $wideRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-assumption.q3a') `
        --property p_assert_a --frames 8000 --bundle-dir $wideQueryBundle
    if ($LASTEXITCODE -ne 0 -or $wideRun -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS') {
        throw "Expected a multi-block bounded query:`n$($wideRun -join "`n")"
    }
    $wideManifestPath = Join-Path $wideQueryBundle 'manifest.json'
    $wideManifest = Get-Content -LiteralPath $wideManifestPath -Raw | ConvertFrom-Json
    $wideQuery = $wideManifest.queries[0]
    $wideCnfPath = Join-Path $wideQueryBundle $wideQuery.cnf_path
    if ((Get-Item -LiteralPath $wideCnfPath).Length -le 64KB) {
        throw 'Expected the regenerated CNF to cross the SHA-256 output buffer boundary.'
    }
    $wideReopen = & $sourcecheck --verify-bundle $wideQueryBundle
    if ($LASTEXITCODE -ne 0 -or
        $wideReopen -notcontains 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=BOUNDED_PASS bound=8000') {
        throw "Multi-block CNF did not match the saved query:`n$($wideReopen -join "`n")"
    }
    [IO.File]::AppendAllText($wideCnfPath, "`n")
    $wideQuery.cnf_sha256 = (Get-FileHash -LiteralPath $wideCnfPath).Hash.ToLowerInvariant()
    $wideCnfRecord = $wideManifest.artifacts | Where-Object path -eq $wideQuery.cnf_path
    $wideCnfRecord.sha256 = $wideQuery.cnf_sha256
    $wideCnfRecord.size_bytes = (Get-Item -LiteralPath $wideCnfPath).Length
    [IO.File]::WriteAllText($wideManifestPath, ($wideManifest | ConvertTo-Json -Depth 100))
    $wideHash = (Get-FileHash -LiteralPath $wideManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $wideQueryBundle 'manifest.sha256') `
        -Value $wideHash -NoNewline -Encoding ascii
    $changedWideReopen = @(& $sourcecheck --verify-bundle $wideQueryBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($changedWideReopen -join "`n") -notmatch 'regenerated BMC query CNF differs from the saved query' -or
        $changedWideReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Changing a final CNF byte must invalidate its regenerated identity:`n$($changedWideReopen -join "`n")"
    }

    $vacuousRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-past.q3a') `
        --property p_past_a --frames 0 --bundle-dir $vacuousBundle
    if ($LASTEXITCODE -ne 0 -or $vacuousRun -notcontains 'Q3A_BMC_VACUITY VACUOUS') {
        throw "Expected a vacuous history warm-up result:`n$($vacuousRun -join "`n")"
    }
    $vacuousReopen = & $sourcecheck --verify-bundle $vacuousBundle
    if ($LASTEXITCODE -ne 0 -or
        $vacuousReopen -notcontains 'Q3A_BUNDLE_BMC_VACUITY VACUOUS' -or
        $vacuousReopen -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Bundle did not reproduce the vacuous history warm-up result:`n$($vacuousReopen -join "`n")"
    }
    $vacuousManifestPath = Join-Path $vacuousBundle 'manifest.json'
    $vacuousText = [IO.File]::ReadAllText($vacuousManifestPath)
    $alteredText = $vacuousText.Replace('"vacuity":"VACUOUS"', '"vacuity":"NONVACUOUS"')
    if ($alteredText -ceq $vacuousText) { throw 'Expected a saved vacuous claim.' }
    [IO.File]::WriteAllText($vacuousManifestPath, $alteredText)
    $alteredHash = (Get-FileHash -LiteralPath $vacuousManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $vacuousBundle 'manifest.sha256') `
        -Value $alteredHash -NoNewline -Encoding ascii
    $altered = @(& $sourcecheck --verify-bundle $vacuousBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($altered -join "`n") -notmatch 'BMC assertion vacuity does not match' -or
        $altered -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "An incorrect vacuity claim with valid hashes must be rejected:`n$($altered -join "`n")"
    }

    $coverMissRun = & $sourcecheck --bmc (Join-Path $prototypeRoot 'lower-sva-sequences.q3a') `
        --property property_check_12 --frames 0 --bundle-dir $coverMissBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($coverMissRun -contains 'Q3A_BMC_STATUS UNKNOWN') -or
        -not ($coverMissRun -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND')) {
        throw "A bounded cover miss must remain non-conclusive when saved:`n$($coverMissRun -join "`n")"
    }
    $coverMissReopen = & $sourcecheck --verify-bundle $coverMissBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($coverMissReopen -contains 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=NOT_FOUND_WITHIN_BOUND bound=0') -or
        -not ($coverMissReopen -contains 'Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE') -or
        -not ($coverMissReopen -contains 'Q3A_BUNDLE_STATUS REVALIDATED') -or
        ($coverMissReopen -contains 'Q3A_BMC_STATUS UNREACHABLE')) {
        throw "A reopened cover miss must be re-executed but never called unreachable:`n$($coverMissReopen -join "`n")"
    }
    $coverManifestPath = Join-Path $coverMissBundle 'manifest.json'
    $coverManifestText = [IO.File]::ReadAllText($coverManifestPath)
    $forgedBoundary = $coverManifestText.Replace('"boundary_obligations":"INCOMPLETE"',
        '"boundary_obligations":"COMPLETE"')
    if ($coverManifestText -ceq $forgedBoundary) {
        throw 'Bundle did not save the cover query boundary as incomplete.'
    }
    [IO.File]::WriteAllText($coverManifestPath, $forgedBoundary)
    $forgedBoundaryHash = (Get-FileHash -LiteralPath $coverManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $coverMissBundle 'manifest.sha256') `
        -Value $forgedBoundaryHash -NoNewline -Encoding ascii
    $forgedResult = @(& $sourcecheck --verify-bundle $coverMissBundle 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        ($forgedResult -join "`n") -notmatch 'BMC boundary obligations do not match the saved result' -or
        $forgedResult -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The rerun accepted an incorrect boundary claim with valid hashes:`n$($forgedResult -join "`n")"
    }


    Copy-Item -LiteralPath $boundedPassBundle -Destination $incompatibleSatBundle -Recurse
    $incompatibleSatManifestPath = Join-Path $incompatibleSatBundle 'manifest.json'
    $incompatibleSatObject = Get-Content -LiteralPath $incompatibleSatManifestPath -Raw | ConvertFrom-Json
    $savedSatFingerprint = @($incompatibleSatObject.components |
        Where-Object { $_.id -eq 'sat_bit_blaster' }).source_sha256
    if (-not $savedSatFingerprint -or $savedSatFingerprint.Length -ne 64) {
        throw 'Bounded-pass fixture does not contain the expected SAT component fingerprint.'
    }
    $incompatibleSatText = Get-Content -LiteralPath $incompatibleSatManifestPath -Raw
    $incompatibleSatText = $incompatibleSatText.Replace($savedSatFingerprint, ('0' * 64))
    [System.IO.File]::WriteAllText(
        $incompatibleSatManifestPath, $incompatibleSatText, [System.Text.UTF8Encoding]::new($false))
    $incompatibleSatHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $incompatibleSatManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $incompatibleSatBundle 'manifest.sha256') `
        -Value $incompatibleSatHash -NoNewline -Encoding ascii
    $incompatibleSat = & $sourcecheck --verify-bundle $incompatibleSatBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($incompatibleSat -contains 'Q3A_BUNDLE_STATUS HISTORIC') -or
        -not ($incompatibleSat | Where-Object { $_ -match '^Q3A_BUNDLE_REVALIDATION UNAVAILABLE reason=saved SAT component fingerprint is unavailable' }) -or
        ($incompatibleSat | Where-Object { $_ -match '^Q3A_BUNDLE_BMC_QUERY REVALIDATED ' })) {
        throw "A bounded-pass query from a different SAT component build must remain historical:`n$($incompatibleSat -join "`n")"
    }

    Copy-Item -LiteralPath $failBundle -Destination $tamperedTraceBundle -Recurse
    $tamperedTracePath = Join-Path $tamperedTraceBundle 'properties\p_q_tracks_a\trace.json'
    $traceContent = [System.IO.File]::ReadAllText($tamperedTracePath)
    $traceDefect = '"q":"0x0"'
    if (-not $traceContent.Contains($traceDefect)) {
        throw 'Known-fail trace fixture no longer contains the expected q value.'
    }
    $oldTraceHash = (Get-FileHash -LiteralPath $tamperedTracePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        $tamperedTracePath, $traceContent.Replace($traceDefect, '"q":"0x1"'),
        [System.Text.UTF8Encoding]::new($false))
    $newTraceHash = (Get-FileHash -LiteralPath $tamperedTracePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $tamperedTraceManifest = Join-Path $tamperedTraceBundle 'manifest.json'
    $traceManifestText = [System.IO.File]::ReadAllText($tamperedTraceManifest)
    if (-not $traceManifestText.Contains($oldTraceHash)) {
        throw 'Bundle manifest does not fingerprint the expected BMC trace.'
    }
    [System.IO.File]::WriteAllText(
        $tamperedTraceManifest, $traceManifestText.Replace($oldTraceHash, $newTraceHash),
        [System.Text.UTF8Encoding]::new($false))
    $tamperedTraceManifestHash = (Get-FileHash -LiteralPath $tamperedTraceManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $tamperedTraceBundle 'manifest.sha256') `
        -Value $tamperedTraceManifestHash -NoNewline -Encoding ascii
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $invalidTrace = & $sourcecheck --verify-bundle $tamperedTraceBundle 2>&1
    $invalidTraceExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($invalidTraceExitCode -eq 0 -or
        -not (($invalidTrace -join "`n") -match 'bundle BMC witness replay failed')) {
        throw "An integrity-consistent but semantically false BMC trace must fail independent replay:`n$($invalidTrace -join "`n")"
    }

    Copy-Item -LiteralPath $passBundle -Destination $tamperedBundle -Recurse
    Set-Content -LiteralPath (Join-Path $tamperedBundle 'model\model.json') `
        -Value '{}' -NoNewline -Encoding ascii
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tampered = & $sourcecheck --verify-bundle $tamperedBundle 2>&1
    $tamperedExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($tamperedExitCode -eq 0 -or
        -not (($tampered -join "`n") -match 'artifact size or SHA-256 mismatch: model/model.json')) {
        throw "A modified model must fail bundle reopening before proof revalidation:`n$($tampered -join "`n")"
    }

    $largeBundle = Join-Path $tempRoot 'large'
    Copy-Item -LiteralPath $failBundle -Destination $largeBundle -Recurse
    $largeArtifact = Join-Path $largeBundle 'large-waveform.vcd'
    $knownVcd = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'evidence/known-fail/witness.vcd')
    $waveformBytes = [Text.Encoding]::ASCII.GetBytes($knownVcd + ("`n" * 144000))
    [IO.File]::WriteAllBytes($largeArtifact, $waveformBytes)
    $largeManifestPath = Join-Path $largeBundle 'manifest.json'
    $largeManifest = Get-Content -Raw -LiteralPath $largeManifestPath | ConvertFrom-Json
    $largeManifest.artifacts += [pscustomobject]@{
        path = 'large-waveform.vcd'
        role = 'vcd_export'
        size_bytes = $waveformBytes.Length
        sha256 = (Get-FileHash -LiteralPath $largeArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $largeManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $largeManifestPath -Encoding utf8
    $largeManifestHash = (Get-FileHash -LiteralPath $largeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $largeBundle 'manifest.sha256') -Value $largeManifestHash -Encoding ascii
    $largeCheck = @(& $sourcecheck --verify-bundle $largeBundle)
    if ($LASTEXITCODE -ne 0 -or $largeCheck -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $largeCheck -notcontains 'Q3A_BUNDLE_VCD VERIFIED') {
        throw "A valid multi-block waveform must preserve bundle revalidation:`n$($largeCheck -join "`n")"
    }
    $waveformBytes[$waveformBytes.Length - 1] = 13
    [IO.File]::WriteAllBytes($largeArtifact, $waveformBytes)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $corruptWaveform = @(& $sourcecheck --verify-bundle $largeBundle 2>&1)
    $corruptWaveformExit = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($corruptWaveformExit -eq 0 -or
        ($corruptWaveform -join "`n") -notmatch 'artifact size or SHA-256 mismatch: large-waveform.vcd') {
        throw "A changed byte after the first hash block must fail bundle reopening:`n$($corruptWaveform -join "`n")"
    }

    $waveformBytes[$waveformBytes.Length - 1] = 10
    [IO.File]::WriteAllBytes($largeArtifact, $waveformBytes)
    $traceRecord = $largeManifest.artifacts | Where-Object role -eq 'replay_validated_trace'
    $tracePath = Join-Path $largeBundle $traceRecord.path
    $padding = [Text.Encoding]::ASCII.GetBytes((' ' * 65536))
    $traceOutput = [IO.File]::Open($tracePath, [IO.FileMode]::Append)
    try {
        for ($i = 0; $i -lt 320; $i++) {
            $traceOutput.Write($padding, 0, $padding.Length)
        }
    } finally { $traceOutput.Dispose() }
    $traceRecord.size_bytes = (Get-Item -LiteralPath $tracePath).Length
    $traceRecord.sha256 = (Get-FileHash -LiteralPath $tracePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $largeManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $largeManifestPath -Encoding utf8
    $largeManifestHash = (Get-FileHash -LiteralPath $largeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $largeBundle 'manifest.sha256') -Value $largeManifestHash -Encoding ascii
    $savedMemoryBudget = $env:Q3A_MEMORY_LIMIT_MIB
    $savedPreference = $ErrorActionPreference
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '16'
        $ErrorActionPreference = 'Continue'
        $stoppedBundle = @(& $sourcecheck --verify-bundle $largeBundle 2>&1)
        if ($LASTEXITCODE -ne 3 -or $stoppedBundle -notcontains 'Q3A_BUNDLE_STATUS UNKNOWN' -or
            ($stoppedBundle -join "`n") -notmatch 'Q3A_BUNDLE_RESOURCE_LIMIT.*pending=[1-9][0-9]+ limit=16777216' -or
            $stoppedBundle -contains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Active trace must stop before a budgeted read:`n$($stoppedBundle -join "`n")"
        }
    } finally {
        $ErrorActionPreference = $savedPreference
        if ($null -eq $savedMemoryBudget) {
            Remove-Item Env:Q3A_MEMORY_LIMIT_MIB -ErrorAction SilentlyContinue
        } else {
            $env:Q3A_MEMORY_LIMIT_MIB = $savedMemoryBudget
        }
    }
    $resumedBundle = @(& $sourcecheck --verify-bundle $largeBundle)
    if ($LASTEXITCODE -ne 0 -or $resumedBundle -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The same bundle must replay after removing the restrictive budget:`n$($resumedBundle -join "`n")"
    }

    Copy-Item -LiteralPath $passBundle -Destination $escapedBundle -Recurse
    $manifestPath = Join-Path $escapedBundle 'manifest.json'
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if (-not $manifestText.Contains('source-snapshot/project.q3a')) {
        throw 'Test fixture does not contain the expected project-manifest artifact path.'
    }
    $escapedManifest = $manifestText.Replace('source-snapshot/project.q3a', '../project.q3a')
    [System.IO.File]::WriteAllText(
        $manifestPath, $escapedManifest, [System.Text.UTF8Encoding]::new($false))
    $escapedManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $escapedBundle 'manifest.sha256') `
        -Value $escapedManifestHash -NoNewline -Encoding ascii
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pathTraversal = & $sourcecheck --verify-bundle $escapedBundle 2>&1
    $pathTraversalExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($pathTraversalExitCode -eq 0 -or
        -not (($pathTraversal -join "`n") -match 'artifact path escapes the bundle root')) {
        throw "A self-consistent manifest with a parent path must be rejected:`n$($pathTraversal -join "`n")"
    }

    Copy-Item -LiteralPath $passBundle -Destination $incompatibleBundle -Recurse
    $incompatibleManifestPath = Join-Path $incompatibleBundle 'manifest.json'
    $incompatibleText = Get-Content -LiteralPath $incompatibleManifestPath -Raw
    $passManifest = Get-Content -LiteralPath (Join-Path $passBundle 'manifest.json') -Raw | ConvertFrom-Json
    $oldCheckerFingerprint = $passManifest.checker.fingerprint_sha256
    $incompatibleText = $incompatibleText.Replace($oldCheckerFingerprint, ('0' * 64))
    [System.IO.File]::WriteAllText(
        $incompatibleManifestPath, $incompatibleText, [System.Text.UTF8Encoding]::new($false))
    $incompatibleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $incompatibleManifestPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $incompatibleBundle 'manifest.sha256') `
        -Value $incompatibleHash -NoNewline -Encoding ascii
    $incompatible = & $sourcecheck --verify-bundle $incompatibleBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($incompatible -contains 'Q3A_BUNDLE_STATUS HISTORIC') -or
        -not ($incompatible | Where-Object { $_ -match '^Q3A_BUNDLE_REVALIDATION UNAVAILABLE .*checker identity is unavailable' }) -or
        ($incompatible | Where-Object { $_ -match '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED ' })) {
        throw "A bundle from a different checker build must not be revalidated by identity alone:`n$($incompatible -join "`n")"
    }
} finally {
    foreach ($bundlePath in @($pastBundle, $coverBundle, $boundedPassBundle, $coverMissBundle)) {
        if (Test-Path -LiteralPath $bundlePath) {
            $bundleFull = [System.IO.Path]::GetFullPath($bundlePath)
            $outputFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\') + '\'
            if (-not $bundleFull.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                [System.IO.Path]::GetFileName($bundleFull) -notmatch '^q3a-(past|cover|bmc-pass|cover-miss)-reopen-[0-9a-f]{32}$') {
                throw "Refusing to clean an unexpected test path: $bundleFull"
            }
            Remove-Item -LiteralPath $bundleFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        $tempFull = [System.IO.Path]::GetFullPath($tempRoot)
        $outputFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\') + '\'
        if (-not $tempFull.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($tempFull) -notmatch '^q3a-open-[0-9a-f]{32}$') {
            throw "Refusing to clean an unexpected test path: $tempFull"
        }
        Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

'PASS: ordinary and long-path bundles reopen with checked induction certificates, witnesses replay, bounded queries rerun, and incomplete proofs, tampering, path traversal, and output collisions are rejected.'
