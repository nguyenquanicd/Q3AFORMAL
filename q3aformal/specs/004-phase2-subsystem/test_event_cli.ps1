#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DevelopmentExecutable,
    [Parameter(Mandatory)][string]$ReleasedExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$CheckerExecutable
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$dev = (Resolve-Path -LiteralPath $DevelopmentExecutable).ProviderPath
$release = (Resolve-Path -LiteralPath $ReleasedExecutable).ProviderPath
$checker = (Resolve-Path -LiteralPath $CheckerExecutable).ProviderPath
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$source = Join-Path $root 'source fixtures'
New-Item -ItemType Directory -Path $source | Out-Null
$rtl = @(
    'module event_cli(input logic clk_a, clk_b, data, env_ok, output logic x, y);'
    'always_ff @(posedge clk_a) begin x <= data; end'
    'always_ff @(posedge clk_b) begin y <= data; end'
    "p_true: assert property (@(posedge clk_a) 1'b1);"
    "p_false: assert property (@(posedge clk_a) 1'b0);"
    "p_pending: assert property (@(posedge clk_a) 1'b1 |=> x);"
    "c_hit: cover property (@(posedge clk_b) 1'b1);"
    'c_view: cover property (@(posedge clk_b) data ##1 !data);'
    'p_valid: assert property (@(posedge clk_a) data |=> x);'
    "c_never: cover property (@(posedge clk_b) 1'b0);"
)
Set-Content -LiteralPath "$source/normal.sv" -Value ($rtl + 'endmodule') -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/provisional.sv" -Value (
    $rtl + "env: assume property (@(posedge clk_b) 1'b1 |=> env_ok);" + 'endmodule'
) -Encoding utf8NoBOM
$manifest = @('Q3AFORMAL_PROJECT 2', 'top event_cli', 'source systemverilog "normal.sv"')
Set-Content -LiteralPath "$source/normal.q3a" -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/changed.q3a" -Value ($manifest -replace '^top event_cli$', 'top  event_cli') -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/provisional.q3a" -Value ($manifest -replace 'normal.sv', 'provisional.sv') -Encoding utf8NoBOM
$guiFixture = "$source/gui.q3a"
Set-Content -LiteralPath "$source/gui.sv" -Value ($rtl + "idle_a: assume property (@(posedge clk_a) 1'b0);" + 'endmodule') -Encoding utf8NoBOM
$guiManifest = $manifest -replace 'normal\.sv', 'gui.sv'
Set-Content -LiteralPath $guiFixture -Value $guiManifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$source/gui-changed.q3a" -Value ($guiManifest -replace '^top event_cli$', 'top  event_cli') -Encoding utf8NoBOM

function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
$identity = [ordered]@{development = Hash $dev; released = Hash $release; checker = Hash $checker}
$devVersion = & $dev --version | ConvertFrom-Json
$releasedVersion = & $release --version | ConvertFrom-Json
if ($devVersion.build_id -eq $releasedVersion.build_id -or
    $devVersion.build_configuration -cnotmatch 'Q3A_ENABLE_DEVELOPMENT_EVENT_MASK' -or
    $releasedVersion.build_configuration -cmatch 'Q3A_ENABLE_DEVELOPMENT_EVENT_MASK' -or
    -not ((& $dev --help) -cmatch 'dev-check-events') -or ((& $release --help) -cmatch 'dev-check-events')) {
    throw 'Development and released command surfaces did not separate.'
}

$cases = [Collections.Generic.List[object]]::new()
function Test-Run([string]$Name, [string]$Program, [int]$Exit, [string]$Status, [string[]]$CommandArguments) {
    $stderr = Join-Path $root "$Name.stderr.txt"
    $stdout = @(& $Program @CommandArguments 2> $stderr)
    $code = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    if ($code -ne $Exit) { throw "$Name exited $code, expected $Exit. $stdout $(Get-Content $stderr -Raw)" }
    $record = if ($Status) { $stdout | ConvertFrom-Json }
    if ($Status -and ($record.status -cne $Status -or $record.exit_code -ne $code)) {
        throw "$Name did not report $Status. $stdout"
    }
    $cases.Add([ordered]@{name = $Name; exit = $code; status = $record.status})
    return $record
}

