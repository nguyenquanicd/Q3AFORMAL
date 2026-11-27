#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$StandardExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$RequireCompactBitVectors,
    [switch]$RequireLiveness,
    [switch]$RequireFourState,
    [switch]$RequireExtendedFourState,
    [switch]$RequireIndexedReadsAndCounterexamples,
    [switch]$RequireSequenceContainmentAndMultiplication,
    [switch]$RequireFourStateModelAndWildcards,
    [switch]$RequireDivisionAndNamedSequences,
    [switch]$RequireFirstMatch,
    [switch]$RequireNamedProperties,
    [string]$PreviousFourStateExecutable
)
$ErrorActionPreference = 'Stop'
if ($PreviousFourStateExecutable) {
    $PreviousFourStateExecutable = (Resolve-Path -LiteralPath $PreviousFourStateExecutable).Path
    $RequireIndexedReadsAndCounterexamples = $true
}
if ($RequireSequenceContainmentAndMultiplication) { $RequireExtendedFourState = $true }
if ($RequireFourStateModelAndWildcards) { $RequireExtendedFourState = $true }
if ($RequireDivisionAndNamedSequences) { $RequireExtendedFourState = $true }
if ($RequireFirstMatch) { $RequireExtendedFourState = $true }
if ($RequireNamedProperties) { $RequireExtendedFourState = $true }
if ($RequireIndexedReadsAndCounterexamples) { $RequireExtendedFourState = $true }
if ($RequireExtendedFourState) { $RequireFourState = $true }
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$standard = (Resolve-Path -LiteralPath $StandardExecutable).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }

$inventory = & "$repo/scripts/package_windows.ps1" -Archive $archivePath -VerifyOnly | ConvertFrom-Json
if ($inventory.channel -cne 'development-preview' -or $inventory.sha256 -cne (Hash $archivePath)) {
    throw 'Expected a verified development preview archive.'
}
$runtime = Join-Path $root 'extracted preview'
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $runtime)
$dev = Join-Path $runtime 'prototype/bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $runtime 'prototype/bin/q3aformal-proofcheck.exe'
$startupIdentity = & $dev --version | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $startupIdentity.build_id -cne $inventory.source_build_id) {
    throw 'Extracted executable does not identify the packaged build.'
}
$profiles = @('MEMORY','EVENT_MASK','SAMPLED_VALUES')
if ($RequireLiveness) { $profiles += 'LIVENESS' }
if ($RequireFourState) { $profiles += 'FOUR_STATE' }
foreach ($name in $profiles) {
    if ($startupIdentity.build_configuration -cnotmatch "Q3A_ENABLE_DEVELOPMENT_$name(?: |$)") {
        throw "Integrated archive is missing development capability $name."
    }
}

$specRoot = Join-Path $repo 'specs'
$phase2 = Join-Path $specRoot '004-phase2-subsystem'
$phase3 = Join-Path $specRoot '005-phase3-profile-expansion'
& "$phase2/test_memory_cli.ps1" -DevelopmentExecutable $dev -ReleasedExecutable $standard -CheckerExecutable $checker -OutputDirectory "$root/memory"
& "$phase2/test_event_cli.ps1" -DevelopmentExecutable $dev -ReleasedExecutable $standard -CheckerExecutable $checker -OutputDirectory "$root/events"
& "$phase3/test_sampled_values.ps1" -DevelopmentExecutable $dev -DefaultExecutable $standard -CheckerExecutable $checker -OutputDirectory "$root/sampling"

