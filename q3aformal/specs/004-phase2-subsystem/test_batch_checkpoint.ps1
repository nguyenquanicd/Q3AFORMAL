#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$project = Join-Path $root 'resume.q3a'
$rtl = Join-Path $root 'dut.sv'
Copy-Item -LiteralPath "$repo/prototype/corpus/source-model-vectors/pdr_pipeline.sv" -Destination $rtl
@('Q3AFORMAL_PROJECT 2', 'top pdr_example', 'source systemverilog "dut.sv"', 'option profile Q3A-P0-R0.9.1') |
    Set-Content -LiteralPath $project
$plan = Join-Path $root 'plan.q3b'
@('Q3AFORMAL_BATCH 2', 'memory_mib 384', 'job safe pdr p_safe 12 30000 max_queries 50000',
  'job witness pdr p_bad 12 30000', 'job finite bmc p_bad 5 30000', 'job bounded bmc p_safe 4 30000') |
    Set-Content -LiteralPath $plan
$output = Join-Path $root 'checkpoint'

function Invoke-Checkpoint([string]$Case, [int]$Code, [string]$Mode,
    [string]$InputPlan = $plan, [string]$Target = $output, [string]$InputProject = $project,
    [string[]]$Options = @()) {
    $lines = @(& $exe prove-batch $InputProject --plan $InputPlan --output-dir $Target $Mode @Options 2> "$root/$Case.stderr.txt")
    $actual = $LASTEXITCODE
    $lines | Set-Content -LiteralPath "$root/$Case.stdout.json"
    if ($actual -ne $Code -or $lines.Count -ne 1) {
        throw "Unexpected checkpoint exit for $Case ($actual): $lines $(Get-Content -Raw "$root/$Case.stderr.txt")"
    }
    $report = $lines[0] | ConvertFrom-Json
    if ($report.exit_code -ne $Code) { throw "Incorrect report exit for $Case" }
    return $report
}

$start = Invoke-Checkpoint start 1 --checkpoint
if ($start.checkpoint_attempt -ne 1 -or ($start.jobs.result.status -join ',') -cne 'PROVEN,FAIL,BOUNDED_FAIL,BOUNDED_PASS' -or
    @($start.jobs | Where-Object reused).Count -ne 0 -or
    (Test-Path -LiteralPath "$output/attempt-1/job-bounded/checkpoint.commit")) {
    throw 'Initial checkpoint did not commit only reusable verdicts.'
}
$changed = Join-Path $root 'changed.q3b'
Copy-Item -LiteralPath $plan -Destination $changed
Add-Content -LiteralPath $changed -Value ''
$null = Invoke-Checkpoint wrong-plan 2 --resume $changed
$rtlBytes = [IO.File]::ReadAllBytes($rtl)
Add-Content -LiteralPath $rtl -Value '// Different source identity.'
$null = Invoke-Checkpoint wrong-source 2 --resume
[IO.File]::WriteAllBytes($rtl, $rtlBytes)
$lock = [IO.File]::Open("$output/batch.lock", 'Open', 'ReadWrite', 'None')
try { $null = Invoke-Checkpoint locked 2 --resume }
finally { $lock.Dispose() }
$cancel = Join-Path $root 'cancel'
New-Item -ItemType File -Path $cancel | Out-Null
$cancelled = Invoke-Checkpoint cancelled 1 --resume -Options @('--cancel-file', $cancel)
if ($cancelled.status -cne 'CANCELLED' -or (Test-Path -LiteralPath "$output/attempt-2")) {
    throw 'Rejected or cancelled setup changed the checkpoint.'
}

Rename-Item -LiteralPath "$output/attempt-1/batch.json" -NewName 'batch.unpublished.json'
Rename-Item -LiteralPath "$output/attempt-1/job-finite/checkpoint.commit" -NewName 'checkpoint.unpublished'
$oldProof = (Get-FileHash -LiteralPath "$output/attempt-1/job-safe/result.json").Hash
$resumed = Invoke-Checkpoint resumed 1 --resume
if ($resumed.checkpoint_attempt -ne 2 -or ($resumed.jobs.reused -join ',') -cne 'True,True,False,False' -or
    ($resumed.jobs.result.status -join ',') -cne ($start.jobs.result.status -join ',') -or
    $resumed.jobs[0].result_directory -cne 'attempt-1/job-safe' -or
    $resumed.jobs[2].result_directory -cne 'attempt-2/job-finite' -or
    (Get-FileHash -LiteralPath "$output/attempt-1/job-safe/result.json").Hash -cne $oldProof) {
    throw 'Resume failed to retain verified jobs and retry unpublished or inconclusive jobs.'
}
$again = Invoke-Checkpoint again 1 --resume
if ($again.checkpoint_attempt -ne 3 -or ($again.jobs.reused -join ',') -cne 'True,True,True,False') {
    throw 'Resume failed to recover results across more than one attempt.'
}

