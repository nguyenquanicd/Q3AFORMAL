#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = Join-Path $repo 'prototype/benchmark/fixtures/P1_elastic_pipeline.q3a'
$plan = Join-Path $root 'jobs with spaces.q3b'
@('Q3AFORMAL_BATCH 2', 'memory_mib 384',
    'job induction induction p_hold 2 30000', 'job property pdr p_hold 12 30000',
    'job cover bmc p_transfer 16 30000') | Set-Content -LiteralPath $plan
function Invoke-Batch([string]$Label, [int]$ExpectedCode, [string]$Target, [string[]]$Options,
    [string]$JobPlan = $plan) {
    $out = @(& $exe prove-batch $project --plan $JobPlan --output-dir $Target @Options 2> "$root/$Label.stderr.txt")
    $actual = $LASTEXITCODE
    $out | Set-Content -LiteralPath "$root/$Label.json"
    if ($out.Count -ne 1 -or $actual -ne $ExpectedCode) {
        throw "Unexpected batch exit $actual for $Label : $out $(Get-Content -Raw "$root/$Label.stderr.txt")"
    }
    $report = $out[0] | ConvertFrom-Json
    if ($report.exit_code -ne $ExpectedCode) { throw "Batch exit disagrees with its JSON for $Label" }
    return $report
}

$legacy = "$root/sequential"
$parallel = "$root/parallel results"
$serial = Invoke-Batch serial 0 $legacy @('--checkpoint')
$concurrent = Invoke-Batch parallel 0 $parallel @('--checkpoint','--workers','2')
if ($concurrent.workers -ne 2 -or $concurrent.peak_workers -ne 2 -or
    $concurrent.coordinator_memory_mib + $concurrent.workers * $concurrent.worker_memory_mib -gt $concurrent.memory_mib -or
    ($concurrent.jobs.id -join ',') -cne 'induction,property,cover' -or
    ($concurrent.jobs.result.status -join ',') -cne 'PROVEN,PROVEN,COVERED' -or
    ($concurrent.jobs.result.status -join ',') -cne ($serial.jobs.result.status -join ',')) {
    throw 'Parallel batch changed job order or outcomes, or violated its reservation.'
}
foreach ($job in $concurrent.jobs) {
    $workerBytes = $concurrent.worker_memory_mib * 1MB
    if ($job.worker_peak_commit_bytes -le 0 -or $job.worker_peak_commit_bytes -gt $workerBytes -or
        $job.result.run_configuration.search_private_limit_bytes -gt $workerBytes -or
        !(Test-Path -LiteralPath "$parallel/$($job.result_directory)/checkpoint.commit")) {
        throw "Worker $($job.id) did not stay within its commit budget or publish its checked result."
    }
}
$resume = Invoke-Batch resume 0 $parallel @('--resume','--workers','2')
if (($resume.jobs.reused -join ',') -cne 'True,True,True' -or $resume.peak_workers -ne 0 -or
    ($resume.jobs.result.status -join ',') -cne ($serial.jobs.result.status -join ',')) {
    throw 'Parallel results did not independently reopen on resume.'
}
$small = "$root/small.q3b"
(Get-Content -LiteralPath $plan) -creplace '^memory_mib 384$', 'memory_mib 100' | Set-Content -LiteralPath $small
$invalid = "$root/invalid output"
$null = Invoke-Batch invalid-without-checkpoint 2 $invalid @('--workers','2')
$null = Invoke-Batch invalid-budget 2 $invalid @('--checkpoint','--workers','2') $small
if (Test-Path -LiteralPath $invalid) { throw 'A rejected parallel setup wrote output.' }

$timeoutPlan = "$root/timeout.q3b"
@('Q3AFORMAL_BATCH 1', 'memory_mib 384', 'job limited bmc p_hold 10000 1',
  'job other induction p_hold 2 30000') | Set-Content -LiteralPath $timeoutPlan
$timeout = Invoke-Batch timeout 1 "$root/timeout" @('--checkpoint','--workers','2') $timeoutPlan
if (($timeout.jobs.result.status -join ',') -cne 'TIMEOUT,PROVEN') {
    throw 'An exhausted worker deadline changed the independent job result.'
}

$cancelPlan = "$root/cancel.q3b"
@('Q3AFORMAL_BATCH 1', 'memory_mib 768',
  'job first bmc p_hold 1024 30000', 'job second bmc p_hold 1024 30000',
  'job pending bmc p_hold 1024 30000') | Set-Content -LiteralPath $cancelPlan
