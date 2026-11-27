#requires -Version 7.0
param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$project = Join-Path $prototype 'pdr-pipeline.q3a'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-batch-test-' + [guid]::NewGuid()))).FullName
$stderr = Join-Path $root 'stderr.log'

function Run-Batch($Plan, $Directory, $Code, $Status, [string[]]$Options = @()) {
    $lines = @(& $exe prove-batch $project --plan $Plan --output-dir $Directory @Options 2> $stderr)
    $actual = $LASTEXITCODE
    if ($lines.Count -ne 1) { throw "Expected one batch JSON response. $lines" }
    $result = $lines[0] | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Unexpected batch result. $lines $(Get-Content -LiteralPath $stderr -Raw)"
    }
    if ($result.jobs.Count) {
        $report = Join-Path $Directory 'batch.json'
        $loadCancelled = $result.cancellation_stage -ceq 'source_loading'
        $validSource = if ($loadCancelled) {
            $result.status -ceq 'CANCELLED' -and $result.cancellation_cause -ceq 'cancel_file' -and
                $result.PSObject.Properties.Name -cnotcontains 'source_set_sha256'
        } else {
            $result.source_set_sha256 -cmatch '^[0-9a-f]{64}$'
        }
        if ((Get-Content -LiteralPath $report -Raw).TrimEnd() -cne $lines[0] -or
            $result.workers -ne 1 -or !$validSource -or
            $result.plan_sha256 -cne (Get-FileHash -LiteralPath $Plan).Hash.ToLowerInvariant()) {
            throw 'The persisted report does not identify the exact batch.'
        }
        foreach ($job in $result.jobs) {
            if ($job.result.status -ceq 'NOT_RUN') { continue }
            $jobPath = Join-Path $Directory "$($job.result_directory)/result.json"
            $saved = Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json
            if (($saved | ConvertTo-Json -Depth 10 -Compress) -cne
                    ($job.result | ConvertTo-Json -Depth 10 -Compress) -or
                $saved.source_set_sha256 -cne $result.source_set_sha256 -or
                $saved.build_id -cne $result.build_id -or $saved.timeout_ms -ne $job.timeout_ms) {
                throw "Job $($job.id) lost its recorded identity, deadline, or result."
            }
        }
    }
    return $result
}