$proof = "$output/attempt-1/job-safe/certificate/safety.q3adrat"
$proofBytes = [IO.File]::ReadAllBytes($proof)
Add-Content -LiteralPath $proof -Value 'after-proof'
try { $null = Invoke-Checkpoint wrong-proof 3 --resume }
finally { [IO.File]::WriteAllBytes($proof, $proofBytes) }
$record = "$output/attempt-1/job-safe/result.json"
$original = [IO.File]::ReadAllBytes($record)
Add-Content -LiteralPath $record -Value ' '
try { $null = Invoke-Checkpoint wrong-result 3 --resume }
finally { [IO.File]::WriteAllBytes($record, $original) }

# A refreshed checkpoint digest cannot authorize a different property.
$marker = "$output/attempt-1/job-safe/checkpoint.commit"
$markerBytes = [IO.File]::ReadAllBytes($marker)
$sha = [Security.Cryptography.SHA256]
$utf8 = [Text.Encoding]::UTF8
$identity = [IO.File]::ReadAllBytes("$output/checkpoint.identity")
$identityDigest = [Convert]::ToHexString($sha::HashData($identity)).ToLowerInvariant()
$swapped = $utf8.GetString($original).TrimEnd([char]10).Replace('"p_safe"', '"p_bad"')
$payloadDigest = [Convert]::ToHexString($sha::HashData($utf8.GetBytes($swapped))).ToLowerInvariant()
$binding = @($identityDigest, '1', 'safe', $payloadDigest) -join [char]10
$digest = [Convert]::ToHexString($sha::HashData($utf8.GetBytes($binding))).ToLowerInvariant()
[IO.File]::WriteAllText($record, $swapped + [char]10)
[IO.File]::WriteAllText($marker, $digest + [char]10)
try { $null = Invoke-Checkpoint substituted-property 3 --resume }
finally {
    [IO.File]::WriteAllBytes($record, $original)
    [IO.File]::WriteAllBytes($marker, $markerBytes)
}

$crashPlan = Join-Path $root 'crash.q3b'
@('Q3AFORMAL_BATCH 1', 'memory_mib 384', 'job durable pdr p_safe 12 30000',
  'job interrupted bmc p_safe 10000 3000') | Set-Content -LiteralPath $crashPlan
$crashRoot = Join-Path $root 'crash-checkpoint'
$startInfo = [Diagnostics.ProcessStartInfo]::new($exe)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($item in @('prove-batch', $project, '--plan', $crashPlan, '--output-dir', $crashRoot, '--checkpoint')) {
    $startInfo.ArgumentList.Add($item)
}
$process = [Diagnostics.Process]::Start($startInfo)
try {
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $durable = Join-Path $crashRoot 'attempt-1/job-durable/checkpoint.commit'
    while (!$process.HasExited -and !(Test-Path -LiteralPath $durable) -and $watch.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Milliseconds 5
    }
    if ($process.HasExited -or !(Test-Path -LiteralPath $durable)) {
        throw 'Could not interrupt the live batch after its first committed job.'
    }
    $process.Kill()
    $process.WaitForExit()
    $out.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/crash-start.stdout.txt"
    $err.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/crash-start.stderr.txt"
} finally {
    if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
if (Test-Path -LiteralPath "$crashRoot/attempt-1/batch.json") {
    throw 'The interrupted batch unexpectedly published an aggregate report.'
}
$afterCrash = Invoke-Checkpoint after-crash 1 --resume $crashPlan $crashRoot
if (($afterCrash.jobs.reused -join ',') -cne 'True,False' -or $afterCrash.jobs[0].result.status -cne 'PROVEN') {
    throw 'The new invocation did not recover the committed job from the interrupted process.'
}

$inductionPlan = Join-Path $root 'induction.q3b'
@('Q3AFORMAL_BATCH 1', 'memory_mib 384', 'job base-and-step induction p_hold 2 30000') |
    Set-Content -LiteralPath $inductionPlan
$inductionProject = "$repo/prototype/benchmark/fixtures/P1_elastic_pipeline.q3a"
$inductionRoot = "$root/induction-checkpoint"
$initialInduction = Invoke-Checkpoint induction-start 0 --checkpoint $inductionPlan $inductionRoot $inductionProject
$resumedInduction = Invoke-Checkpoint induction-resume 0 --resume $inductionPlan $inductionRoot $inductionProject
if ($initialInduction.jobs[0].result.status -cne 'PROVEN' -or !$resumedInduction.jobs[0].reused) {
    throw 'The source-backed induction proof did not resume.'
}
[ordered]@{
    status = 'PASS'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checked_reuse = @('PDR invariant', 'PDR witness', 'BMC witness', 'k-induction proof')
    rejected = @('changed input', 'changed plan', 'active writer', 'modified proof', 'modified result', 'substituted property with refreshed digest')
    recovered = @('missing batch summary', 'unpublished job', 'non-conclusive attempt', 'multiple earlier attempts', 'terminated live batch process')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json"
'PASS: checkpoint recovery and independent evidence revalidation.'
