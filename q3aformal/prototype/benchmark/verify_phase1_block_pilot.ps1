#requires -Version 7.0
param([Parameter(Mandatory)][string]$RunDirectory, [string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $prototype
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$run = (Resolve-Path -LiteralPath $RunDirectory).Path
$envRecord = Get-Content (Join-Path $run 'environment.json') -Raw | ConvertFrom-Json
$expected = Get-Content (Join-Path $PSScriptRoot 'phase1-block-jobs.pilot.json') -Raw | ConvertFrom-Json
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$jobsHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'phase1-block-jobs.pilot.json') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($envRecord.q3a_executable_sha256 -cne $hash -or $envRecord.jobs_manifest_sha256 -cne $jobsHash) {
    throw 'Benchmark build or workload hash does not match.'
}
$rows = @(Import-Csv (Join-Path $run 'measurements.csv'))
if ($rows.Count -ne $expected.jobs.Count -or @($rows.job_id | Sort-Object -Unique).Count -ne $rows.Count) {
    throw 'Benchmark case coverage differs from the frozen roster.'
}

$verdicts = foreach ($row in $rows) {
    $job = $expected.jobs | Where-Object id -CEQ $row.job_id
    if (!$job -or $row.executable_sha256 -cne $hash -or $row.measurement_verdict -cne 'EXPECTED' -or
        $row.formal_status -cne $job.expected_formal_status -or
        [int]$row.process_exit_code -ne $job.expected_exit_code) {
        throw "Unexpected functional result for $($row.job_id)."
    }
    $recordedInputs = $row.input_hashes_json | ConvertFrom-Json -AsHashtable
    $inputPaths = @($job.input_files | ForEach-Object { "prototype/benchmark/$_" })
    if ($recordedInputs.Count -ne $inputPaths.Count -or @($inputPaths | Where-Object { !$recordedInputs.Contains($_) }).Count) {
        throw "Input roster differs for $($row.job_id)."
    }
    foreach ($field in $recordedInputs.GetEnumerator()) {
        $prefix = 'prototype/benchmark/fixtures/'
        if (!$field.Key.StartsWith($prefix) -or $field.Key.Substring($prefix.Length) -notmatch '^P1_[a-z_]+\.(q3a|sv)$') {
            throw "Invalid benchmark input record $($field.Key)."
        }
        $currentHash = (Get-FileHash -LiteralPath (Join-Path $repo $field.Key) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -cne $field.Value) { throw "Benchmark input changed: $($field.Key)." }
    }
    $base = Join-Path $run "$($row.job_id)-artifacts"
    if ($row.job_id -ceq 'P1-04-registered-grant-pdr') {
        $certificate = Join-Path $base 'certificate'
        $project = Join-Path $PSScriptRoot 'fixtures/P1_arbiter.q3a'
        $verification = @(& $exe verify-pdr $project --property p_registered_grant --evidence-dir $certificate)
        if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw 'PDR certificate did not revalidate.'
        }
        $verification += @(& (Join-Path $prototype 'tests/test_drat_independent_full_scan.ps1') -PdrEvidence $certificate)
    } else {
        $bundle = Join-Path $base 'bundle'
        $verification = @(& $exe --verify-bundle $bundle)
        if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            $verification -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED') {
            throw "Bundle did not revalidate for $($row.job_id)."
        }
        if ($row.formal_status -in 'BOUNDED_FAIL','COVERED' -and
            ($verification -cnotcontains 'Q3A_BUNDLE_INDEXED_TRACE VERIFIED' -or
             $verification -cnotcontains 'Q3A_BUNDLE_WAVEFORM_CAPTURE VERIFIED')) {
            throw "Indexed witness or capture did not revalidate for $($row.job_id)."
        }
        if ($row.formal_status -ceq 'PROVEN') {
            foreach ($id in 'base','step') {
                if (!($verification -cmatch "^Q3A_BUNDLE_PROOF_CHECK ACCEPTED id=$id ")) {
                    throw "Missing checked induction obligation $id."
                }
            }
        }
    }
    $verification | Set-Content -LiteralPath (Join-Path $run "$($row.job_id).revalidation.txt") -Encoding utf8
    [pscustomobject]@{Job=$row.job_id; Status=$row.formal_status; Evidence='REVALIDATED'; ExecutableSha256=$hash}
}
$verdicts | Export-Csv -LiteralPath (Join-Path $run 'evidence-verdicts.csv') -NoTypeInformation

$bundle = Join-Path $run 'P1-02-elastic-stall-failure-artifacts/bundle'
$page = Join-Path $run 'elastic-stall-debug.html'
$html = & $exe debug $bundle
if ($LASTEXITCODE -ne 0) { throw 'Could not generate the verified block-level debug view.' }
$html | Set-Content -LiteralPath $page -Encoding utf8
$index = Join-Path $bundle 'properties/p_hold/trace.q3atrace'
$metrics = & node (Join-Path $PSScriptRoot 'measure_debug_navigation.cjs') $page $index out_valid
if ($LASTEXITCODE -ne 0) { throw 'Indexed debug navigation measurement failed.' }
$metrics | Set-Content -LiteralPath (Join-Path $run 'debug-navigation.json') -Encoding utf8
$verdicts | Format-Table Job,Status,Evidence -AutoSize
$metrics