if ($RequireCompactBitVectors) {
    & "$phase3/test_bit_vector_functions.ps1" -DevelopmentExecutable $dev -StandardExecutable $standard -CheckerExecutable $checker -OutputDirectory "$root/bit-vector"
    & "$phase3/test_compact_bit_vector.ps1" -ExecutablePath $dev -OutputDirectory "$root/compact-bit-vector"
}
if ($RequireLiveness) {
    $standardHelp = @(& $standard --help)
    if ($LASTEXITCODE -ne 0 -or ($standardHelp -join "`n") -match 'dev-(check|verify)-liveness') {
        throw 'A standard executable unexpectedly exposes the development liveness commands.'
    }
    & "$phase3/test_liveness_vcd.ps1" -ExecutablePath $dev -OutputDirectory "$root/liveness"
}
$fourStateSuites = @()
if ($RequireFourState) {
    if ($inventory.schema -cne 'Q3AFORMAL-WINDOWS-PACKAGE-3') {
        throw 'The preview is missing the packaged four-state example roster.'
    }
    $standardHelp = @(& $standard --help)
    if ($LASTEXITCODE -ne 0 -or ($standardHelp -join [Environment]::NewLine) -match 'dev-(lower|eval|prove|verify)-four-state') {
        throw 'A standard executable unexpectedly exposes development four-state commands.'
    }
    & "$phase3/test_four_state_source.ps1" -ExecutablePath $dev -StandardExecutable $standard -OutputDirectory "$root/four-state-evaluation"
    $fourStateSuites += 'four-state-evaluation'
    $fourStateProofSuites = @('proof','sequential','sva','sequences','assumptions','history','cover')
    if ($RequireExtendedFourState) {
        $fourStateProofSuites += 'reductions','arithmetic','shifts','case','hierarchy'
    }
    if ($RequireIndexedReadsAndCounterexamples) {
        $fourStateProofSuites += 'indexed_bits','indexed_parts'
    }
    if ($PreviousFourStateExecutable) {
        $fourStateProofSuites += 'sequence_or','sequence_intersect','sequence_and'
    }
    if ($RequireSequenceContainmentAndMultiplication) {
        $fourStateProofSuites += 'sequence_throughout','sequence_within','multiply'
    }
    if ($RequireFourStateModelAndWildcards) {
        $fourStateProofSuites += 'wildcard_equality','casex'
        & "$phase3/test_four_state_model_export.ps1" -ExecutablePath $dev -StandardExecutable $standard -OutputDirectory "$root/four-state-model-export"
        $fourStateSuites += 'four-state-model-export'
    }
    if ($RequireDivisionAndNamedSequences) {
        $fourStateProofSuites += 'divide','named_sequence'
    }
    if ($RequireFirstMatch) {
        $fourStateProofSuites += 'first_match'
    }
    if ($RequireNamedProperties) {
        $fourStateProofSuites += 'named_property'
    }
    foreach ($name in $fourStateProofSuites) {
        $suite = "four-state-$name"
        & "$phase3/test_four_state_${name}.ps1" -ExecutablePath $dev -CheckerPath $checker -OutputDirectory "$root/$suite"
        $fourStateSuites += $suite
    }
    & "$phase3/test_four_state_vcd.ps1" -ExecutablePath $dev -OutputDirectory "$root/four-state-vcd"
    $fourStateSuites += 'four-state-vcd'
    if ($RequireIndexedReadsAndCounterexamples) {
        & "$phase3/test_four_state_counterexample_artifacts.ps1" -ExecutablePath $dev -OutputDirectory "$root/four-state-counterexample"
        $fourStateSuites += 'four-state-counterexample'
    }
    if ($PreviousFourStateExecutable) {
        & "$phase3/test_four_state_window_pruning.ps1" -ExecutablePath $dev -PreviousExecutablePath $PreviousFourStateExecutable -CheckerPath $checker -OutputDirectory "$root/four-state-window-pruning"
        $fourStateSuites += 'four-state-window-pruning'
    }
    $example = "$runtime/prototype/four-state-cover.q3a"
    $proof = "$root/example-proof"
    $witness = "$root/example-witness"
    $vcd = "$root/example-waveform.vcd"
    $result = & $dev dev-prove-four-state $example --property p_history --evidence-dir $proof --steps 2 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'BOUNDED_PASS') { throw 'The packaged example assertion failed.' }
    $checked = & $dev dev-verify-four-state $example --property p_history --evidence-dir $proof --steps 2 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $checked.status -cne 'REVALIDATED' -or $checked.proof_sha256 -cne $result.proof_sha256) {
        throw 'The packaged example assertion certificate did not revalidate.'
    }
    $hit = & $dev dev-prove-four-state $example --property c_xz_then_zx --evidence-dir $witness --steps 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $hit.status -cne 'COVERED') { throw 'The packaged example cover was missed.' }
    $reopened = & $dev dev-verify-four-state $example --property c_xz_then_zx --evidence-dir $witness --steps 1 --vcd $vcd | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $reopened.status -cne 'COVERED' -or !$reopened.witness_revalidated -or
        $reopened.witness_sha256 -cne $hit.witness_sha256 -or $reopened.vcd_sha256 -cne (Hash $vcd) -or
        $reopened.trace[0].data -cne 'xz' -or $reopened.trace[1].data -cne 'zx' -or
        $reopened.trace[1].previous_data -cne 'xz') {
        throw 'The packaged example lost its witness value, evidence binding or waveform.'
    }
    $childProofHash = $null
    if ($RequireExtendedFourState) {
        $child = "$root/example-child-proof"
        $options = @($example,'--property','capture.p_history','--evidence-dir',$child,'--steps','2')
        $childProof = & $dev dev-prove-four-state @options | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $childProof.status -cne 'BOUNDED_PASS') {
            throw 'The packaged child assertion failed.'
        }
        $childCheck = & $dev dev-verify-four-state @options | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $childCheck.status -cne 'REVALIDATED' -or
            $childCheck.proof_sha256 -cne $childProof.proof_sha256 -or
            $childCheck.proof_sha256 -cne (Hash "$child/proof.q3adrat")) {
            throw 'The packaged child assertion certificate did not revalidate.'
        }
        $childProofHash = $childCheck.proof_sha256
    }
    $counterexampleHash = $null
    $counterexampleVcdHash = $null
    if ($RequireIndexedReadsAndCounterexamples) {
        $failDir = "$root/example-counterexample"
        $failVcd = "$root/example-counterexample.vcd"
        $options = @($example,'--property','p_demo_counterexample','--evidence-dir',$failDir,'--steps','0')
        $failure = & $dev dev-prove-four-state @options --save-witness | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $failure.status -cne 'COUNTEREXAMPLE') {
            throw 'The packaged demo assertion did not reproduce its expected failure.'
        }
        $replayedFailure = & $dev dev-verify-four-state @options --vcd $failVcd | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $replayedFailure.status -cne 'COUNTEREXAMPLE' -or !$replayedFailure.witness_revalidated -or
            $failure.witness_sha256 -cne $replayedFailure.witness_sha256 -or
            $replayedFailure.witness_sha256 -cne (Hash "$failDir/counterexample.q3awitness") -or
            $replayedFailure.vcd_sha256 -cne (Hash $failVcd) -or
            $replayedFailure.failure_sample -ne 0 -or $replayedFailure.signals.data -cne 'z1' -or
            $replayedFailure.signals.window -cne 'xz') {
            throw 'The packaged example did not reopen the partial-slice counterexample from source.'
        }
        $counterexampleHash = $replayedFailure.witness_sha256
        $counterexampleVcdHash = $replayedFailure.vcd_sha256
    }
    $exampleRun = @{
        status = 'PACKAGED_FOUR_STATE_EXAMPLE_QUALIFIED'
        executable_sha256 = Hash $dev
        project_sha256 = Hash $example
        source_sha256 = Hash "$runtime/prototype/corpus/source-model-vectors/four_state_cover.sv"
        proof_sha256 = $checked.proof_sha256
        child_proof_sha256 = $childProofHash
        counterexample_sha256 = $counterexampleHash
        counterexample_vcd_sha256 = $counterexampleVcdHash
        witness_sha256 = $reopened.witness_sha256
        vcd_sha256 = $reopened.vcd_sha256
    }
    $exampleRun | ConvertTo-Json | Set-Content -LiteralPath "$root/example-qualification.json" -Encoding utf8NoBOM
}
$sampledManifest = "$root/sampling/sampled.q3a"
$crossChecks = @(foreach ($command in 'dev-prove-memory', 'dev-check-events') {
    $unpublished = Join-Path $root "rejected-$command"
    $options = if ($command -ceq 'dev-prove-memory') { @('--max-cells', '4') } else { @('--frames', '4') }
    $raw = & $dev $command $sampledManifest --property p_stable --output-dir $unpublished @options 2> "$root/$command.stderr.txt"
    $exit = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$command.json" -Encoding utf8NoBOM
    $diagnostic = Get-Content -LiteralPath "$root/$command.stderr.txt" -Raw
    if ($exit -eq 0 -or $diagnostic -cnotmatch 'requires a baseline project profile' -or (Test-Path -LiteralPath $unpublished)) {
        throw "$command admitted a sampled-value project into the wrong scheduler semantics. $raw $diagnostic"
    }
    [ordered]@{command = $command; exit = $exit; diagnostic = 'BASELINE_PROJECT_REQUIRED'}
})
& "$repo/prototype/benchmark/preflight_phase2_subsystem.ps1" -ExecutablePath $dev -OutputDirectory "$root/subsystem"

