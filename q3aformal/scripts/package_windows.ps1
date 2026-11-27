#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$CompilerLicenseDirectory,
    [Parameter(ParameterSetName = 'Build')][string]$SourceBuildDirectory,
    [Parameter(ParameterSetName = 'Build')][string]$ProofCheckerExecutable,
    [Parameter(ParameterSetName = 'Build')][switch]$DevelopmentPreview,
    [Parameter(ParameterSetName = 'Build')][string]$Objdump = 'objdump',
    [Parameter(Mandatory, ParameterSetName = 'Verify')][switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$archivePath = [IO.Path]::GetFullPath($Archive)
$manifestName = 'package-manifest.json'
$legacyPackageSchema = 'Q3AFORMAL-WINDOWS-PACKAGE-1'
$packageSchema = 'Q3AFORMAL-WINDOWS-PACKAGE-2'
$fourStatePackageSchema = 'Q3AFORMAL-WINDOWS-PACKAGE-3'
$maxPayloadBytes = 32MB
$licenseFiles = @(
    'libstdc++/COPYING3', 'libstdc++/COPYING.RUNTIME',
    'libgcc/COPYING3', 'libgcc/COPYING.RUNTIME',
    'crt/COPYING', 'crt/COPYING.MinGW-w64-runtime.txt',
    'crt/COPYING.MinGW-w64.txt', 'libwinpthread/COPYING'
)
$legacyPayloads = @(
    'README.md',
    'prototype/bin/q3aformal-sourcecheck.exe',
    'prototype/bin/q3aformal-proofcheck.exe',
    'prototype/pdr-pipeline.q3a',
    'prototype/pdr-cover.q3a',
    'prototype/corpus/source-model-vectors/pdr_pipeline.sv',
    'prototype/corpus/source-model-vectors/pdr_cover.sv'
) + @($licenseFiles | ForEach-Object { "licenses/$_" })
$payloads = $legacyPayloads + 'prototype/batch-pipeline.q3b'
$fourStatePayloads = $payloads + @(
    'prototype/four-state-cover.q3a',
    'prototype/corpus/source-model-vectors/four_state_cover.sv'
)

function Test-FourStateBuild([string]$BuildConfiguration) {
    return $BuildConfiguration -cmatch '(?:^|\s)-DQ3A_ENABLE_DEVELOPMENT_FOUR_STATE(?:=[^\s]+)?(?:$|\s)'
}

function Get-PackageChannel([string]$BuildConfiguration) {
    if ($BuildConfiguration -cmatch '(?:^|\s)-DQ3A_ENABLE_DEVELOPMENT_[A-Z_]+(?:=[^\s]+)?(?:$|\s)') {
        return 'development-preview'
    }
    return 'internal-candidate'
}

function Read-PackageManifest($zipEntry) {
    if ($zipEntry.Length -le 0 -or $zipEntry.Length -gt 64KB) {
        throw 'Invalid package manifest size.'
    }
    $reader = [IO.StreamReader]::new($zipEntry.Open())
    try {
        $buffer = [char[]]::new(64KB + 1)
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -eq $buffer.Length) { throw 'Package manifest exceeds its read limit.' }
        return [string]::new($buffer, 0, $length) | ConvertFrom-Json -AsHashtable
    } finally {
        $reader.Dispose()
    }
}

function Get-ZipMemberDigest($entry) {
    $content = $entry.Open()
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(64KB)
        [long]$remaining = $entry.Length
        while ($remaining -gt 0) {
            $count = $content.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
            if ($count -eq 0) { throw "Truncated ZIP member: $($entry.FullName)" }
            $hasher.AppendData($buffer, 0, $count)
            $remaining -= $count
        }
        if ($content.ReadByte() -ne -1) { throw "Incorrect ZIP member size: $($entry.FullName)" }
        return [BitConverter]::ToString($hasher.GetHashAndReset()).Replace('-', '').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
        $content.Dispose()
    }
}

