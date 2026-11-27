#requires -Version 7.0
param([Parameter(Mandatory)][string]$RunDirectory, [string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $prototype
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$run = (Resolve-Path -LiteralPath $RunDirectory).Path
$approved = Join-Path $PSScriptRoot 'phase0-jobs.approved.json'
$record = Get-Content -LiteralPath (Join-Path $run 'environment.json') -Raw | ConvertFrom-Json
$sha = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
$jobsSha = (Get-FileHash -LiteralPath $approved).Hash.ToLowerInvariant()
if ($record.q3a_executable_sha256 -cne $sha -or $record.jobs_manifest_sha256 -cne $jobsSha -or
    $record.host_profile_status -cnotin 'CAPTURED', 'CAPTURED_WITH_FALLBACK', 'CAPTURED_WITH_USER_OVERRIDE') {
    throw 'The run does not identify the current executable and approved Phase 0 manifest.'
}

$jobs = @( (Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json).jobs )
$gateB = Join-Path $repo 'evidence/benchmark/runs/phase0-final-gate-b-2026-11-24/measurements.csv'
$reviewedInputs = Import-Csv -LiteralPath $gateB | Group-Object -Property job_id -AsHashTable -AsString
$rows = @(Import-Csv -LiteralPath (Join-Path $run 'measurements.csv'))
if ($rows.Count -ne $jobs.Count -or @($rows.job_id | Sort-Object -Unique).Count -ne $jobs.Count) {
    throw 'The recorded benchmark jobs are incomplete or repeated.'
}
$thresholds = foreach ($job in $jobs) {
    $row = $rows | Where-Object job_id -CEQ $job.id
    if (!$row -or $row.executable_sha256 -cne $sha -or $row.measurement_verdict -cne 'EXPECTED' -or
        $row.formal_status -cne $job.expected_formal_status -or $row.timed_out -cne 'False' -or
        !$reviewedInputs.ContainsKey($job.id) -or
        $row.input_hashes_json -cne $reviewedInputs[$job.id][0].input_hashes_json -or
        [int]$row.process_exit_code -ne $job.expected_exit_code -or
        [long]$row.peak_working_set_bytes -le 0 -or
        [long]$row.peak_working_set_bytes -gt $job.peak_working_set_limit_bytes -or
        [double]$row.elapsed_ms -lt 0 -or [double]$row.elapsed_ms -gt ($job.timeout_seconds * 1000)) {
        throw "Phase 0 compatibility failed for $($job.id)."
    }
    [pscustomobject]@{
        Job = $row.job_id; Status = $row.formal_status; Exit = $row.process_exit_code
        ElapsedMs = $row.elapsed_ms; PeakBytes = $row.peak_working_set_bytes
        TimeLimitSeconds = $job.timeout_seconds; MemoryLimitBytes = $job.peak_working_set_limit_bytes
        Verdict = 'PASS'
    }
}
$bundles = @(foreach ($row in ($rows | Where-Object job_id -Match '^B-0[1-4]-')) {
    $bundle = Join-Path $run "$($row.job_id)-artifacts/bundle"
    $check = @(& $exe --verify-bundle $bundle --require-source-model)
    if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $check -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $check -cnotcontains "Q3A_BUNDLE_RESULT_STATUS $($row.formal_status)") {
        throw "Source-backed bundle verification failed for $($row.job_id)."
    }
    if ($row.formal_status -ceq 'PROVEN' -and $check -cnotcontains 'Q3A_BUNDLE_REVALIDATION ACCEPTED proof_artifacts=2') {
        throw "Expected checked base and step DRAT obligations for $($row.job_id)."
    }
    if ($row.formal_status -cin 'BOUNDED_FAIL','COVERED' -and -not ($check -cmatch '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED')) {
        throw "Expected a replayed witness for $($row.job_id)."
    }
    $check | Set-Content -LiteralPath (Join-Path $run "$($row.job_id).revalidation.txt")
    [pscustomobject]@{Job = $row.job_id; Status = $row.formal_status; Verification = 'REVALIDATED'; ExecutableSha256 = $sha}
})
if ($bundles.Count -ne 4) { throw 'Expected four Phase 0 bundle results.' }
$thresholds | Export-Csv -LiteralPath (Join-Path $run 'threshold-verdicts.csv') -NoTypeInformation
$bundles | Export-Csv -LiteralPath (Join-Path $run 'bundle-verdicts.csv') -NoTypeInformation
"PASS $($thresholds.Count) Phase 0 cases and $($bundles.Count) source-backed bundles for $sha"