$cancelOutput = "$root/cancellation"
$flag = "$root/stop requested"
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($arg in @('prove-batch',$project,'--plan',$cancelPlan,'--output-dir',$cancelOutput,
    '--checkpoint','--workers','2','--cancel-file',$flag)) {
    $start.ArgumentList.Add($arg)
}
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $log = "$cancelOutput/attempt-1/job-second/worker.stderr.txt"
    while (!$process.HasExited -and !(Test-Path -LiteralPath $log) -and $clock.Elapsed.TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 5
    }
    if (!(Test-Path -LiteralPath $log) -or $process.HasExited) {
        throw 'The second worker exited before live cancellation could be exercised.'
    }
    New-Item -ItemType File -Path $flag | Out-Null
    if (!$process.WaitForExit(15000)) { throw 'Cancelled parallel batch did not exit.' }
    $raw = $stdout.GetAwaiter().GetResult()
    $raw | Set-Content -LiteralPath "$root/cancelled.json"
    $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/cancelled.stderr.txt"
    $cancelled = $raw | ConvertFrom-Json
    if ($process.ExitCode -ne 1 -or $cancelled.status -cne 'CANCELLED' -or
        $cancelled.jobs[2].result.status -cne 'NOT_RUN' -or
        @($cancelled.jobs | Where-Object { $_.result.status -ceq 'CANCELLED' }).Count -lt 1) {
        throw 'Parallel cancellation lost the active or pending worker distinction.'
    }
} finally {
    if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}

$mutable = "$root/mutable"
New-Item -ItemType Directory -Path $mutable | Out-Null
$mutableProject = "$mutable/project.q3a"
$mutableRtl = "$mutable/P1_elastic_pipeline.sv"
Copy-Item -LiteralPath $project -Destination $mutableProject
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $project) 'P1_elastic_pipeline.sv') -Destination $mutableRtl
$mutatePlan = "$root/mutation.q3b"
@('Q3AFORMAL_BATCH 1', 'memory_mib 768',
  'job first bmc p_hold 1024 1500', 'job second bmc p_hold 1024 1500',
  'job rejected induction p_hold 2 10000') | Set-Content -LiteralPath $mutatePlan
$mutateOutput = "$root/source mutation"
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($arg in @('prove-batch',$mutableProject,'--plan',$mutatePlan,'--output-dir',$mutateOutput,'--checkpoint','--workers','2')) {
    $start.ArgumentList.Add($arg)
}
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $log = "$mutateOutput/attempt-1/job-second/worker.stderr.txt"
    while (!$process.HasExited -and !(Test-Path -LiteralPath $log) -and $clock.Elapsed.TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 5
    }
    if (!(Test-Path -LiteralPath $log) -or $process.HasExited) {
        throw 'The second worker was not active during the source mutation check.'
    }
    Add-Content -LiteralPath $mutableRtl -Value '// Mutated after coordinator admission.'
    if (!$process.WaitForExit(15000)) { throw 'Source mutation check did not finish.' }
    $raw = $stdout.GetAwaiter().GetResult()
    $raw | Set-Content -LiteralPath "$root/source-mutation.json"
    $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/source-mutation.stderr.txt"
    $sourceMutation = $raw | ConvertFrom-Json
    $rejected = "$mutateOutput/attempt-1/job-rejected"
    if ($process.ExitCode -ne 2 -or $sourceMutation.jobs[2].result.status -cne 'SETUP_ERROR' -or
        (Test-Path -LiteralPath "$rejected/checkpoint.commit") -or
        (Get-Content -Raw "$rejected/worker.stderr.txt") -notmatch 'source or manifest changed') {
        throw 'A worker accepted altered source after the coordinator fixed the batch source identity.'
    }
} finally {
    if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}

[ordered]@{
    status = 'PASS'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    requested_workers = $concurrent.workers
    peak_workers = $concurrent.peak_workers
    worker_memory_mib = $concurrent.worker_memory_mib
    coordinator_memory_mib = $concurrent.coordinator_memory_mib
    peak_worker_bytes = ($concurrent.jobs.worker_peak_commit_bytes | Measure-Object -Maximum).Maximum
    statuses = @($concurrent.jobs.result.status)
    independently_reused = @($resume.jobs | Where-Object reused).Count
    cancellation = @($cancelled.jobs.result.status)
    source_changed_while_queued = $sourceMutation.jobs[2].result.status
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json"
'PASS: parallel proof, independent resume, resource accounting, deadline isolation and cancellation.'