$normal = "$source/normal.q3a"
$provisional = "$source/provisional.q3a"
$closed = "$root/closed"
$pending = "$root/pending"
$hit = "$root/cover evidence"
$failed = "$root/assert evidence"
$open = "$root/provisional evidence"
$checkHit = @('dev-check-events', $normal, '--property', 'c_hit', '--output-dir', $hit, '--frames', '0')
$verifyHit = @('dev-verify-events', $normal, '--property', 'c_hit', '--evidence-dir', $hit)
Test-Run complete $dev 1 BOUNDED_COMPLETE @('dev-check-events', $normal, '--property', 'p_true',
    '--output-dir', $closed, '--frames', '0') | Out-Null
Test-Run incomplete $dev 1 BOUNDED_INCOMPLETE @('dev-check-events', $normal, '--property', 'p_pending',
    '--output-dir', $pending, '--frames', '0') | Out-Null
if ((Test-Path -LiteralPath $closed) -or (Test-Path -LiteralPath $pending)) { throw 'Non-witness result created trace files.' }

$covered = Test-Run cover $dev 0 COVERED $checkHit
$reopened = Test-Run cover-reopen $dev 0 REVALIDATED $verifyHit
if ($covered.domain -cne 'clk_b' -or $covered.global_step -ne 0 -or $covered.domain_sample -ne 0 -or
    $covered.global_frames -ne 1 -or $covered.model_input_sha256 -cne $reopened.model_input_sha256 -or
    $covered.manifest_sha256 -cne (Hash $normal) -or $covered.open_assumption -or !$reopened.witness_revalidated) {
    throw 'Cover provenance, domain or sample was lost.'
}
$counterexample = Test-Run assertion $dev 0 FAIL @('dev-check-events', $normal, '--property', 'p_false',
    '--output-dir', $failed, '--frames', '0')
$verifiedFailure = Test-Run assertion-reopen $dev 0 REVALIDATED @('dev-verify-events', $normal,
    '--property', 'p_false', '--evidence-dir', $failed)
if ($counterexample.domain -cne 'clk_a' -or $verifiedFailure.domain_sample -ne 0) { throw 'Assertion witness sampled the wrong domain.' }

$openCheck = Test-Run provisional $dev 1 WITNESS_PENDING_ASSUMPTION @('dev-check-events', $provisional,
    '--property', 'c_hit', '--output-dir', $open, '--frames', '0')
$openVerify = Test-Run provisional-reopen $dev 1 WITNESS_PENDING_ASSUMPTION @('dev-verify-events', $provisional,
    '--property', 'c_hit', '--evidence-dir', $open)
if (!$openCheck.open_assumption -or !$openVerify.open_assumption -or !$openVerify.witness_revalidated) {
    throw 'Provisional status was lost when the trace reopened.'
}
Test-Run released-command $release 2 '' $checkHit | Out-Null
Test-Run existing-evidence $dev 2 REJECTED $checkHit | Out-Null
Test-Run changed-manifest $dev 2 REJECTED ($verifyHit -replace 'normal\.q3a$', 'changed.q3a') | Out-Null
Test-Run wrong-property $dev 2 REJECTED ($verifyHit -replace '^c_hit$', 'p_false') | Out-Null

$signal = Join-Path $root 'cancel.signal'
Set-Content -LiteralPath $signal -Value 'stop'
Test-Run cancelled $dev 1 CANCELLED ($checkHit + @('--cancel-file', $signal)) | Out-Null
Test-Run invalid-bound $dev 2 REJECTED ($checkHit -replace '^0$', '10001') | Out-Null
$sourcePath = Join-Path $source 'normal.sv'
$originalRtl = [IO.File]::ReadAllBytes($sourcePath)
try {
    Add-Content -LiteralPath $sourcePath -Value '// Changed source identity.'
    Test-Run changed-rtl $dev 2 REJECTED $verifyHit | Out-Null
} finally { [IO.File]::WriteAllBytes($sourcePath, $originalRtl) }
$schedule = Join-Path $hit 'witness.schedule'
$original = [IO.File]::ReadAllBytes($schedule)
try {
    $text = [Text.Encoding]::UTF8.GetString($original)
    $edit = $text.Replace('step 0 - 0', 'step 0 - 1').Replace('step 0 0 0', 'step 0 0 1')
    if ($edit -ceq $text) { throw 'Could not find the candidate local index.' }
    [IO.File]::WriteAllText($schedule, $edit)
    Test-Run changed-sample $dev 2 REJECTED $verifyHit | Out-Null
} finally { [IO.File]::WriteAllBytes($schedule, $original) }
Test-Run restored-witness $dev 0 REVALIDATED $verifyHit | Out-Null