try {
    $plan = Join-Path $root 'mixed.q3b'
    @(
        'Q3AFORMAL_BATCH 1'
        'memory_mib 1024'
        'job safe pdr p_safe 12 30000'
        'job delayed pdr p_temporal 12 30000'
        'job deadline bmc p_safe 10000 1'
        'job induction induction p_safe 1 30000'
        'job fail pdr p_bad 12 30000'
    ) | Set-Content -LiteralPath $plan
    $mixed = Join-Path $root 'mixed'
    $report = Run-Batch $plan $mixed 1 'INCONCLUSIVE'
    if (($report.jobs.id -join ',') -cne 'safe,delayed,deadline,induction,fail' -or
        ($report.jobs.result.status -join ',') -cne 'PROVEN,FAIL,TIMEOUT,NOT_1_INDUCTIVE,FAIL' -or
        $report.memory_mib -ne 1024) {
        throw "The mixed batch did not preserve job order or continue after a local failure."
    }
    foreach ($job in $report.jobs) {
        $configuration = $job.result.run_configuration
        if ($job.result.status -ceq 'TIMEOUT') {
            if ($null -ne $configuration) { throw 'The version 1 interruption record changed shape.' }
            continue
        }
        $depth = if ($job.engine -ceq 'pdr') { $configuration.maximum_depth }
                 else { $configuration.induction_depth }
        if ($configuration.source_set_sha256 -cne $report.source_set_sha256 -or
            $configuration.build_id -cne $report.build_id -or
            $configuration.engine -cne $job.engine -or $depth -ne $job.depth -or
            $configuration.workers -ne $report.workers -or
            $configuration.search_private_limit_bytes -le 0 -or
            $configuration.search_private_limit_bytes -gt 1024MB) {
            throw "Job $($job.id) lost its effective configuration inside the batch."
        }
    }
    $checkedDirectory = Join-Path $mixed 'job-safe/certificate'
    $jobRecord = Get-Content -LiteralPath (Join-Path $mixed 'job-safe/result.json') -Raw | ConvertFrom-Json
    $descriptor = $report.jobs[0].result.certificate
    if ($descriptor.directory -cne $checkedDirectory -or $descriptor.build_id -cne $report.build_id -or
        ($descriptor | ConvertTo-Json -Depth 6 -Compress) -cne
            ($jobRecord.certificate | ConvertTo-Json -Depth 6 -Compress) -or
        @($report.jobs | Where-Object { $null -ne $_.result.certificate }).Count -ne 1) {
        throw 'Batch and job records do not identify the same checked PDR certificate.'
    }
    $cert = @(& $exe verify-pdr $project --property p_safe --evidence-dir $descriptor.directory)
    if ($LASTEXITCODE -ne 0 -or $cert -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') { throw 'Batch certificate failed.' }
    $hit = @(& $exe --verify-bundle (Join-Path $mixed 'job-fail/bundle'))
    if ($LASTEXITCODE -ne 0 -or $hit -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') { throw 'Batch witness failed.' }
    $hit = @(& $exe --verify-bundle (Join-Path $mixed 'job-delayed/bundle'))
    if ($LASTEXITCODE -ne 0 -or $hit -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') { throw 'Delayed batch witness failed.' }
    $null = Run-Batch $plan $mixed 2 'SETUP_ERROR'
    $after = Get-Content -LiteralPath (Join-Path $mixed 'batch.json') -Raw | ConvertFrom-Json
    if ($after.jobs.Count -ne 5) { throw 'A collision changed the existing batch report.' }

    $conclusive = Join-Path $root 'conclusive.q3b'
    @('Q3AFORMAL_BATCH 1', 'memory_mib 1024', 'job proved pdr p_safe 12 30000',
      'job failed pdr p_bad 12 30000') | Set-Content -LiteralPath $conclusive
    $report = Run-Batch $conclusive (Join-Path $root 'conclusive') 0 'COMPLETED'
    if (($report.jobs.result.status -join ',') -cne 'PROVEN,FAIL') {
        throw 'The aggregate erased the distinction between a proof and a checked failure.'
    }

    $tiny = Join-Path $root 'tiny.q3b'
    @('Q3AFORMAL_BATCH 1', 'memory_mib 1', 'job capped pdr p_safe 12 30000') | Set-Content -LiteralPath $tiny
    $report = Run-Batch $tiny (Join-Path $root 'tiny') 1 'INCONCLUSIVE'
    if ($report.jobs[0].result.status -cne 'RESOURCE_LIMIT' -or
        $report.jobs[0].result.resource_limit -cne 'memory') {
        throw 'The batch-specific process-memory limit was ignored.'
    }

    $stop = Join-Path $root 'stop requested'
    [IO.File]::WriteAllText($stop, '')
    $cancelled = Join-Path $root 'cancelled'
    $report = Run-Batch $plan $cancelled 1 'CANCELLED' @('--cancel-file', $stop)
    if ($report.cancellation_stage -cne 'source_loading' -or
        ($report.jobs.result.status -join ',') -cne 'NOT_RUN,NOT_RUN,NOT_RUN,NOT_RUN,NOT_RUN' -or
        @(Get-ChildItem -LiteralPath $cancelled -Directory).Count -ne 0) {
        throw 'Pre-cancellation started one or more proof jobs.'
    }

    $budgetPlan = Join-Path $root 'query-budget.q3b'
    @('Q3AFORMAL_BATCH 2', 'memory_mib 384',
        'job low pdr p_safe 12 30000 max_queries 1',
        'job configured pdr p_safe 12 30000 max_queries 50000',
        'job inherited pdr p_safe 12 30000',
        'job bounded bmc p_safe 4 30000') | Set-Content -LiteralPath $budgetPlan
    $budgetRoot = Join-Path $root 'v2'
    $report = Run-Batch $budgetPlan $budgetRoot 1 'INCONCLUSIVE'
    if ($report.plan_schema_version -ne 2 -or ($report.jobs.result.status -join ',') -cne
            'RESOURCE_LIMIT,PROVEN,PROVEN,BOUNDED_PASS' -or
        $report.jobs[0].max_queries -ne 1 -or $report.jobs[0].result.resource_limit -cne 'search' -or
        $report.jobs[0].result.pdr_configuration.maximum_search_queries -ne 1 -or
        $report.jobs[1].max_queries -ne 50000 -or $report.jobs[1].result.pdr_configuration.maximum_search_queries -ne 50000 -or
        $null -ne $report.jobs[2].max_queries -or $report.jobs[2].result.pdr_configuration.maximum_search_queries -ne 10000 -or
        $null -ne $report.jobs[3].max_queries -or (Test-Path -LiteralPath (Join-Path $budgetRoot 'job-low/certificate'))) {
        throw 'Version 2 did not preserve the independent query budgets and their corresponding statuses.'
    }
    foreach ($job in $report.jobs[1], $report.jobs[2]) {
        $verified = @(& $exe verify-pdr $project --property p_safe --evidence-dir $job.result.certificate.directory)
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw "Could not revalidate version 2 proof $($job.id)."
        }
    }
    foreach ($file in (Get-ChildItem -LiteralPath $report.jobs[1].result.certificate.directory -File |
        Where-Object Name -CNE 'run-configuration.json')) {
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -cne (Get-FileHash -LiteralPath (Join-Path $report.jobs[2].result.certificate.directory $file.Name)).Hash) {
            throw "Changing only the query budget altered proof artifact $($file.Name)."
        }
    }
    $cancelledV2 = Run-Batch $budgetPlan (Join-Path $root 'v2-cancelled') 1 'CANCELLED' @('--cancel-file', $stop)
    if ($cancelledV2.cancellation_stage -cne 'source_loading' -or
        @($cancelledV2.jobs | Where-Object { $_.result.status -cne 'NOT_RUN' }).Count -ne 0 -or
        $cancelledV2.jobs[1].max_queries -ne 50000) {
        throw 'A pending version 2 job lost its declared query budget on cancellation.'
    }
    'PASS: version 2 batch query budgets, unchanged defaults, isolated results, and cancellation metadata.'

    $invalid = Join-Path $root 'invalid.q3b'
    $unused = Join-Path $root 'output-must-not-exist'
    $prefix = @('Q3AFORMAL_BATCH 1', 'memory_mib 1024')
    $badPlans = @(
        ,@('Q3AFORMAL_BATCH 1', 'job no-limit pdr p_safe 12 30000')
        ,($prefix + @('job duplicate pdr p_safe 12 30000', 'job duplicate bmc p_bad 1 30000'))
        ,($prefix + 'job ../invalid bmc p_safe 1 30000')
        ,($prefix + 'job zero-deadline pdr p_safe 12 0')
        ,($prefix + 'job excessive-bound pdr p_safe 129 30000')
    )
    $prefixV2 = @('Q3AFORMAL_BATCH 2', 'memory_mib 384')
    $badPlans += ,($prefix + 'job old-format pdr p_safe 12 30000 max_queries 2')
    $badPlans += ,($prefixV2 + 'job incompatible bmc p_safe 6 30000 max_queries 2')
    $badPlans += ,($prefixV2 + 'job incompatible induction p_safe 2 30000 max_queries 2')
    $badPlans += ,($prefixV2 + 'job zero pdr p_safe 12 30000 max_queries 0')
    $badPlans += ,($prefixV2 + 'job invalid pdr p_safe 12 30000 max_queries 18446744073709551616')
    $badPlans += ,($prefixV2 + 'job missing pdr p_safe 12 30000 max_queries')
    $badPlans += ,($prefixV2 + 'job duplicated pdr p_safe 12 30000 max_queries 1 max_queries 2')
    foreach ($badPlan in $badPlans) {
        $badPlan | Set-Content -LiteralPath $invalid
        $null = Run-Batch $invalid $unused 2 'SETUP_ERROR'
        if (Test-Path -LiteralPath $unused) { throw 'An invalid plan created the output directory.' }
    }
    'PASS: ordered batch results, checked proof and witness, per-job timeout and memory, cancellation, twelve invalid plans, and collision protection.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-batch-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
