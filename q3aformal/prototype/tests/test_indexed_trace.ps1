$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-indexed-test-' + [Guid]::NewGuid()))).FullName

function Write-BundleManifest($Directory, $Manifest) {
    $path = Join-Path $Directory 'manifest.json'
    [IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath (Join-Path $Directory 'manifest.sha256')
}

try {
    $unit = Join-Path $root 'indexed-trace-test.exe'
    & g++ -std=c++17 -Wall -Wextra -Wpedantic (Join-Path $PSScriptRoot 'indexed_trace_test.cpp') (
        Join-Path $prototype 'source/bundle/indexed_trace.cpp') -o $unit
    if ($LASTEXITCODE -ne 0) { throw 'Indexed trace unit test did not compile.' }
    & $unit
    if ($LASTEXITCODE -ne 0) { throw 'Indexed trace unit test failed.' }
    $bundle = Join-Path $root 'bundle'
    $manifest = Join-Path $prototype 'bmc-state-failure.q3a'
    $result = & $exe --bmc $manifest --property p_q_tracks_a --frames 1 --bundle-dir $bundle
    if ($LASTEXITCODE -ne 0 -or $result -cnotcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Could not generate replay-validated witness.'
    }
    $indexed = Join-Path $bundle 'properties/p_q_tracks_a/trace.q3atrace'
    $output = & $exe trace window $indexed --first 1 --last 1 --signal q
    if ($LASTEXITCODE -ne 0) { throw 'Could not read selected witness window.' }
    $window = $output | ConvertFrom-Json
    if ($window.property -ne 'p_q_tracks_a' -or $window.candidate_frame -ne 1 -or
        $window.signals.Count -ne 1 -or $window.signals[0].name -ne 'q' -or
        $window.signals[0].width -ne 1 -or $window.signals[0].changes[0][0] -ne 1 -or
        $window.signals[0].changes[0][1] -ne '0x0') { throw 'Wrong signal window.' }
    $verified = & $exe --verify-bundle $bundle
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_INDEXED_TRACE VERIFIED') {
        throw 'Bundle did not verify the indexed trace.'
    }
    $stderr = Join-Path $root 'errors.txt'
    $null = & $exe trace window $indexed --first 0 --last 2 2> $stderr
    if ($LASTEXITCODE -ne 2) { throw 'An out-of-range window was accepted.' }
    $null = & $exe trace window $indexed --first 0 --last 1 --signal absent 2> $stderr
    if ($LASTEXITCODE -ne 2) { throw 'An unknown signal was accepted.' }

    $bytes = [IO.File]::ReadAllBytes($indexed)
    $original = $bytes.Clone()
    $firstBlock = [int][BitConverter]::ToUInt64($bytes, $bytes.Length - 16)
    $bytes[$firstBlock + 4] = $bytes[$firstBlock + 4] -bxor 1
    [IO.File]::WriteAllBytes($indexed, $bytes)
    $bundleManifestPath = Join-Path $bundle 'manifest.json'
    $bundleManifest = Get-Content -LiteralPath $bundleManifestPath -Raw | ConvertFrom-Json
    ($bundleManifest.artifacts | Where-Object role -CEQ 'indexed_witness_trace').sha256 =
        (Get-FileHash -LiteralPath $indexed -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-BundleManifest $bundle $bundleManifest
    $null = & $exe --verify-bundle $bundle 2> $stderr
    if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'differs from replay-validated') {
        throw 'Verifier accepted an indexed witness with altered values and recomputed hashes.'
    }

    [IO.File]::WriteAllBytes($indexed, $original)
    $bundleManifest.artifacts = @($bundleManifest.artifacts | Where-Object role -CNE 'replay_validated_trace')
    Remove-Item -LiteralPath (Join-Path $bundle 'properties/p_q_tracks_a/trace.json')
    $record = $bundleManifest.artifacts | Where-Object role -CEQ 'indexed_witness_trace'
    $record.sha256 = (Get-FileHash -LiteralPath $indexed -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-BundleManifest $bundle $bundleManifest
    $verified = & $exe --verify-bundle $bundle
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_INDEXED_TRACE VERIFIED' -or
        $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'Bundle with only indexed trace did not replay.'
    }
    $signalCount = [BitConverter]::ToUInt32($original, 24)
    $blockEnd = [int][BitConverter]::ToUInt64($original, $original.Length - 8)
    $seriesOffsets = $blockEnd - 8 * ($signalCount + 1)
    $qEnd = [int][BitConverter]::ToUInt64($original, $seriesOffsets + 8 * ($window.signals[0].id + 1))
    $valueOffset = $firstBlock + $qEnd - 8
    $original[$valueOffset] = $original[$valueOffset] -bxor 1
    [IO.File]::WriteAllBytes($indexed, $original)
    $record.sha256 = (Get-FileHash -LiteralPath $indexed -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-BundleManifest $bundle $bundleManifest
    $null = & $exe --verify-bundle $bundle 2> $stderr
    if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'witness replay failed') {
        throw 'Verifier accepted an indexed-only witness that violates the transition equations.'
    }
    'PASS: cross-block reads, exact 64-bit values, indexed-only replay, and rejection of altered witness values.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), (Split-Path $root -Leaf))
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