function Verify-Package([IO.Compression.ZipArchive]$zip) {
    $entries = [Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
    [long]$total = 0
    foreach ($entry in $zip.Entries) {
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        $nonFileAttributes = ($entry.ExternalAttributes -band 0x410) -ne 0
        if (($entry.FullName -cnotin $fourStatePayloads -and $entry.FullName -cne $manifestName) -or
            $unixType -notin 0, 0x8000 -or $nonFileAttributes -or
            !$entries.TryAdd($entry.FullName, $entry) -or $entry.Length -le 0) {
            throw 'Unexpected, unsafe, empty, or duplicate ZIP member.'
        }
        if ($entry.Length -gt ($maxPayloadBytes - $total)) { throw 'Package expands beyond its size limit.' }
        $total += $entry.Length
    }
    if (!$entries.ContainsKey($manifestName)) { throw 'Package is missing required members.' }
    $manifest = Read-PackageManifest $entries[$manifestName]
    $expected = switch -CaseSensitive ($manifest.schema) {
        $legacyPackageSchema { $legacyPayloads }
        $packageSchema { $payloads }
        $fourStatePackageSchema {
            if (!(Test-FourStateBuild $manifest.build_configuration)) {
                throw 'The four-state package roster requires the four-state build capability.'
            }
            $fourStatePayloads
        }
        default { throw 'Unsupported Windows package manifest version.' }
    }
    if ($entries.Count -ne ($expected.Count + 1) -or
        @($expected | Where-Object { !$entries.ContainsKey($_) }).Count) {
        throw 'Package is missing required members or contains members from another version.'
    }
    if ($manifest.target -cne 'windows-x64' -or
        $manifest.source_build_id -cnotmatch '^[0-9a-f]{64}$' -or
        !$manifest.compiler -or !$manifest.build_configuration -or
        $manifest.files.Count -ne $expected.Count) {
        throw 'Package manifest identity or file roster is invalid.'
    }
    $expectedChannel = Get-PackageChannel $manifest.build_configuration
    if (($manifest.Contains('channel') -or $expectedChannel -ceq 'development-preview') -and
        $manifest.channel -cne $expectedChannel) {
        throw 'Package channel does not match the build configuration.'
    }
    $manifestEntries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in $manifest.files) {
        if ($record.path -cnotin $expected -or !$manifestEntries.TryAdd($record.path, $record)) {
            throw 'Package manifest lists an unexpected or duplicate payload.'
        }
    }
    foreach ($path in $expected) {
        $record = $manifestEntries[$path]
        $entry = $entries[$path]
        if ($record.bytes -ne $entry.Length -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid manifest entry for $path."
        }
        $digest = Get-ZipMemberDigest $entry
        if ($digest -cne $record.sha256) { throw "Package digest mismatch for $path." }
    }
    return $manifest
}

if ($VerifyOnly) {
    $inputArchive = [IO.File]::OpenRead($archivePath)
    try {
        if ($inputArchive.Length -gt $maxPayloadBytes) { throw 'ZIP archive exceeds its size limit.' }
        $zip = [IO.Compression.ZipArchive]::new($inputArchive, [IO.Compression.ZipArchiveMode]::Read, $true)
        try { $manifest = Verify-Package $zip } finally { $zip.Dispose() }
        $inputArchive.Position = 0
        $digest = (Get-FileHash -Algorithm SHA256 -InputStream $inputArchive).Hash.ToLowerInvariant()
    } finally {
        $inputArchive.Dispose()
    }
    [ordered]@{
        status = 'INVENTORY_AND_HASHES_VERIFIED'
        schema = $manifest.schema
        channel = Get-PackageChannel $manifest.build_configuration
        files = $manifest.files.Count
        sha256 = $digest
        source_build_id = $manifest.source_build_id
    } | ConvertTo-Json
    return
}

$sourceBuild = if ($SourceBuildDirectory) {
    (Resolve-Path -LiteralPath $SourceBuildDirectory).ProviderPath
} else {
    Join-Path $repo 'prototype/bin'
}
$proofChecker = if ($ProofCheckerExecutable) {
    (Resolve-Path -LiteralPath $ProofCheckerExecutable).ProviderPath
} else {
    Join-Path $repo 'prototype/bin/q3aformal-proofcheck.exe'
}
$header = Get-Content -LiteralPath (Join-Path $sourceBuild 'q3a_build_info.hpp') -Raw
$build = [regex]::Match($header, 'kBuildId\[\]\s*=\s*"([0-9a-f]{64})"').Groups[1].Value
$compiler = [regex]::Match($header, 'kCompiler\[\]\s*=\s*"([^"]+)"').Groups[1].Value
$configuration = [regex]::Match($header, 'kBuildConfiguration\[\]\s*=\s*"([^"]+)"').Groups[1].Value
$channel = Get-PackageChannel $configuration
if ([bool]$DevelopmentPreview -ne ($channel -ceq 'development-preview')) {
    throw 'Development builds require -DevelopmentPreview and standard builds require the internal-candidate channel.'
}