$debugEvidence = "$root/debug evidence"
$debugSession = "$root/windows session.json"
$coverDebug = Test-Run gui-witness $dev 0 COVERED @('dev-check-events', $guiFixture, '--property', 'c_view',
    '--output-dir', $debugEvidence, '--frames', '8')
if ($coverDebug.domain -cne 'clk_b' -or $coverDebug.domain_sample -lt 1 -or $coverDebug.global_step -lt 1) {
    throw 'GUI fixture lacks a multi-step witness.'
}
$scheduleRows = @(Get-Content -LiteralPath "$debugEvidence/witness.schedule" | Where-Object { $_ -cmatch '^step ' })
$expectedRow = 'step {0} - {1}' -f $coverDebug.global_step, $coverDebug.domain_sample
if ($scheduleRows.Count -ne $coverDebug.global_frames -or $scheduleRows -cnotcontains $expectedRow) {
    throw 'GUI fixture did not record an idle clock and an active local sample at the witness.'
}
$debugArgs = @('dev-gui-events', $guiFixture, '--property', 'c_view', '--evidence-dir', $debugEvidence,
    '--test-session', $debugSession)
Test-Run gui-changed-manifest $dev 2 REJECTED ($debugArgs -replace 'gui\.q3a$', 'gui-changed.q3a') | Out-Null
Test-Run gui-released-command $release 2 '' $debugArgs | Out-Null
if (Test-Path -LiteralPath $debugSession) { throw 'A rejected GUI command saved a session.' }
Test-Run native-event-debug $dev 0 DEBUG_SESSION_VERIFIED $debugArgs | Out-Null
$viewState = Get-Content -LiteralPath $debugSession -Raw | ConvertFrom-Json
if ($viewState.trace -cne 'witness.q3t' -or !$viewState.markers -or $viewState.frame -ne $coverDebug.global_step) {
    throw 'Saved GUI session lost the witness trace, cursor or marker.'
}


$validProof = "$root/safety proof"
$deadCover = "$root/unreachable cover"
$pdrFailure = "$root/pdr witness"
$pdrHit = "$root/pdr cover"
$prove = @('dev-prove-events', $normal, '--property', 'p_valid', '--output-dir', $validProof,
    '--max-depth', '8', '--max-queries', '1000', '--feasibility-frames', '4')
$verify = @('dev-verify-event-proof', $normal, '--property', 'p_valid', '--evidence-dir', $validProof)
$proved = Test-Run unbounded-safety $dev 0 PROVEN $prove
$checked = Test-Run proof-reopen $dev 0 PROOF_REVALIDATED $verify
if ($proved.schedule -cne 'FREE_EVENT_MASK' -or $checked.certificate_model_sha256 -cne $proved.certificate_model_sha256 -or
    $checked.run_configuration_sha256 -cne $proved.run_configuration_sha256 -or $proved.obligations.Count -ne 3) {
    throw 'Unbounded proof lost its model, configuration or obligation identities.'
}
$recordPath = Join-Path $validProof 'run-configuration.json'
$config = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if ($config.run_configuration.maximum_depth -ne 8 -or $config.run_configuration.maximum_search_queries -ne 1000 -or
    $config.run_configuration.minimum_feasibility_bound -ne 4 -or $config.run_configuration.project_manifest_sha256 -cne (Hash $normal)) {
    throw 'Unbounded proof did not retain its saved controls.'
}
$unreachable = Test-Run unbounded-unreachable $dev 0 UNREACHABLE @('dev-prove-events', $normal,
    '--property', 'c_never', '--output-dir', $deadCover)
$revalidatedCover = Test-Run unreachable-reopen $dev 0 PROOF_REVALIDATED @('dev-verify-event-proof', $normal,
    '--property', 'c_never', '--evidence-dir', $deadCover)
if ($unreachable.run_configuration_sha256 -cne $revalidatedCover.run_configuration_sha256) {throw 'Cover proof configuration changed.'}

