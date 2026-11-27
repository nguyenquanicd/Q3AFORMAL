#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$LimitsPath, [string]$ExecutablePath
)

$ErrorActionPreference = 'Stop'
$run = (Resolve-Path -LiteralPath $RunDirectory).Path
$planPath = Join-Path $PSScriptRoot 'phase1-block-jobs.pilot.json'
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$limits = Get-Content -LiteralPath $LimitsPath -Raw | ConvertFrom-Json
$environment = Get-Content -LiteralPath (Join-Path $run 'environment.json') -Raw | ConvertFrom-Json
$planHash = (Get-FileHash -LiteralPath $planPath).Hash.ToLowerInvariant()
if ($limits.schema -cne 'Q3AFORMAL_PHASE1_BLOCK_LIMITS_1' -or
    $limits.approval_status -cnotin 'PROPOSED', 'APPROVED' -or
    $limits.workload_sha256 -cne $planHash -or $environment.jobs_manifest_sha256 -cne $planHash) {
    throw 'The limit record and run must identify the frozen Phase 1 workload.'
}

$isApproved = $limits.approval_status -ceq 'APPROVED'
if ($isApproved) {
    if (!$limits.approval_reference -or !$limits.approved_at -or !$environment.captured_at -or
        [DateTimeOffset]$environment.captured_at -le [DateTimeOffset]$limits.approved_at) {
        throw 'Acceptance measurement must start after the recorded approval.'
    }
}
if ($environment.host_profile_status -cnotin 'CAPTURED', 'CAPTURED_WITH_FALLBACK', 'CAPTURED_WITH_USER_OVERRIDE' -or
    $environment.architecture -cne $limits.host.architecture -or
    $environment.cpu_models -cnotcontains $limits.host.cpu_model -or
    !$limits.host.installed_memory_label -or
    $environment.installed_memory_label -cne $limits.host.installed_memory_label) {
    throw 'Benchmark host identity differs from the limit record.'
}

$inputs = @($plan.jobs.input_files | Sort-Object -Unique)
$recorded = @($limits.inputs.PSObject.Properties.Name)
if ($inputs.Count -ne $recorded.Count -or @($inputs | Where-Object { $_ -cnotin $recorded }).Count) {
    throw 'The approved input roster differs from the frozen workload.'
}
foreach ($path in $inputs) {
    $digest = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $path)).Hash.ToLowerInvariant()
    if ($limits.inputs.$path -cne $digest) { throw "Frozen input changed: $path" }
}

$jobIds = @($plan.jobs.id)
$limitIds = @($limits.jobs.id)
if ($limitIds.Count -ne $jobIds.Count -or @($limitIds | Sort-Object -Unique).Count -ne $jobIds.Count -or
    @($limitIds | Where-Object { $_ -cnotin $jobIds }).Count) {
    throw 'The limit record must name each benchmark job exactly once.'
}

& (Join-Path $PSScriptRoot 'verify_phase1_block_pilot.ps1') -RunDirectory $run -ExecutablePath $ExecutablePath | Out-Null
$measurements = @(Import-Csv -LiteralPath (Join-Path $run 'measurements.csv'))
$verdicts = foreach ($job in $limits.jobs) {
    $row = $measurements | Where-Object job_id -CEQ $job.id
    $wall = 0.0
    $peak = 0L
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (![double]::TryParse($row.elapsed_ms, [Globalization.NumberStyles]::AllowDecimalPoint, $culture, [ref]$wall) -or
        [double]::IsInfinity($wall) -or $wall -le 0 -or ![long]::TryParse($row.peak_working_set_bytes, [ref]$peak) -or
        $peak -le 0 -or [int]$row.successful_memory_samples -lt 1 -or
        $job.max_wall_ms -isnot [long] -or $job.max_wall_ms -le 0 -or
        $job.max_peak_working_set_bytes -isnot [long] -or $job.max_peak_working_set_bytes -le 0) {
        throw "Invalid resource limits or measurements for $($job.id)."
    }
    [ordered]@{
        id = $job.id
        elapsed_ms = $wall
        peak_working_set_bytes = $peak
        max_wall_ms = $job.max_wall_ms
        max_peak_working_set_bytes = $job.max_peak_working_set_bytes
        within_limits = $wall -le $job.max_wall_ms -and $peak -le $job.max_peak_working_set_bytes
    }
}
$withinLimits = @($verdicts | Where-Object { !$_.within_limits }).Count -eq 0
[ordered]@{
    status = if ($isApproved) {
        if ($withinLimits) { 'APPROVED_LIMITS_MET' } else { 'APPROVED_LIMITS_MISSED' }
    } elseif ($withinLimits) { 'PREVIEW_WITHIN_PROPOSED_LIMITS' } else { 'PREVIEW_LIMITS_MISSED' }
    approval_status = $limits.approval_status
    workload_sha256 = $planHash
    limits_sha256 = (Get-FileHash -LiteralPath $LimitsPath).Hash.ToLowerInvariant()
    executable_sha256 = $environment.q3a_executable_sha256
    measurements_captured_at = $environment.captured_at
    jobs = @($verdicts)
} | ConvertTo-Json -Depth 6
if ($isApproved -and !$withinLimits) { throw 'The benchmark missed approved limits.' }
