$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $prototypeRoot
$benchmarkRoot = Join-Path $prototypeRoot 'benchmark'
$manifestPath = Join-Path $benchmarkRoot 'phase0-jobs.proposed.json'
$document = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'

if (-not (Test-Path -LiteralPath $sourcecheck -PathType Leaf)) {
    throw "Q3AFormal executable does not exist: $sourcecheck"
}

$jobs = @($document.jobs | Where-Object { $_.id -like 'B-05*' })
if ($jobs.Count -ne 4) {
    throw "Expected four B-05 negative jobs, found $($jobs.Count)."
}

foreach ($job in $jobs) {
    if ($job.arguments.Count -ne 2 -or $job.arguments[0] -ne '--lower-project') {
        throw "B-05 job '$($job.id)' must invoke only --lower-project, before any proof command."
    }
    foreach ($relativeInput in $job.input_files) {
        $inputPath = [System.IO.Path]::GetFullPath((Join-Path $benchmarkRoot $relativeInput))
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "B-05 job '$($job.id)' input file is missing: $relativeInput"
        }
    }

    $projectArgument = [string]$job.arguments[1]
    $projectPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $projectArgument))
    $output = @(& $sourcecheck '--lower-project' $projectPath 2>&1)
    $exitCode = $LASTEXITCODE
    $combinedOutput = $output -join "`n"
    if ($exitCode -ne [int]$job.expected_exit_code) {
        throw "B-05 job '$($job.id)' exited $exitCode; expected $($job.expected_exit_code).`n$combinedOutput"
    }
    if (-not [regex]::IsMatch($combinedOutput, [string]$job.expected_diagnostic_regex)) {
        throw "B-05 job '$($job.id)' did not match its diagnostic regular expression.`n$combinedOutput"
    }
    if ([regex]::IsMatch($combinedOutput, '(?m)^Q3A_(?:BMC|INDUCTION|SAT|BUNDLE_RESULT)_STATUS\b')) {
        throw "B-05 job '$($job.id)' unexpectedly emitted a formal-query status."
    }
}

Write-Output 'PASS: all four B-05 unsupported-input jobs stop before formal proof/query and match their expected diagnostics.'