$memory = Get-Content -LiteralPath "$root/memory/qualification.json" -Raw | ConvertFrom-Json
$event = Get-Content -LiteralPath "$root/events/qualification.json" -Raw | ConvertFrom-Json
$sampling = Get-Content -LiteralPath "$root/sampling/qualification.json" -Raw | ConvertFrom-Json
$subsystem = Get-Content -LiteralPath "$root/subsystem/qualification.json" -Raw | ConvertFrom-Json
$devSha = Hash $dev
$checkerSha = Hash $checker
if ($devSha -cne $memory.executables.development -or $devSha -cne $event.executables.development -or
    $devSha -cne $sampling.development_sha256 -or $devSha -cne $subsystem.executable_sha256 -or
    $checkerSha -cne $memory.executables.checker -or $checkerSha -cne $event.executables.checker -or
    $checkerSha -cne $sampling.checker_sha256 -or $inventory.sha256 -cne (Hash $archivePath)) {
    throw 'Integrated qualification did not use one exact packaged binary pair.'
}
$extraProofs = 0
$extraObligations = 0
$compactBytes = $null
$suiteNames = @('memory','events','sampling','subsystem')
if ($RequireCompactBitVectors) {
    $vector = Get-Content -LiteralPath "$root/bit-vector/qualification.json" -Raw | ConvertFrom-Json
    $compact = Get-Content -LiteralPath "$root/compact-bit-vector/qualification.json" -Raw | ConvertFrom-Json
    if ($vector.executable_sha256 -cne $devSha -or $compact.executable_sha256 -cne $devSha -or
        $vector.standalone_checker_sha256 -cne $checkerSha -or
        $vector.status -cne 'DEVELOPMENT_BIT_VECTOR_QUALIFIED' -or $compact.status -cne 'COMPACT_BIT_VECTOR_QUALIFIED') {
        throw 'Bit-vector qualification did not bind to the packaged build.'
    }
    $extraProofs = $vector.proven_and_source_revalidated.Count
    $extraObligations = $vector.standalone_count_obligations.Count
    $compactBytes = $compact.serialized_bytes
    $suiteNames += 'bit-vector','compact-bit-vector'
}
if ($RequireLiveness) {
    $liveness = Get-Content -LiteralPath "$root/liveness/qualification.json" -Raw | ConvertFrom-Json
    if ($liveness.status -cne 'LIVENESS_VCD_EXPORT_QUALIFIED' -or $liveness.executable_sha256 -cne $devSha) {
        throw 'Liveness qualification did not bind to the packaged build.'
    }
    $suiteNames += 'liveness'
}
foreach ($name in $fourStateSuites) {
    $four = Get-Content -LiteralPath "$root/$name/qualification.json" -Raw | ConvertFrom-Json
    if ($four.status -cnotmatch '_QUALIFIED$' -or $four.executable_sha256 -cne $devSha -or
        ($four.checker_sha256 -and $four.checker_sha256 -cne $checkerSha)) {
        throw "Four-state suite $name did not bind to the packaged executable pair."
    }
}
$suiteNames += $fourStateSuites
[ordered]@{
    status = 'DEVELOPMENT_PREVIEW_FUNCTIONAL_QUALIFICATION_PASSED'
    archive_sha256 = $inventory.sha256
    build_id = $inventory.source_build_id
    executable_sha256 = $devSha
    standalone_checker_sha256 = $checkerSha
    memory_cli_cases = $memory.cases.Count
    event_cli_cases = $event.cases.Count
    sampled_value_proofs = $sampling.distinct_proofs
    bit_vector_proofs = $extraProofs
    compact_bit_vector_serialized_bytes = $compactBytes
    native_event_gui = 'SESSION_REPLAYED'
    liveness_waveforms = if ($RequireLiveness) { $liveness.waveforms.Count } else { 0 }
    standalone_profile_obligations = $memory.standalone_obligations.Count + $event.standalone_obligations.Count + 1 + $extraObligations
    four_state_suites = $fourStateSuites.Count
    four_state_example_sha256 = if ($RequireFourState) { Hash "$root/example-qualification.json" } else { $null }
    cross_profile_rejections = $crossChecks
    phase2_subsystem = $subsystem.status
    phase2_timed_acceptance = 'PENDING'
    phase3_profile_release_acceptance = 'PENDING'
    acceptance_progress_percent = 50
    suite_evidence = @(foreach ($name in $suiteNames) {
        @{path = "$name/qualification.json"; sha256 = Hash "$root/$name/qualification.json"}
    })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: extracted development preview qualified across its configured profiles and Phase 2 subsystem preflight.'

