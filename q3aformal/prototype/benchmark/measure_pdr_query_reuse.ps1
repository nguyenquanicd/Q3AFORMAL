#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1, 20)][int]$Repeats = 5
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$candidate = (Resolve-Path (Join-Path $PSScriptRoot '../bin/q3aformal-sourcecheck.exe')).Path
$baseline = (Resolve-Path -LiteralPath $BaselineExecutable).Path
$output = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$cases = @(
    @{ Id = 'registered-grant'; Manifest = 'P1_arbiter.q3a'; Source = 'P1_arbiter.sv'; Property = 'p_registered_grant' },
    @{ Id = 'six-stage-pipeline'; Manifest = 'P1_pdr_pipeline6.q3a'; Source = 'p1_pdr_pipeline6.sv'; Property = 'p_latency' },
    @{ Id = 'assumption-cone'; Manifest = 'P1_pdr_cone_environment.q3a'; Source = 'p1_pdr_cone_environment.sv'; Property = 'p_quiet' }
)
$builds = @(
    @{ Id = 'baseline'; Executable = $baseline },
    @{ Id = 'candidate'; Executable = $candidate }
)
foreach ($build in $builds) {
    $build.Sha256 = (Get-FileHash -LiteralPath $build.Executable).Hash.ToLowerInvariant()
}
if ($builds[0].Sha256 -ceq $builds[1].Sha256) { throw 'Expected two different binaries.' }

function Invoke-TimedProof($Build, $Case, [string]$Manifest, [int]$Repeat) {
    $id = "$($Case.Id)-$($Build.Id)-$Repeat"
    $directory = Join-Path $output $id
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Build.Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('prove', $Manifest, '--timeout-ms', '30000', '--engine', 'pdr',
        '--property', $Case.Property, '--max-depth', '16', '--evidence-dir', $directory)) {
        $start.ArgumentList.Add($argument)
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    $peak = 0L
    $samples = 0
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (!$process.WaitForExit(10)) {
            if ($clock.ElapsedMilliseconds -gt 35000) {
                $process.Kill()
                $process.WaitForExit()
                throw "Proof exceeded the test watchdog: $id"
            }
            try {
                $process.Refresh()
                $workingSet = $process.PeakWorkingSet64
                if ($workingSet -gt 0) {
                    $peak = [math]::Max($peak, $workingSet)
                    ++$samples
                }
            } catch [InvalidOperationException] {
                if (!$process.HasExited) { throw }
            }
        }
        $clock.Stop()
        $json = $stdout.Result
        $log = $stderr.Result
        $json.TrimEnd() | Set-Content "$directory.result.json"
        $log.TrimEnd() | Set-Content "$directory.stderr.txt"
        if ($process.ExitCode -ne 0 -or ($json | ConvertFrom-Json).status -cne 'PROVEN') {
            throw "Proof did not pass: $id. $json $log"
        }
    } finally {
        $process.Dispose()
    }
    $verified = @(& $candidate verify-pdr $Manifest --property $Case.Property --evidence-dir $directory)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Proof did not reopen: $id."
    }
    $stats = [regex]::Match($log, 'Q3A_PDR_SEARCH_STATS queries=(\d+) cnf_builds=(\d+)')
    $projection = [regex]::Match($log, ' state_bits=(\d+) full_state_bits=(\d+)')
    $signals = [regex]::Match($log, ' signal_bits=(\d+) full_signal_bits=(\d+)')
    if ($Build.Id -ceq 'candidate' -and (!$stats.Success -or
        [int]$stats.Groups[2].Value -ge [int]$stats.Groups[1].Value)) {
        throw "The candidate did not reuse encoded queries: $id."
    }
    [pscustomobject]@{
        workload = $Case.Id
        build = $Build.Id
        executable_sha256 = $Build.Sha256
        repeat = $Repeat
        wall_ms = $clock.Elapsed.TotalMilliseconds
        peak_working_set_bytes = if ($samples) { $peak }
        memory_samples = $samples
        search_queries = if ($stats.Success) { [int]$stats.Groups[1].Value }
        cnf_builds = if ($stats.Success) { [int]$stats.Groups[2].Value }
        search_state_bits = if ($projection.Success) { [int]$projection.Groups[1].Value }
        full_state_bits = if ($projection.Success) { [int]$projection.Groups[2].Value }
        search_signal_bits = if ($signals.Success) { [int]$signals.Groups[1].Value }
        full_signal_bits = if ($signals.Success) { [int]$signals.Groups[2].Value }
        certificate = 'REVALIDATED'
    }
}

$rows = foreach ($case in $cases) {
    $manifest = Join-Path $PSScriptRoot "fixtures/$($case.Manifest)"
    foreach ($repeat in 1..$Repeats) {
        $order = if ($repeat % 2) { $builds } else { $builds[1], $builds[0] }
        foreach ($build in $order) {
            Invoke-TimedProof $build $case $manifest $repeat
        }
    }
}
$rows | Export-Csv (Join-Path $output 'measurements.csv') -NoTypeInformation
$inputs = $cases | ForEach-Object { $_.Manifest; $_.Source }
Get-FileHash ($inputs | ForEach-Object { Join-Path "$PSScriptRoot/fixtures" $_ }) |
    ForEach-Object { [pscustomobject]@{ Artifact = Split-Path -Leaf $_.Path; Sha256 = $_.Hash.ToLowerInvariant() } } |
    Export-Csv (Join-Path $output 'input-hashes.csv') -NoTypeInformation
$rows | Group-Object workload, build | ForEach-Object {
    $times = @($_.Group.wall_ms | Sort-Object)
    [pscustomobject]@{ Group = $_.Name; MedianMs = ($times[[math]::Floor(($times.Count - 1) / 2)] +
        $times[[math]::Ceiling(($times.Count - 1) / 2)]) / 2 }
}
