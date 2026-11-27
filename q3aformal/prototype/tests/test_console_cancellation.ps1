#requires -Version 7.0
param([string]$Compiler = 'g++', [string]$ReportPath, [string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$manifest = Join-Path $prototype 'counter4-fail.q3a'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-console-test-' + [guid]::NewGuid()))).FullName

try {
    $probe = Join-Path $root 'probe.exe'
    & $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic -static -municode (
        Join-Path $PSScriptRoot 'console_cancel_probe.cpp') -o $probe
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the isolated console probe.' }

    $cases = @(
        @{ Cause = 'ctrl_c'; Mode = 'prove'; Pattern = 'console-explicit.json' },
        @{ Cause = 'ctrl_break'; Mode = 'prove'; Pattern = 'q3a-cancelled-*.json' },
        @{ Cause = 'ctrl_c'; Mode = 'prove-batch'; Pattern = 'result.json' },
        @{ Cause = 'ctrl_break'; Mode = 'prove-batch'; Pattern = 'result.json' }
    )
    $rows = foreach ($case in $cases) {
        $cause = $case.Cause
        $caseName = "$($case.Mode)-$cause"
        $run = (New-Item -ItemType Directory -Path (Join-Path $root $caseName)).FullName
        $isBatch = $case.Mode -ceq 'prove-batch'
        if ($isBatch) {
            @(
                'Q3AFORMAL_BATCH 1'
                'memory_mib 1024'
                'job slow bmc p_wraps_to_zero 10000 20000'
                'job skipped bmc p_wraps_to_zero 1 20000'
            ) | Set-Content -LiteralPath (Join-Path $run 'plan.q3b')
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $probe
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @($exe, $manifest, $run, $cause)) {
            $start.ArgumentList.Add($argument)
        }
        if ($isBatch) { $start.ArgumentList.Add('batch') }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $errors = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(35000)) { throw 'The console probe timed out.' }
            if ($process.ExitCode -ne 0) { throw "The console probe failed for ${cause}. $($errors.Result)" }
        } finally {
            if (!$process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
            $process.Dispose()
        }
        $recordRoot = if ($isBatch) { Join-Path $run 'batch-result/job-slow' } else { $run }
        $records = @(Get-ChildItem -LiteralPath $recordRoot -File -Filter $case.Pattern)
        if ($records.Count -ne 1 -or (Test-Path -LiteralPath (Join-Path $run 'witness')) -or
            (Test-Path -LiteralPath (Join-Path $recordRoot 'bundle'))) {
            throw "Invalid artifact publication after $caseName."
        }
        $recordJson = Get-Content -LiteralPath $records[0].FullName -Raw
        $result = $recordJson | ConvertFrom-Json
        if ($result.status -cne 'CANCELLED' -or $result.exit_code -ne 1 -or
            $result.cancellation_cause -cne $cause -or !$result.cancellation_stage -or
            $result.completed_work -cnotcontains 'project_loaded' -or $result.engine -cne 'bmc' -or
            $result.properties.Count -ne 1 -or $result.properties[0].status -cne 'CANCELLED') {
            throw "Incorrect cancellation record for $caseName."
        }
        $nextJob = $null
        if ($isBatch) {
            $batchRoot = Join-Path $run 'batch-result'
            $batch = Get-Content -LiteralPath (Join-Path $batchRoot 'batch.json') -Raw | ConvertFrom-Json
            $planHash = (Get-FileHash -LiteralPath (Join-Path $run 'plan.q3b')).Hash.ToLowerInvariant()
            if ($batch.exit_code -ne 1 -or $batch.status -cne 'CANCELLED' -or
                $batch.plan_sha256 -cne $planHash -or $batch.build_id -cne $result.build_id -or
                $batch.source_set_sha256 -cne $result.source_set_sha256 -or
                ($batch.jobs.id -join ',') -cne 'slow,skipped' -or
                ($batch.jobs.result.status -join ',') -cne 'CANCELLED,NOT_RUN' -or
                ($batch.jobs[0].result | ConvertTo-Json -Depth 10 -Compress) -cne
                    ($result | ConvertTo-Json -Depth 10 -Compress) -or
                (Test-Path -LiteralPath (Join-Path $batchRoot 'job-skipped'))) {
                throw "Batch scheduled another job after $cause or lost its active job record."
            }
            $nextJob = $batch.jobs[1].result.status
        }
        $recordHash = (Get-FileHash -LiteralPath $records[0].FullName).Hash.ToLowerInvariant()
        $verified = @(& $exe --verify-bundle $records[0].FullName)
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_RUN_RECORD_STATUS STRUCTURE_VALID' -or
            $verified -cnotcontains "Q3A_RUN_RECORD_SHA256 $recordHash") {
            throw "Saved cancellation record did not reopen for $caseName. $verified"
        }
        [ordered]@{
            mode = $case.Mode
            cause = $cause
            status = $result.status
            stage = $result.cancellation_stage
            build_id = $result.build_id
            record_file = $records[0].Name
            record_sha256 = $recordHash
            record_json = $recordJson
            record_verification = 'STRUCTURE_VALID'
            next_job = $nextJob
        }
    }
    foreach ($row in $rows) {
        "PASS: $($row.cause) cancelled $($row.mode) in a private Windows console and the record reopened."
    }
    if ($ReportPath) {
        [ordered]@{
            schema = 'Q3AFORMAL-WINDOWS-CONSOLE-REGRESSION-1'
            executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
            results = @($rows)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-console-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
