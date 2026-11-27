#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange('Positive')][int]$PhysicalReserveMiB = 2048
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $prototype
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$project = Join-Path $PSScriptRoot 'fixtures/P1_fifo_contract.q3a'
$jobs = Join-Path $PSScriptRoot 'phase1-fifo-width-jobs.pilot.json'
$run = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory }
    else { Join-Path $repo $OutputDirectory }
$oldLimit = $env:Q3A_MEMORY_LIMIT_MIB
$oldReserve = $env:Q3A_MEMORY_RESERVE_MIB
$limit = 384
$reserve = $PhysicalReserveMiB

function Check-Drat($Cnf, $Proof, $Model, $Kind) {
    $checks = @(& $checker --check-drat $Cnf $Proof --model-sha256 $Model --query-kind $Kind)
    if ($LASTEXITCODE -ne 0 -or $checks -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone checker rejected $Kind."
    }
    return [ordered]@{
        obligation=$Kind
        cnf_sha256=(Get-FileHash -LiteralPath $Cnf).Hash.ToLowerInvariant()
        proof_sha256=(Get-FileHash -LiteralPath $Proof).Hash.ToLowerInvariant()
        verdict=$checks
    }
}

try {
    $env:Q3A_MEMORY_LIMIT_MIB = [string]$limit
    $env:Q3A_MEMORY_RESERVE_MIB = [string]$reserve
    & (Join-Path $PSScriptRoot 'run_phase0_benchmarks.ps1') -JobsPath $jobs -OutputDirectory $run -RequireCompleteHostProfile
    $rows = @(Import-Csv -LiteralPath (Join-Path $run 'measurements.csv'))
    $expectedJobs = @((Get-Content -LiteralPath $jobs -Raw | ConvertFrom-Json).jobs.id)
    if ($rows.Count -ne $expectedJobs.Count -or
        @($rows.job_id | Sort-Object -Unique).Count -ne $expectedJobs.Count) {
        throw 'The benchmark did not return the complete FIFO width matrix.'
    }
    $exeHash = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    $results = foreach ($row in $rows) {
        if ($row.job_id -cnotin $expectedJobs -or $row.job_id -cnotmatch '^fifo-(4|8|16|32)-(pdr|induction)$' -or
            $row.executable_sha256 -cne $exeHash -or [long]$row.peak_working_set_bytes -le 0 -or
            $row.measurement_verdict -cne 'UNASSESSED') {
            throw "Invalid measurement for $($row.job_id)."
        }
        $width = [int]$Matches[1]
        $engine = $Matches[2]
        $directory = Join-Path $repo $row.job_output_directory
        $summary = Get-Content -LiteralPath (Join-Path $run $row.stdout_log) -Raw | ConvertFrom-Json
        if ($summary.status -cne $row.formal_status -or $summary.exit_code -ne [int]$row.process_exit_code -or
            $summary.timeout_ms -ne 10000) { throw "Incorrect run control record for $($row.job_id)." }
        $progress = Get-Content -LiteralPath (Join-Path $run $row.stderr_log) -Raw
        $queries = $null
        $cnfBuilds = $null
        $initialZeroRejections = $null
        if ($progress -match '(?m)^Q3A_PDR_SEARCH_STATS queries=(\d+) cnf_builds=(\d+)') {
            $queries = [int]$Matches[1]
            $cnfBuilds = [int]$Matches[2]
        }
        if ($progress -match '(?m)^Q3A_PDR_SEARCH_STATS .* initial_zero_rejections=(\d+)') {
            $initialZeroRejections = [int]$Matches[1]
        }
        if ($engine -ceq 'pdr' -and ($summary.status -ceq 'PROVEN' -or $summary.resource_limit -ceq 'search') -and
            $null -eq $queries) { throw "PDR search statistics missing for $($row.job_id)." }
        $checked = @()
        if ($summary.status -ceq 'PROVEN') {
            if ($summary.exit_code -ne 0) { throw 'PROVEN returned a nonzero exit code.' }
            if ($engine -ceq 'pdr') {
                $certificate = Join-Path $directory 'certificate'
                $verification = @(& $exe verify-pdr $project --parameter DATA_WIDTH $width --property p_step --evidence-dir $certificate)
                if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
                    throw "Source-backed PDR verification failed at width $width."
                }
                $model = (Get-Content -LiteralPath (Join-Path $certificate 'invariant.txt') -TotalCount 2)[1]
                $checked = @(foreach ($kind in 'initiation','consecution','safety') {
                    Check-Drat (Join-Path $certificate "$kind.cnf") (Join-Path $certificate "$kind.q3adrat") $model "pdr-$kind"
                })
            } else {
                $bundle = Join-Path $directory 'bundle'
                $verification = @(& $exe --verify-bundle $bundle --require-source-model)
                if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
                    $verification -cnotcontains 'Q3A_BUNDLE_REVALIDATION ACCEPTED proof_artifacts=2') {
                    throw "Source-backed induction verification failed at width $width."
                }
                $manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
                $checked = @(foreach ($query in $manifest.queries) {
                    $proof = $manifest.artifacts | Where-Object {
                        $_.role -ceq 'checked_drat_proof' -and $_.path.EndsWith("/$($query.id).q3adrat")
                    }
                    if (!$proof) { throw "Induction proof $($query.id) missing at width $width." }
                    Check-Drat (Join-Path $bundle $query.cnf_path) (Join-Path $bundle $proof.path) $manifest.model.sha256 $query.kind
                })
            }
            $verification | Set-Content -LiteralPath (Join-Path $run "$($row.job_id).revalidation.txt") -Encoding utf8
        } elseif ($summary.status -cin 'RESOURCE_LIMIT','TIMEOUT','UNKNOWN') {
            if ($summary.exit_code -ne 1 -or (Test-Path -LiteralPath (Join-Path $directory 'certificate')) -or
                (Test-Path -LiteralPath (Join-Path $directory 'bundle')) -or
                @(Get-ChildItem -LiteralPath $directory -Filter '*.q3adrat').Count) {
                throw "Inconclusive run produced unexpected proof evidence for $($row.job_id)."
            }
        } else {
            throw "Unexpected functional result for $($row.job_id): $($summary.status)."
        }
        [ordered]@{
            id=$row.job_id; width=$width; engine=$engine; status=$summary.status
            resource_limit=$summary.resource_limit; timeout_stage=$summary.timeout_stage
            process_wall_ms=[double]$row.elapsed_ms; peak_working_set_bytes=[long]$row.peak_working_set_bytes
            pdr_sat_queries=$queries; pdr_cnf_builds=$cnfBuilds; pdr_initial_zero_rejections=$initialZeroRejections; checked_drat=$checked
        }
    }
    [ordered]@{
        schema='Q3AFORMAL_FIFO_PAYLOAD_WIDTH_PILOT_1'
        executable_sha256=$exeHash
        checker_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
        job_manifest_sha256=(Get-FileHash -LiteralPath $jobs).Hash.ToLowerInvariant()
        input_private_memory_limit_mib=$limit
        requested_physical_reserve_mib=$reserve
        per_job_deadline_ms=10000
        classification='engineering comparison, no release thresholds applied'
        runs=$results
    } | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $run 'qualification.json') -Encoding utf8
    $results | ForEach-Object { [pscustomobject]$_ } |
        Format-Table width,engine,status,resource_limit,process_wall_ms,peak_working_set_bytes,pdr_sat_queries
} finally {
    $env:Q3A_MEMORY_LIMIT_MIB = $oldLimit
    $env:Q3A_MEMORY_RESERVE_MIB = $oldReserve
}