Test-Run unbounded-violation $dev 0 FAIL @('dev-prove-events', $normal,
    '--property', 'p_false', '--output-dir', $pdrFailure) | Out-Null
Test-Run unbounded-violation-replay $dev 0 REVALIDATED @('dev-verify-events', $normal,
    '--property', 'p_false', '--evidence-dir', $pdrFailure) | Out-Null
Test-Run unbounded-cover-hit $dev 0 COVERED @('dev-prove-events', $normal,
    '--property', 'c_hit', '--output-dir', $pdrHit) | Out-Null
Test-Run unbounded-cover-replay $dev 0 REVALIDATED @('dev-verify-events', $normal,
    '--property', 'c_hit', '--evidence-dir', $pdrHit) | Out-Null
Test-Run proof-released-command $release 2 '' $prove | Out-Null
Test-Run mismatched-proof-property $dev 2 REJECTED ($verify -replace '^p_valid$', 'p_true') | Out-Null
Test-Run mismatched-proof-manifest $dev 2 REJECTED ($verify -replace 'normal\.q3a$', 'changed.q3a') | Out-Null
Test-Run witness-as-proof $dev 2 REJECTED @('dev-verify-event-proof', $normal,
    '--property', 'c_hit', '--evidence-dir', $pdrHit) | Out-Null
$configBytes = [IO.File]::ReadAllBytes($recordPath)
try {
    $config.run_configuration.project_manifest_sha256 = 'a' * 64
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    Test-Run edited-proof-provenance $dev 2 REJECTED $verify | Out-Null
} finally { [IO.File]::WriteAllBytes($recordPath, $configBytes) }
$backup = Join-Path $validProof 'original-configuration.test'
Move-Item -LiteralPath $recordPath -Destination $backup
try { Test-Run missing-proof-provenance $dev 2 REJECTED $verify | Out-Null }
finally { Move-Item -LiteralPath $backup -Destination $recordPath }
Test-Run proof-restored $dev 0 PROOF_REVALIDATED $verify | Out-Null

$obligations = @(foreach ($case in @(@{directory=$validProof; certificate=$proved; name='p_valid'},
    @{directory=$deadCover; certificate=$unreachable; name='c_never'})) {
    foreach ($obligation in $case.certificate.obligations) {
        $stem = Join-Path $case.directory ($obligation.kind -replace '^pdr-', '')
        $accepted = @(& $checker --check-drat "$stem.cnf" "$stem.q3adrat" --model-sha256 $case.certificate.certificate_model_sha256 --query-kind $obligation.kind)
        if ($LASTEXITCODE -ne 0 -or $accepted -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
            (Hash "$stem.cnf") -cne $obligation.query_sha256 -or (Hash "$stem.q3adrat") -cne $obligation.proof_sha256) {
            throw "Standalone proof check failed for $($case.name)/$($obligation.kind)."
        }
        [ordered]@{property=$case.name; kind=$obligation.kind; query_sha256=$obligation.query_sha256; proof_sha256=$obligation.proof_sha256}
    }
})
if ($obligations.Count -ne 6) { throw 'The two unbounded proof groups must each have three independent obligations.' }

$artifacts = @(foreach ($case in @(@{name='cover'; directory=$hit}, @{name='assertion'; directory=$failed},
    @{name='provisional'; directory=$open}, @{name='gui-cover'; directory=$debugEvidence}, @{name='pdr-assertion'; directory=$pdrFailure}, @{name='pdr-cover'; directory=$pdrHit})) {
    [ordered]@{
        name = $case.name
        indexed_sha256 = Hash (Join-Path $case.directory 'witness.q3t')
        schedule_sha256 = Hash (Join-Path $case.directory 'witness.schedule')
    }
})
if ((Hash $dev) -cne $identity.development -or (Hash $release) -cne $identity.released -or (Hash $checker) -cne $identity.checker) { throw 'Executable identity changed.' }
[ordered]@{
    status = 'PASS'
    development_build_id = $devVersion.build_id
    released_build_id = $releasedVersion.build_id
    executables = $identity
    cases = @($cases)
    witnesses = $artifacts
    standalone_obligations = $obligations
    native_debug_session_sha256 = Hash $debugSession
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: $($cases.Count) event CLI checks with six witness groups, six standalone proof obligations, and a native GUI session."