$parent = Split-Path -Parent $archivePath
if (!(Test-Path -LiteralPath $parent -PathType Container) -or (Test-Path -LiteralPath $archivePath)) {
    throw 'The archive destination requires an existing directory and an unused filename.'
}
$includeFourState = Test-FourStateBuild $configuration
$selectedSchema = if ($includeFourState) { $fourStatePackageSchema } else { $packageSchema }
$selectedPayloads = if ($includeFourState) { $fourStatePayloads } else { $payloads }
$sortedPayloads = [string[]]$selectedPayloads.Clone()
[Array]::Sort($sortedPayloads, [StringComparer]::Ordinal)
$rootPath = Join-Path $parent ('.q3a-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $rootPath | Out-Null
try {
    $staged = Join-Path $rootPath 'payload'
    foreach ($path in $selectedPayloads) {
        $origin = if ($path.StartsWith('licenses/', [StringComparison]::Ordinal)) {
            Join-Path $CompilerLicenseDirectory $path.Substring('licenses/'.Length)
        } elseif ($path -ceq 'README.md') {
            $readme = if ($DevelopmentPreview) { 'docs/windows-development-preview.md' } else { 'docs/windows-package.md' }
            Join-Path $repo $readme
        } elseif ($path -ceq 'prototype/bin/q3aformal-sourcecheck.exe') {
            Join-Path $sourceBuild 'q3aformal-sourcecheck.exe'
        } elseif ($path -ceq 'prototype/bin/q3aformal-proofcheck.exe') {
            $proofChecker
        } else {
            Join-Path $repo $path
        }
        $destination = Join-Path $staged $path
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $origin -Destination $destination
    }
    $files = foreach ($path in $sortedPayloads) {
        $file = Get-Item -LiteralPath (Join-Path $staged $path)
        [ordered]@{
            path = $path
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [ordered]@{
        schema = $selectedSchema
        channel = $channel
        target = 'windows-x64'
        source_build_id = $build
        compiler = $compiler
        build_configuration = $configuration
        files = @($files)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $staged $manifestName) -Encoding utf8NoBOM

    $temporaryArchive = Join-Path $rootPath 'candidate.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($staged, $temporaryArchive)
    $extracted = Join-Path $rootPath 'extracted candidate'
    $zip = [IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try { $manifest = Verify-Package $zip } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($temporaryArchive, $extracted)
    $packagedExe = Join-Path $extracted 'prototype/bin/q3aformal-sourcecheck.exe'
    $runtimeIdentity = & $packagedExe --version | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $runtimeIdentity.build_id -cne $manifest.source_build_id -or
        $runtimeIdentity.build_configuration -cne $manifest.build_configuration) {
        throw 'The extracted executable identity does not match the package manifest.'
    }
    $auditScript = Join-Path $repo 'prototype/benchmark/audit_windows_runtime.ps1'
    $extractedPrototype = Join-Path $extracted 'prototype'
    $audit = & $auditScript -Objdump $Objdump -PrototypeDirectory $extractedPrototype -PackageProfile -BatchProfile -CurrentProductProfile |
        ConvertFrom-Json
    if ($audit.source_build_id -cne $manifest.source_build_id) {
        throw 'The running executable build did not match the packaged build record.'
    }
    $batchPlan = $manifest.files | Where-Object path -CEQ 'prototype/batch-pipeline.q3b'
    if ($audit.batch_plan_sha256 -cne $batchPlan.sha256 -or $audit.batch_evidence -cne 'REVALIDATED') {
        throw 'The extracted batch did not revalidate against the packaged plan.'
    }
    foreach ($exe in $audit.executables) {
        $entry = $manifest.files | Where-Object path -CEQ "prototype/bin/$($exe.name)"
        if ($entry.sha256 -cne $exe.sha256) { throw "Extracted runtime audit mismatch for $($exe.name)." }
    }
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryArchive).Hash.ToLowerInvariant()
    [IO.File]::Move($temporaryArchive, $archivePath)
    [ordered]@{
        status = if ($DevelopmentPreview) { 'DEVELOPMENT_PREVIEW_VERIFIED' } else { 'INTERNAL_CANDIDATE_VERIFIED' }
        schema = $manifest.schema
        channel = $channel
        files = $manifest.files.Count
        sha256 = $digest
        source_build_id = $manifest.source_build_id
        extracted_runtime_audit = $audit
    } | ConvertTo-Json -Depth 8
} finally {
    $resolved = (Resolve-Path -LiteralPath $rootPath).ProviderPath
    if ($resolved -eq $rootPath -and (Split-Path -Leaf $rootPath) -like '.q3a-package-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
