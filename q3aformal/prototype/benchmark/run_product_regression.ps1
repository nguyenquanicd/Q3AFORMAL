#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$Suite,
    [ValidateRange(1, 3600)][int]$PerSuiteTimeoutSeconds = 180,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$prototype = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $prototype
$tests = Join-Path $prototype 'tests'
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$package = & (Join-Path $repo 'scripts/package_windows.ps1') -Archive $archivePath -VerifyOnly | ConvertFrom-Json
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $reader = [IO.StreamReader]::new($zip.GetEntry('package-manifest.json').Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
$executables = @($manifest.files | Where-Object path -Match '^prototype/bin/[^/]+\.exe$')
function Check-ExecutableIdentity {
    foreach ($entry in $executables) {
        $current = (Get-FileHash -LiteralPath (Join-Path $repo $entry.path)).Hash.ToLowerInvariant()
        if ($current -cne $entry.sha256) { throw "Binary identity changed for $($entry.path)." }
    }
}
if ($executables.Count -ne 2) { throw 'Expected two package executables.' }
Check-ExecutableIdentity
$run = if ($Resume) { (Resolve-Path -LiteralPath $OutputDirectory).Path }
    else { (New-Item -ItemType Directory -Path $OutputDirectory).FullName }
$pwsh = (Get-Process -Id $PID).Path
$resultsPath = Join-Path $run 'suites.csv'

$scripts = @(Get-ChildItem -LiteralPath $tests -Filter 'test_*.ps1' -File | Sort-Object Name)
if ($Suite) {
    $scripts = @($scripts | Where-Object BaseName -CIn $Suite)
    if ($scripts.Count -ne $Suite.Count) { throw 'One or more selected suite names are repeated or unavailable.' }
}
function Publish-RegressionLedger([string]$Pending, [string]$Destination) {
    $maximumAttempts = 20
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            [IO.File]::Move($Pending, $Destination, $true)
            return
        } catch {
            $inner = $_.Exception.GetBaseException()
            $windowsCode = $inner.HResult -band 0xffff
            if (!$IsWindows -or $attempt -eq $maximumAttempts -or $windowsCode -notin 5,32,33) {
                throw
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Quote-PowerShell([string]$Value) {
    "'" + $Value.Replace("'", "''") + "'"
}
$roster = [ordered]@{}
foreach ($script in $scripts) {
    $roster[$script.BaseName] = (Get-FileHash -LiteralPath $script.FullName).Hash.ToLowerInvariant()
}
$identity = [ordered]@{
    schema='Q3AFORMAL_PRODUCT_REGRESSION_RUN_1'
    package_sha256=$package.sha256
    build_id=$package.source_build_id
    executables=$executables
    runner_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
    per_suite_timeout_seconds=$PerSuiteTimeoutSeconds
    roster=$roster
} | ConvertTo-Json -Depth 8 -Compress
$lock = [IO.File]::Open((Join-Path $run '.runner.lock'), [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $identityPath = Join-Path $run 'run-identity.json'
    $rows = [Collections.Generic.List[object]]::new()
    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Resume) {
        if ([IO.File]::ReadAllText($identityPath) -cne $identity) {
            throw 'The resumed regression differs in package, runner, suite selection or source, or timeout.'
        }
        if (Test-Path -LiteralPath $resultsPath) {
            foreach ($row in Import-Csv -LiteralPath $resultsPath) {
                if (($roster.Keys -cnotcontains $row.suite) -or $row.script_sha256 -cne $roster[$row.suite] -or
                    !$completed.Add($row.suite) -or $row.status -cnotin @('PASS','FAIL','TIMEOUT') -or
                    $row.exit_code -cnotmatch '^-?\d+$' -or $row.elapsed_ms -cnotmatch '^\d+$' -or
                    ($row.status -ceq 'PASS' -and $row.exit_code -ne '0') -or
                    !(Test-Path -LiteralPath (Join-Path $run "$($row.suite).stdout.txt") -PathType Leaf) -or
                    !(Test-Path -LiteralPath (Join-Path $run "$($row.suite).stderr.txt") -PathType Leaf)) {
                    throw "Invalid resume ledger entry for $($row.suite)."
                }
                $rows.Add($row)
            }
        }
    } else {
        [IO.File]::WriteAllText($identityPath,$identity)
    }
    foreach ($script in $scripts) {
        if ($completed.Contains($script.BaseName)) { continue }
        $artifacts = Join-Path $run ($script.BaseName + '-artifacts')
        if ($Resume -and (Test-Path -LiteralPath $artifacts)) {
            $resolved = (Resolve-Path -LiteralPath $artifacts).Path
            $backup = Join-Path $run ($script.BaseName + '-interrupted-' + [guid]::NewGuid().ToString('n'))
            if ((Split-Path -Parent $resolved) -cne $run -or (Split-Path -Parent $backup) -cne $run -or
                (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Unexpected partial artifacts path for $($script.BaseName)."
            }
            Move-Item -LiteralPath $resolved -Destination $backup
        }
        if ((Get-FileHash -LiteralPath $script.FullName).Hash.ToLowerInvariant() -cne $roster[$script.BaseName]) {
            throw "Suite source changed for $($script.BaseName)."
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Cannot parse $($script.Name)." }
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $start.WorkingDirectory = $repo
        # The executable emits UTF-8 irrespective of the PowerShell console code page.
        $command = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & ' +
            (Quote-PowerShell $script.FullName)
        if ($parameters -ccontains 'UseExistingBuild') { $command += ' -UseExistingBuild' }
        if ($parameters -ccontains 'Archive') { $command += ' -Archive ' + (Quote-PowerShell $archivePath) }
        if ($parameters -ccontains 'OutputDirectory') {
            $command += ' -OutputDirectory ' + (Quote-PowerShell (Join-Path $run ($script.BaseName + '-artifacts')))
        }
        if ($parameters -ccontains 'ReportPath') {
            $command += ' -ReportPath ' + (Quote-PowerShell (Join-Path $run ($script.BaseName + '.json')))
        }
        $command += '; if (!$?) { exit 1 }'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        foreach ($argument in '-NoProfile','-NonInteractive','-EncodedCommand',$encoded) {
            $start.ArgumentList.Add($argument)
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $timedOut = !$process.WaitForExit($PerSuiteTimeoutSeconds * 1000)
            if ($timedOut) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $code = $process.ExitCode
            [IO.File]::WriteAllText((Join-Path $run ($script.BaseName + '.stdout.txt')), $stdout.Result)
            [IO.File]::WriteAllText((Join-Path $run ($script.BaseName + '.stderr.txt')), $stderr.Result)
        } finally {
            $process.Dispose()
        }
        Check-ExecutableIdentity
        $verdict = if ($timedOut) { 'TIMEOUT' } elseif ($code -eq 0) { 'PASS' } else { 'FAIL' }
        if ((Get-FileHash -LiteralPath $script.FullName).Hash.ToLowerInvariant() -cne $roster[$script.BaseName]) {
            throw "Suite source changed while running $($script.BaseName)."
        }
        $rows.Add([pscustomobject]@{suite=$script.BaseName;status=$verdict;exit_code=$code;
            elapsed_ms=$timer.ElapsedMilliseconds;script_sha256=$roster[$script.BaseName]})
        $pendingLedger = Join-Path $run 'suites.csv.pending'
        $rows | Export-Csv -LiteralPath $pendingLedger -NoTypeInformation
        Publish-RegressionLedger $pendingLedger $resultsPath
        "$verdict $($script.BaseName)"
    }
    $count = $rows.Count
    $failed = @($rows | Where-Object status -CNE 'PASS').Count
    [ordered]@{
        schema='Q3AFORMAL_PRODUCT_REGRESSION_1'
        package_sha256=$package.sha256
        build_id=$package.source_build_id
        executables=$executables
        suites=$count
        passed=$count-$failed
        failed_or_timed_out=$failed
        per_suite_timeout_seconds=$PerSuiteTimeoutSeconds
        classification='repository regression on package-identical executables plus standalone component and archived evidence tests'
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $run 'summary.json') -Encoding utf8
    if ($failed) { throw "$failed of $count suites failed or timed out." }
} finally {
    $lock.Dispose()
}
