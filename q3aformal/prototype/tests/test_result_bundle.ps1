param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $prototypeRoot 'bin'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$tempRoot = Join-Path $outputRoot ('q3a-bundle-' + [guid]::NewGuid().ToString('N'))
$bmcBundle = Join-Path $tempRoot 'bmc-run'
$inductionBundle = Join-Path $tempRoot 'induction-run'
$inductionPrefix = Join-Path $tempRoot 'induction-query'

function Assert-Bundle($Path, $ExpectedCommand, $ExpectedStatus, $ExpectedProperty) {
    $manifestPath = Join-Path $Path 'manifest.json'
    $summaryPath = Join-Path $Path 'summary.json'
    if (-not (Test-Path -LiteralPath $manifestPath) -or
        -not (Test-Path -LiteralPath $summaryPath) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'model\model.json')) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'source-snapshot\project.q3a'))) {
        throw "Bundle is missing its manifest, summary, exact model, or project snapshot: $Path"
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    $manifest = $manifestText | ConvertFrom-Json
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 'Q3A-RUN-BUNDLE-1' -or
        $manifest.command -ne $ExpectedCommand -or
        $manifest.result.status -ne $ExpectedStatus -or
        $manifest.result.property -ne $ExpectedProperty -or
        $summary.status -ne $ExpectedStatus -or
        $manifest.model.schema_version -ne 'Q3A-TIR-0.4' -or
        $manifest.profile.source_set_sha256 -notmatch '^[0-9a-f]{64}$' -or
        $manifest.model.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $manifest.build.executable_sha256 -notmatch '^[0-9a-f]{64}$' -or
        $manifest.components.Count -lt 5 -or
        $manifest.components.source_sha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace($manifest.reset_initial_policy) -or
        $manifest.resource_limits.decisions -lt 0 -or
        $manifest.resource_limits.propagations -lt 0 -or
        -not $manifest.resource_limits.zero_means_unlimited -or
        $manifestText -match '[A-Za-z]:\\') {
        throw "Bundle metadata is incomplete or has the wrong identity/status: $Path"
    }
    $modelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Path 'model\model.json')).Hash.ToLowerInvariant()
    if ($modelHash -ne $manifest.model.sha256) {
        throw "Bundle model hash mismatch: $Path"
    }
    $executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcecheck).Hash.ToLowerInvariant()
    if ($executableHash -ne $manifest.build.executable_sha256) {
        throw "Bundle executable hash mismatch: $Path"
    }
    $projectSnapshot = Join-Path $Path 'source-snapshot\project.q3a'
    $projectHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectSnapshot).Hash.ToLowerInvariant()
    if ($projectHash -ne $manifest.project.manifest_sha256) {
        throw "Bundle project-manifest identity mismatch: $Path"
    }
    foreach ($source in $manifest.project.sources) {
        $snapshot = Join-Path $Path ($source.snapshot_path.Replace('/', '\'))
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot).Hash.ToLowerInvariant()
        if ($sourceHash -ne $source.sha256) {
            throw "Bundle RTL source identity mismatch: $($source.path)"
        }
    }
    foreach ($query in $manifest.queries) {
        $queryArtifact = Join-Path $Path ($query.cnf_path.Replace('/', '\'))
        $queryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $queryArtifact).Hash.ToLowerInvariant()
        if ($queryHash -ne $query.cnf_sha256) {
            throw "Bundle query identity mismatch: $($query.id)"
        }
    }
    foreach ($artifact in $manifest.artifacts) {
        if ([System.IO.Path]::IsPathRooted($artifact.path) -or
            $artifact.path.Split('/') -contains '..') {
            throw "Bundle artifact path is not portable: $($artifact.path)"
        }
        $artifactPath = Join-Path $Path ($artifact.path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $artifactPath)) {
            throw "Manifest artifact is missing: $($artifact.path)"
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
        if ($actualHash -ne $artifact.sha256 -or
            (Get-Item -LiteralPath $artifactPath).Length -ne $artifact.size_bytes) {
            throw "Manifest artifact hash mismatch: $($artifact.path)"
        }
    }
    $manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    $sidecarHash = (Get-Content -LiteralPath (Join-Path $Path 'manifest.sha256') -Raw).Trim()
    if ($manifestHash -ne $sidecarHash) {
        throw "Bundle manifest sidecar hash mismatch: $Path"
    }
    return $manifest
}

try {
    if (!$UseExistingBuild) {
        & $buildScript -Compiler $Compiler
    }
    if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
        throw 'Q3AFormal sourcecheck build failed.'
    }
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $vcdPath = Join-Path $tempRoot 'w.vcd'
    $htmlPath = Join-Path $tempRoot 'w.html'
    $bmc = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-state-failure.q3a') `
        --property p_q_tracks_a --frames 1 --vcd $vcdPath --html $htmlPath --bundle-dir $bmcBundle
    if ($LASTEXITCODE -ne 0 -or -not ($bmc -contains 'Q3A_BMC_STATUS BOUNDED_FAIL')) {
        throw "BMC bundle run failed:`n$($bmc -join "`n")"
    }
    $bmcManifest = Assert-Bundle $bmcBundle 'bmc' 'BOUNDED_FAIL' 'p_q_tracks_a'
    foreach ($waveform in @(
        @{ Path = 'trace/p_q_tracks_a.vcd'; Role = 'vcd_export'; Output = $vcdPath },
        @{ Path = 'trace/p_q_tracks_a.html'; Role = 'waveform_html_viewer'; Output = $htmlPath }
    )) {
        $record = @($bmcManifest.artifacts | Where-Object { $_.path -eq $waveform.Path })
        $actual = Get-Item -LiteralPath $waveform.Output
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $actual.FullName).Hash.ToLowerInvariant()
        if ($record.Count -ne 1 -or $record[0].role -ne $waveform.Role -or
            $record[0].sha256 -ne $hash -or $record[0].size_bytes -ne $actual.Length) {
            throw "Bundled waveform differs from exported bytes: $($waveform.Path)"
        }
    }
    if ($bmcManifest.queries.Count -ne 1 -or
        $bmcManifest.queries[0].algorithm -ne 'bounded-model-checking' -or
        $bmcManifest.queries[0].cnf_sha256 -notmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath (Join-Path $bmcBundle 'properties\p_q_tracks_a\trace.json'))) {
        throw "BMC bundle must preserve the exact query and replayed trace:`n$($bmc | Out-String)"
    }

    $inconsistentBundle = Join-Path $tempRoot 'inconsistent-run'
    $inconsistent = & $sourcecheck --bmc `
        (Join-Path $prototypeRoot 'bmc-conflict.q3a') `
        --property p_assert_a --frames 1 --bundle-dir $inconsistentBundle
    if ($LASTEXITCODE -ne 0 -or
        -not ($inconsistent -contains 'Q3A_BMC_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS')) {
        throw "Contradictory assumptions must produce a bundleable inconclusive model status:`n$($inconsistent -join "`n")"
    }
    $inconsistentManifest = Assert-Bundle `
        $inconsistentBundle 'bmc' 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' 'p_assert_a'
    if ($inconsistentManifest.queries.Count -ne 1 -or
        $inconsistentManifest.queries[0].kind -ne 'model-feasibility' -or
        $inconsistentManifest.queries[0].status -ne 'UNSAT' -or
        $inconsistentManifest.assumptions.Count -ne 2) {
        throw "Inconsistent assumptions must preserve their exact feasibility query:`n$($inconsistent | Out-String)"
    }

    $passBundle = Join-Path $tempRoot 'bounded-pass-run'
    $pass = & $sourcecheck --bmc `
        (Join-Path $prototypeRoot 'bmc-scalar.q3a') `
        --property p_always_true --frames 1 --bundle-dir $passBundle
    if ($LASTEXITCODE -ne 0 -or -not ($pass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
        throw "A bounded pass must produce a query bundle:`n$($pass -join "`n")"
    }
    $passManifest = Assert-Bundle $passBundle 'bmc' 'BOUNDED_PASS' 'p_always_true'
    if ($passManifest.result.vacuity -ne 'NONVACUOUS' -or
        $passManifest.result.boundary_obligations -ne 'COMPLETE' -or
        $passManifest.queries[0].status -ne 'UNSAT') {
        throw "A bounded pass must preserve query, vacuity, and boundary status:`n$($pass | Out-String)"
    }

    $induction = & $sourcecheck --prove-inductive `
        (Join-Path $prototypeRoot 'known-pass-combinational.q3a') `
        --property p_y_implies_a --output-prefix $inductionPrefix `
        --bundle-dir $inductionBundle
    if ($LASTEXITCODE -ne 0 -or -not ($induction -contains 'Q3A_INDUCTION_STATUS PROVEN')) {
        throw "Induction bundle run failed:`n$($induction -join "`n")"
    }
    $inductionManifest = Assert-Bundle $inductionBundle 'k-induction' 'PROVEN' 'p_y_implies_a'
    foreach ($bundle in @($bmcBundle, $passBundle, $inductionBundle)) {
        $reopened = @(& $sourcecheck --verify-bundle $bundle)
        if ($LASTEXITCODE -ne 0 -or $reopened -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Fresh bundle did not revalidate: $bundle"
        }
    }
    if ($inductionManifest.queries.Count -ne 2 -or
        -not (Test-Path -LiteralPath (Join-Path $inductionBundle 'properties\p_y_implies_a\base.q3adrat')) -or
        -not (Test-Path -LiteralPath (Join-Path $inductionBundle 'properties\p_y_implies_a\step.q3adrat'))) {
        throw "Induction bundle must preserve both checked proof obligations:`n$($induction | Out-String)"
    }

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $overwrite = & $sourcecheck --bmc (Join-Path $prototypeRoot 'bmc-state-failure.q3a') `
        --property p_q_tracks_a --frames 1 --bundle-dir $bmcBundle 2>&1
    $overwriteExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($overwriteExitCode -eq 0 -or
        -not (($overwrite -join "`n") -match 'bundle output already exists')) {
        throw "Bundle creation must refuse to overwrite existing evidence:`n$($overwrite -join "`n")"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $tempFull = [System.IO.Path]::GetFullPath($tempRoot)
        $outputFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\') + '\'
        if (-not $tempFull.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($tempFull) -notmatch '^q3a-bundle-[0-9a-f]{32}$') {
            throw "Refusing to clean an unexpected test path: $tempFull"
        }
        Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

'PASS: BMC fail/pass/inconsistent and k-induction bundles preserve source/model/query/evidence identities, verify every artifact hash, and reject overwrites.'
