#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobsPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [ValidateRange(10, 60000)]
    [int]$SampleIntervalMilliseconds = 25,

    [switch]$RequireCompleteHostProfile,

    [string]$ExecutablePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$jobsFullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $JobsPath).Path)
$outputFullPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$repoPrefix = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

function Test-InRepoPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-RepoPath([string]$Path, [string]$BaseDirectory) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $candidate = [System.IO.Path]::GetFullPath($Path)
    } else {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
    }
    if (-not (Test-InRepoPath $candidate)) {
        throw "Benchmark paths must resolve inside the Q3AFormal repository: $Path"
    }
    return $candidate
}

function Get-RepoRelativePath([string]$Path) {
    return [System.IO.Path]::GetRelativePath($repoRoot, [System.IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

function Get-FormalStatus([string]$Text) {
    $matches = [regex]::Matches(
        $Text,
        '(?m)^Q3A_(?:BMC|INDUCTION|SAT|BUNDLE_RESULT)_STATUS\s+([^\s\r\n]+)')
    if ($matches.Count -eq 0) {
        return 'NO_FORMAL_STATUS'
    }
    return $matches[$matches.Count - 1].Groups[1].Value
}

if (-not ('Q3ABenchmarkNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class Q3ABenchmarkNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetPhysicallyInstalledSystemMemory(out ulong totalMemoryInKilobytes);

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx memoryStatus);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformationEx(int relationshipType, IntPtr buffer, ref uint returnedLength);

    public static ulong GetInstalledMemoryBytes()
    {
        ulong kilobytes;
        if (!GetPhysicallyInstalledSystemMemory(out kilobytes))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked(kilobytes * 1024UL);
    }

    public static ulong GetOsVisiblePhysicalMemoryBytes()
    {
        MemoryStatusEx status = new MemoryStatusEx();
        status.Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
        if (!GlobalMemoryStatusEx(ref status))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return status.TotalPhysical;
    }

    public static int GetPhysicalCoreCount()
    {
        uint length = 0;
        GetLogicalProcessorInformationEx(0xffff, IntPtr.Zero, ref length);
        int error = Marshal.GetLastWin32Error();
        if (length == 0 && error != 122)
            throw new Win32Exception(error);

        IntPtr buffer = Marshal.AllocHGlobal(checked((int)length));
        try
        {
            if (!GetLogicalProcessorInformationEx(0xffff, buffer, ref length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            int coreCount = 0;
            int offset = 0;
            while ((uint)offset < length)
            {
                int relationship = Marshal.ReadInt32(buffer, offset);
                int size = Marshal.ReadInt32(buffer, offset + 4);
                if (size < 8 || (ulong)(uint)offset + (uint)size > length)
                    throw new InvalidOperationException("Invalid processor relationship record size.");
                if (relationship == 0) coreCount++;
                offset = checked(offset + size);
            }
            return coreCount;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

if (-not (Test-InRepoPath $jobsFullPath)) {
    throw 'The jobs manifest must be inside the Q3AFormal repository.'
}
if (-not (Test-InRepoPath $outputFullPath)) {
    throw 'The output directory must be inside the Q3AFormal repository.'
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Refusing to reuse an existing benchmark output directory: $(Get-RepoRelativePath $outputFullPath)"
}

$jobsDocument = Get-Content -LiteralPath $jobsFullPath -Raw | ConvertFrom-Json -AsHashtable
if ($jobsDocument.schema -notin 'Q3AFORMAL_PHASE0_BENCHMARK_JOBS_1','Q3AFORMAL_PHASE1_BENCHMARK_JOBS_1') {
    throw 'Unsupported Q3AFormal benchmark jobs manifest schema.'
}
$phaseOne = $jobsDocument.schema -eq 'Q3AFORMAL_PHASE1_BENCHMARK_JOBS_1'
if ($jobsDocument.host_profile_override) {
    if (-not $jobsDocument.host_profile_override.installed_memory_label -or
        -not $jobsDocument.host_profile_override.source) {
        throw 'host_profile_override requires installed_memory_label and source.'
    }
}
if (-not ($jobsDocument.jobs -is [System.Collections.IList]) -or $jobsDocument.jobs.Count -eq 0) {
    throw 'The jobs manifest must contain at least one reviewed job.'
}

$jobsBase = [System.IO.Path]::GetDirectoryName($jobsFullPath)
$override = if ($ExecutablePath) { Resolve-RepoPath $ExecutablePath (Get-Location).Path }
if ($override -and ([IO.Path]::GetFileName($override) -cne 'q3aformal-sourcecheck.exe' -or
    !(Test-Path -LiteralPath $override -PathType Leaf))) {
    throw 'The executable override requires an existing repository-local q3aformal-sourcecheck.exe.'
}
$jobIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$resolvedJobs = [System.Collections.Generic.List[object]]::new()
foreach ($job in $jobsDocument.jobs) {
    if ($job.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Invalid benchmark job ID: $($job.id)"
    }
    if (-not $jobIds.Add([string]$job.id)) {
        throw "Duplicate benchmark job ID: $($job.id)"
    }
    if (-not ($job.arguments -is [System.Collections.IList])) {
        throw "Job '$($job.id)' must provide an arguments array."
    }
    if (-not ($job.input_files -is [System.Collections.IList]) -or $job.input_files.Count -eq 0) {
        throw "Job '$($job.id)' must list every benchmark source and project manifest in input_files."
    }
    if ($null -ne $job.timeout_seconds -and [double]$job.timeout_seconds -lt 0) {
        throw "Job '$($job.id)' timeout_seconds cannot be negative. Use 0 for no timeout."
    }
    if ($job.Keys -contains 'expected_diagnostic_regex') {
        try { $null = [regex]::new([string]$job.expected_diagnostic_regex) }
        catch { throw "Job '$($job.id)' has an invalid expected_diagnostic_regex: $($_.Exception.Message)" }
    }

    $executable = Resolve-RepoPath ([string]$job.executable) $jobsBase
    if ($override -and [IO.Path]::GetFileName($executable) -ieq 'q3aformal-sourcecheck.exe') {
        $executable = $override
    }
    $workingDirectory = if ($job.working_directory) {
        Resolve-RepoPath ([string]$job.working_directory) $jobsBase
    } else {
        $jobsBase
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Job '$($job.id)' executable does not exist: $(Get-RepoRelativePath $executable)"
    }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Job '$($job.id)' working directory does not exist: $(Get-RepoRelativePath $workingDirectory)"
    }
    if ((@($job.arguments | Where-Object { [string]$_ -match '\{JOB_OUTPUT_DIR\}' }).Count -gt 0) -and
        -not $workingDirectory.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Job '$($job.id)' must use the repository root as working_directory when arguments contain {JOB_OUTPUT_DIR}."
    }

    $inputs = foreach ($inputPath in $job.input_files) {
        $resolvedInput = Resolve-RepoPath ([string]$inputPath) $jobsBase
        if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
            throw "Job '$($job.id)' input file does not exist: $(Get-RepoRelativePath $resolvedInput)"
        }
        $resolvedInput
    }
    $resolvedJobs.Add([pscustomobject]@{
        Id = [string]$job.id
        Executable = $executable
        WorkingDirectory = $workingDirectory
        Arguments = @($job.arguments | ForEach-Object { [string]$_ })
        Inputs = @($inputs)
        ExpectedFormalStatus = $(if ($job.Keys -contains 'expected_formal_status') { [string]$job.expected_formal_status } else { $null })
        ExpectedExitCode = $(if ($job.Keys -contains 'expected_exit_code') { [int]$job.expected_exit_code } else { $null })
        ExpectedDiagnosticRegex = $(if ($job.Keys -contains 'expected_diagnostic_regex') { [string]$job.expected_diagnostic_regex } else { $null })
        TimeoutSeconds = $(if ($job.Keys -contains 'timeout_seconds') { [double]$job.timeout_seconds } else { 0.0 })
    })
}

$outputParent = [System.IO.Path]::GetDirectoryName($outputFullPath)
$null = New-Item -ItemType Directory -Force -Path $outputParent
$null = New-Item -ItemType Directory -Path $outputFullPath
$outputEncoding = [System.Text.UTF8Encoding]::new($false)
$q3aExecutable = $resolvedJobs | Where-Object { [System.IO.Path]::GetFileName($_.Executable) -eq 'q3aformal-sourcecheck.exe' } | Select-Object -First 1
$buildInfoPath = Join-Path $repoRoot 'prototype/bin/q3a_build_info.hpp'
$buildId = 'UNAVAILABLE'
$compiler = 'UNAVAILABLE'
$buildInfoHash = 'UNAVAILABLE'
$buildConfiguration = 'C++17 -O2 -Wall -Wextra -Wpedantic'
if ($override) {
    $identity = & $override --version | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $identity.build_id -cnotmatch '^[0-9a-f]{64}$' -or
        !$identity.compiler -or !$identity.build_configuration) {
        throw 'Unable to read runtime identity from the overridden executable.'
    }
    $buildId = $identity.build_id
    $compiler = $identity.compiler
    $buildConfiguration = $identity.build_configuration
} elseif (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) {
    $buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw
    $buildInfoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $buildInfoPath).Hash.ToLowerInvariant()
    if ($buildInfo -match 'kBuildId\[\]\s*=\s*"([^"]+)"') { $buildId = $Matches[1] }
    if ($buildInfo -match 'kCompiler\[\]\s*=\s*"((?:\\.|[^"])*)"') { $compiler = $Matches[1] }
    if ($buildInfo -match 'kBuildConfiguration\[\]\s*=\s*"([^"]+)"') { $buildConfiguration = $Matches[1] }
}

$hostCaptureNotes = [System.Collections.Generic.List[string]]::new()
$cpuRows = @()
$operatingSystem = $null
$computerSystem = $null
try {
    $cpuRows = @(Get-CimInstance -ClassName Win32_Processor)
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
} catch {
    $hostCaptureNotes.Add("CIM: $($_.Exception.Message)")
}
$cpuModels = @($cpuRows | ForEach-Object { $_.Name.Trim() } | Sort-Object -Unique)
$physicalCores = if ($cpuRows.Count) { [int](($cpuRows | Measure-Object -Property NumberOfCores -Sum).Sum) } else { $null }
$logicalProcessors = if ($cpuRows.Count) { [int](($cpuRows | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum) } else { $null }
$installedMemoryBytes = $null
$osVisiblePhysicalMemoryBytes = if ($computerSystem) { [uint64]$computerSystem.TotalPhysicalMemory } else { $null }
$osCaption = if ($operatingSystem) { [string]$operatingSystem.Caption } else { $null }
$osVersion = if ($operatingSystem) { [string]$operatingSystem.Version } else { $null }
$osBuild = if ($operatingSystem) { [string]$operatingSystem.BuildNumber } else { $null }

try {
    if ($cpuModels.Count -eq 0) {
        $cpuRegistry = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name ProcessorNameString -ErrorAction Stop
        $cpuModels = @(([string]$cpuRegistry.ProcessorNameString).Trim())
    }
} catch { $hostCaptureNotes.Add("CPU model: $($_.Exception.Message)") }
try {
    if ($null -eq $physicalCores) { $physicalCores = [Q3ABenchmarkNative]::GetPhysicalCoreCount() }
} catch { $hostCaptureNotes.Add("Physical core count: $($_.Exception.Message)") }
try {
    if ($null -eq $logicalProcessors) { $logicalProcessors = [Environment]::ProcessorCount }
} catch { $hostCaptureNotes.Add("Logical processor count: $($_.Exception.Message)") }
try {
    if ($null -eq $installedMemoryBytes) { $installedMemoryBytes = [Q3ABenchmarkNative]::GetInstalledMemoryBytes() }
} catch { $hostCaptureNotes.Add("Installed memory: $($_.Exception.Message)") }
try {
    if ($null -eq $osVisiblePhysicalMemoryBytes) { $osVisiblePhysicalMemoryBytes = [Q3ABenchmarkNative]::GetOsVisiblePhysicalMemoryBytes() }
} catch { $hostCaptureNotes.Add("OS-visible physical memory: $($_.Exception.Message)") }
$installedMemoryLabel = if ($null -ne $installedMemoryBytes) {
    "$installedMemoryBytes bytes"
} elseif ($jobsDocument.host_profile_override.installed_memory_label) {
    [string]$jobsDocument.host_profile_override.installed_memory_label
} else {
    $null
}
$installedMemorySource = if ($null -ne $installedMemoryBytes) {
    'Windows API'
} elseif ($installedMemoryLabel) {
    [string]$jobsDocument.host_profile_override.source
} else {
    'unavailable'
}
try {
    if (-not $osCaption -or -not $osBuild) {
        $windowsVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if (-not $osCaption) { $osCaption = [string]$windowsVersion.ProductName }
        if (-not $osVersion) { $osVersion = [string]$windowsVersion.DisplayVersion }
        if (-not $osBuild) {
            $osBuild = [string]$windowsVersion.CurrentBuildNumber
            if ($null -ne $windowsVersion.UBR) { $osBuild += ".{0}" -f $windowsVersion.UBR }
        }
    }
} catch { $hostCaptureNotes.Add("OS version: $($_.Exception.Message)") }

$hostProfileComplete = $cpuModels.Count -gt 0 -and $null -ne $physicalCores -and
    $null -ne $logicalProcessors -and $installedMemoryLabel -and
    $osCaption -and $osBuild
$hostProfileStatus = if (-not $hostProfileComplete) {
    'INCOMPLETE'
} elseif ($installedMemorySource -ne 'Windows API') {
    'CAPTURED_WITH_USER_OVERRIDE'
} elseif ($hostCaptureNotes.Count) {
    'CAPTURED_WITH_FALLBACK'
} else {
    'CAPTURED'
}
$hostProfile = [ordered]@{
    captured_at = [DateTimeOffset]::Now.ToString('o')
    host_profile_status = $hostProfileStatus
    host_profile_notes = @($hostCaptureNotes)
    os_caption = $osCaption
    os_version = $osVersion
    os_build = $osBuild
    architecture = $env:PROCESSOR_ARCHITECTURE
    cpu_models = $cpuModels
    physical_cores = $physicalCores
    logical_processors = $logicalProcessors
    installed_memory_label = $installedMemoryLabel
    installed_memory_source = $installedMemorySource
    installed_memory_bytes = $installedMemoryBytes
    os_visible_physical_memory_bytes = $osVisiblePhysicalMemoryBytes
    q3a_build_id = $buildId
    q3a_compiler = $compiler
    q3a_build_configuration = $buildConfiguration
    q3a_build_info_header_sha256 = $buildInfoHash
    q3a_executable_sha256 = $(if ($q3aExecutable) { (Get-FileHash -Algorithm SHA256 -LiteralPath $q3aExecutable.Executable).Hash.ToLowerInvariant() } else { 'NOT_IDENTIFIED' })
    q3a_executable_path = $(if ($q3aExecutable) { Get-RepoRelativePath $q3aExecutable.Executable } else { $null })
    jobs_manifest_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $jobsFullPath).Hash.ToLowerInvariant()
    jobs_manifest_path = (Get-RepoRelativePath $jobsFullPath)
    sample_interval_ms = $SampleIntervalMilliseconds
    performance_thresholds_applied = $false
}
$hostProfile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputFullPath 'environment.json') -Encoding utf8
if ($RequireCompleteHostProfile -and
    (!$hostProfileComplete -or !$buildId -or !$compiler -or !$buildConfiguration -or !$q3aExecutable)) {
    throw 'The official benchmark requires a complete host and build profile before launching jobs.'
}

$records = [System.Collections.Generic.List[object]]::new()
foreach ($job in $resolvedJobs) {
    $jobOutputDirectory = Join-Path $outputFullPath ($job.Id + '-artifacts')
    $null = New-Item -ItemType Directory -Path $jobOutputDirectory
    $stdoutPath = Join-Path $outputFullPath ($job.Id + '.stdout.txt')
    $stderrPath = Join-Path $outputFullPath ($job.Id + '.stderr.txt')
    $inputHashes = [ordered]@{}
    foreach ($input in $job.Inputs) {
        $inputHashes[(Get-RepoRelativePath $input)] = (Get-FileHash -Algorithm SHA256 -LiteralPath $input).Hash.ToLowerInvariant()
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $job.Executable
    $process.StartInfo.WorkingDirectory = $job.WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $jobOutputRelative = Get-RepoRelativePath $jobOutputDirectory
    $expandedArguments = @($job.Arguments | ForEach-Object {
        $_.Replace('{JOB_OUTPUT_DIR}', $jobOutputRelative)
    })
    foreach ($argument in $expandedArguments) { $process.StartInfo.ArgumentList.Add($argument) }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $peakWorkingSet = [int64]0
    $successfulMemorySamples = 0
    $timedOut = $false
    $engineError = $null
    $exitCode = $null
    $stdout = ''
    $stderr = ''
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        try {
            $process.Refresh()
            $peakWorkingSet = [Math]::Max($process.WorkingSet64, $process.PeakWorkingSet64)
            if ($peakWorkingSet -gt 0) { $successfulMemorySamples++ }
        } catch { }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit($SampleIntervalMilliseconds)) {
            try {
                # Process caches its memory snapshot until Refresh is called.
                $process.Refresh()
                $observed = [Math]::Max($process.WorkingSet64, $process.PeakWorkingSet64)
                $peakWorkingSet = [Math]::Max($peakWorkingSet, $observed)
                if ($observed -gt 0) { $successfulMemorySamples++ }
            } catch { }
            if ($job.TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $job.TimeoutSeconds) {
                $timedOut = $true
                $process.Kill($true)
                $process.WaitForExit()
                break
            }
        }
        $process.WaitForExit()
        try {
            $process.Refresh()
            $observed = $process.PeakWorkingSet64
            $peakWorkingSet = [Math]::Max($peakWorkingSet, $observed)
            if ($observed -gt 0) { $successfulMemorySamples++ }
        } catch { }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } catch {
        $engineError = $_.Exception.Message
        if ($process.HasExited) {
            try { $exitCode = $process.ExitCode } catch { }
        } else {
            try { $process.Kill($true); $process.WaitForExit() } catch { }
        }
    } finally {
        $stopwatch.Stop()
        $process.Dispose()
    }

    [System.IO.File]::WriteAllText($stdoutPath, $stdout, $outputEncoding)
    [System.IO.File]::WriteAllText($stderrPath, $stderr, $outputEncoding)
    if ($peakWorkingSet -le 0 -and -not $engineError) {
        $engineError = 'Windows did not provide a non-zero peak working-set measurement.'
    }
    $formalStatus = Get-FormalStatus ($stdout + "`n" + $stderr)
    if ($phaseOne -and $job.Arguments[0] -eq 'prove' -and !$timedOut -and !$engineError) {
        try {
            $summary = ConvertFrom-Json -InputObject $stdout -AsHashtable
            if ($summary.schema_version -ne 1 -or $summary.exit_code -ne $exitCode -or
                $summary.status -notmatch '^[A-Z][A-Z0-9_]*$' -or
                $summary.properties.Count -ne 1 -or $summary.properties[0].status -cne $summary.status) {
                throw 'Result summary fields are inconsistent.'
            }
            $formalStatus = $summary.status
        } catch {
            $engineError = "Invalid product CLI summary: $($_.Exception.Message)"
        }
    }
    $expectedDiagnosticMatch = if ($null -ne $job.ExpectedDiagnosticRegex) {
        [regex]::IsMatch(($stdout + "`n" + $stderr), $job.ExpectedDiagnosticRegex)
    } else {
        $null
    }
    $verdict = if ($engineError) {
        'ENGINE_ERROR'
    } elseif ($timedOut) {
        'TIMEOUT'
    } elseif ($null -eq $job.ExpectedFormalStatus -and $null -eq $job.ExpectedExitCode -and $null -eq $job.ExpectedDiagnosticRegex) {
        'UNASSESSED'
    } else {
        $statusMatches = $null -eq $job.ExpectedFormalStatus -or $formalStatus -eq $job.ExpectedFormalStatus
        $exitMatches = $null -eq $job.ExpectedExitCode -or $exitCode -eq $job.ExpectedExitCode
        $diagnosticMatches = $null -eq $job.ExpectedDiagnosticRegex -or $expectedDiagnosticMatch
        if ($statusMatches -and $exitMatches -and $diagnosticMatches) { 'EXPECTED' } else { 'MISMATCH' }
    }

    $records.Add([pscustomobject][ordered]@{
        job_id = $job.Id
        formal_status = $formalStatus
        process_exit_code = $exitCode
        measurement_verdict = $verdict
        expected_formal_status = $job.ExpectedFormalStatus
        expected_exit_code = $job.ExpectedExitCode
        expected_diagnostic_regex = $job.ExpectedDiagnosticRegex
        expected_diagnostic_match = $expectedDiagnosticMatch
        timed_out = $timedOut
        timeout_seconds = $job.TimeoutSeconds
        elapsed_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        peak_working_set_bytes = $peakWorkingSet
        successful_memory_samples = $successfulMemorySamples
        executable = (Get-RepoRelativePath $job.Executable)
        executable_sha256 = ((Get-FileHash -Algorithm SHA256 -LiteralPath $job.Executable).Hash.ToLowerInvariant())
        working_directory = (Get-RepoRelativePath $job.WorkingDirectory)
        job_output_directory = (Get-RepoRelativePath $jobOutputDirectory)
        arguments_json = (ConvertTo-Json -InputObject $job.Arguments -Compress)
        input_hashes_json = (ConvertTo-Json -InputObject $inputHashes -Compress)
        stdout_log = [System.IO.Path]::GetFileName($stdoutPath)
        stderr_log = [System.IO.Path]::GetFileName($stderrPath)
        engine_error = $engineError
    })
}

$records | Export-Csv -LiteralPath (Join-Path $outputFullPath 'measurements.csv') -NoTypeInformation -Encoding utf8
$phaseLabel = if ($phaseOne) { 'Phase 1' } else { 'Phase 0' }
Write-Output "Captured $($records.Count) raw $phaseLabel benchmark run(s) in $(Get-RepoRelativePath $outputFullPath). No performance thresholds were applied."
