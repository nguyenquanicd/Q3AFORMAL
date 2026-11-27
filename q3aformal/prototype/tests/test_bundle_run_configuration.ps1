#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$prototype=Split-Path -Parent $PSScriptRoot
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$exe=Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$project=Join-Path $prototype 'benchmark/fixtures/P1_elastic_pipeline.q3a'
$cases=foreach($spec in @(
    @{id='first';depth='7';queries='1000';prefix='1'},
    @{id='second';depth='9';queries='2000';prefix='2'}
)) {
    $path=Join-Path $root "$($spec.id)-bundle"
    $record=Join-Path $root "$($spec.id).json"
    $stderr=Join-Path $root "$($spec.id).stderr.txt"
    $options=@('prove',$project,'--parameter','DROP_STALL','1','--timeout-ms','5000','--engine','pdr',
        '--property','p_hold','--max-depth',$spec.depth,'--max-queries',$spec.queries,'--feasibility-frames',$spec.prefix,
        '--bundle-dir',$path,'--evidence-dir',(Join-Path $root "$($spec.id)-proof"))
    $raw=& $exe @options 2> $stderr
    $rc=$LASTEXITCODE
    [IO.File]::WriteAllText($record,$raw)
    $result=$raw | ConvertFrom-Json
    if ($rc -ne 0 -or $result.status -cne 'FAIL') { throw "Expected replayed PDR failure: $raw" }

    $manifestPath=Join-Path $path 'manifest.json'
    $manifestRaw=[IO.File]::ReadAllText($manifestPath)
    $manifestDigestPath=Join-Path $path 'manifest.sha256'
    $manifestDigestRaw=[IO.File]::ReadAllText($manifestDigestPath)
    $manifest=$manifestRaw | ConvertFrom-Json
    $artifact=@($manifest.artifacts | Where-Object role -CEQ 'run_configuration')
    if ($artifact.Count -ne 1 -or $artifact[0].path -cne 'reports/run-configuration.json') {
        throw 'Missing the initiating configuration artifact.'
    }
    $configPath=Join-Path $path $artifact[0].path
    $configRaw=[IO.File]::ReadAllText($configPath)
    $config=$configRaw | ConvertFrom-Json
    $digest=(Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()
    if (($result.run_configuration | ConvertTo-Json -Compress -Depth 20) -cne
        ($config | ConvertTo-Json -Compress -Depth 20) -or $digest -cne $artifact[0].sha256 -or
        $config.engine -cne 'pdr' -or $config.property -cne 'p_hold' -or $config.timeout_ms -ne 5000 -or
        $config.maximum_depth -ne [int]$spec.depth -or $config.maximum_search_queries -ne [int]$spec.queries -or
        $config.minimum_feasibility_bound -ne [int]$spec.prefix -or
        $manifest.command -cne 'bmc' -or $manifest.result.bound -ne 1) {
        throw 'Initiating search settings were confused with the bounded replay.'
    }
    $check=@(& $exe --verify-bundle $path --require-source-model)
    if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $check -cnotcontains "Q3A_BUNDLE_RUN_CONFIGURATION VERIFIED sha256=$digest") {
        throw 'The saved configuration and witness did not revalidate.'
    }
    $check | Set-Content -LiteralPath (Join-Path $root "$($spec.id).verify.txt") -Encoding utf8

    $mutant=$configRaw.Replace('"property":"p_hold"','"property":"p_fake"')
    try {
        [IO.File]::WriteAllText($configPath,$mutant)
        $hash=(Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($manifestPath,$manifestRaw.Replace($digest,$hash))
        $changedManifestDigest=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        $updatedDigest=$manifestDigestRaw -creplace '^[0-9a-f]{64}', $changedManifestDigest
        [IO.File]::WriteAllText($manifestDigestPath,$updatedDigest)
        $reopened=@(& $exe --verify-bundle $path --require-source-model 2> $stderr)
        if ($LASTEXITCODE -ne 1 -or $reopened -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            (Get-Content -LiteralPath $stderr -Raw) -notmatch 'run configuration does not match') {
            throw 'A rehashed configuration for another property reopened successfully.'
        }
    } finally {
        [IO.File]::WriteAllText($configPath,$configRaw)
        [IO.File]::WriteAllText($manifestPath,$manifestRaw)
        [IO.File]::WriteAllText($manifestDigestPath,$manifestDigestRaw)
    }
    [ordered]@{id=$spec.id;configuration_sha256=$digest;configuration=$config;
        replay_query_sha256=$manifest.queries[0].cnf_sha256}
}
if ($cases[0].configuration_sha256 -ceq $cases[1].configuration_sha256 -or
    $cases[0].replay_query_sha256 -cne $cases[1].replay_query_sha256) {
    throw 'Expected distinct search configurations for the same replay query.'
}
$previous=Join-Path (Split-Path -Parent $prototype) 'evidence/release/archive-run-options-baseline-2026-11-25/first-bundle'
$check=@(& $exe --verify-bundle $previous --require-source-model)
if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
    throw 'A historical witness bundle failed to revalidate.'
}
[ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();cases=$cases;
    historical_witness_verified=$true;rehashed_property_substitutions_rejected=2} |
    ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: archived initiating options distinguish two PDR searches with the same replay query.'
