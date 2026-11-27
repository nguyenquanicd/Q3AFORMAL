param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$project = Join-Path $prototype 'pdr-activation.q3a'
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-activation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.txt'

function Invoke-Activation([string]$Property, [int]$Depth, [int]$Code, [string]$Status) {
    $proof = Join-Path $root "$Property-activation"
    $json = & $exe prove $project --engine pdr --property $Property --max-depth $Depth --evidence-dir $proof --check-activation 2> $stderr
    $actual = $LASTEXITCODE
    $result = $json | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Status ($Code) for $Property. Actual $json. $(Get-Content $stderr -Raw)"
    }
    $result.properties[0]
}

function Verify-Evidence($Property, $Directory, [switch]$Activation, [switch]$Reject) {
    $options = @('--property', $Property, '--evidence-dir', $Directory)
    if ($Activation) { $options += '--check-activation' }
    $result = @(& $exe verify-pdr $project @options 2> $stderr)
    if ($Reject) {
        if ($LASTEXITCODE -ne 3 -or (Get-Content $stderr -Raw) -notmatch 'model or property identity does not match') {
            throw "Expected an identity mismatch for $Property. $result $(Get-Content $stderr -Raw)"
        }
        return
    }
    if ($LASTEXITCODE -ne 0 -or $result -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED' -or
        ($Activation -and $result -cnotcontains 'Q3A_PDR_RESULT ACTIVATION_UNREACHABLE')) {
        throw "Could not reopen the certificate for $Property."
    }
}

try {
    $evidence = foreach ($name in 'p_unreachable', 'p_excluded') {
        $property = Invoke-Activation $name 12 0 'ACTIVATION_UNREACHABLE'
        if ($property.vacuity.status -cne 'DETECTED' -or $property.vacuity.scope -cne 'COMPLETE' -or
            $property.vacuity.activation -cne 'NOT_REACHED' -or
            $property.vacuity.PSObject.Properties.Name -ccontains 'bound') {
            throw "An unreachable activation did not carry complete scope for $name."
        }
        $path = Join-Path $root "$name-activation"
        Verify-Evidence $name $path -Activation
        Verify-Evidence $name $path -Reject
        $path
    }
    Verify-Evidence 'p_excluded' $evidence[0] -Activation -Reject
    $normal = Join-Path $root 'original-safety-proof'
    $json = & $exe prove $project --evidence-dir $normal 2> $stderr
    if ($LASTEXITCODE -ne 0 -or ($json | ConvertFrom-Json).status -cne 'PROVEN') {
        throw 'The original safety property did not prove.'
    }
    Verify-Evidence 'p_unreachable' $normal
    Verify-Evidence 'p_unreachable' $normal -Activation -Reject
    & (Join-Path $PSScriptRoot 'test_drat_independent_full_scan.ps1') -PdrEvidence $evidence

    $pending = Invoke-Activation 'p_active' 3 1 'UNKNOWN'
    if ($pending.vacuity.status -cne 'INCOMPLETE' -or $pending.vacuity.scope -cne 'BOUNDED' -or
        $pending.vacuity.bound -ne 3) {
        throw 'A bounded activation miss was treated as complete.'
    }
    foreach ($case in @(
        @{ Name = 'p_active'; Depth = 4 },
        @{ Name = 'p_guarded'; Depth = 2 },
        @{ Name = 'p_standalone'; Depth = 2 }
    )) {
        $null = Invoke-Activation $case.Name ($case.Depth - 1) 1 'UNKNOWN'
        $property = Invoke-Activation $case.Name 12 0 'ACTIVATION_REACHED'
        $log = Get-Content $stderr -Raw
        if ($property.vacuity.status -cne 'NOT_DETECTED_WITHIN_SCOPE' -or
            $property.vacuity.scope -cne 'BOUNDED' -or $property.vacuity.bound -ne $case.Depth -or
            $property.vacuity.activation -cne 'REACHED' -or $log -notmatch 'Q3A_BMC_REPLAY VALIDATED' -or
            (Test-Path -LiteralPath (Join-Path $root "$($case.Name)-activation"))) {
            throw "Activation replay or exact eligible sample failed for $($case.Name). $log"
        }
        "PASS: $($case.Name) activation replayed at depth $($case.Depth)."
    }
    $null = Invoke-Activation 'c_hit' 12 2 'SETUP_ERROR'
    'PASS: complete activation certificates, independent DRAT verification, certificate domain isolation, and bounded misses.'

    # p_local holds under the environment assumption and can still activate.
    $sourceProject = Join-Path $prototype 'pdr-temporal-assumptions.q3a'
    $bundle = Join-Path $root 'activation-waveform'
    $noCertificate = Join-Path $root 'no-activation-certificate'
    $options = @('--engine', 'pdr', '--property', 'p_local', '--check-activation',
        '--evidence-dir', $noCertificate, '--bundle-dir', $bundle, '--trace-signal', 'b')
    $json = & $exe prove $sourceProject @options 2> $stderr
    $result = $json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'ACTIVATION_REACHED' -or
        $result.properties[0].vacuity.bound -ne 1 -or (Test-Path -LiteralPath $noCertificate)) {
        throw "Could not publish the activation witness. $json $(Get-Content $stderr -Raw)"
    }
    $manifestPath = Join-Path $bundle 'manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $capture = Get-Content (Join-Path $bundle 'trace/capture.json') -Raw | ConvertFrom-Json
    if ($manifest.result.status -cne 'ACTIVATION_REACHED' -or
        $manifest.queries[0].kind -cne 'assertion-activation' -or $capture.requested -cnotcontains 'b') {
        throw 'The bundle did not preserve activation identity and requested capture.'
    }
    $verified = @(& $exe --verify-bundle $bundle 2> $stderr)
    foreach ($line in 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED', 'Q3A_BUNDLE_INDEXED_TRACE VERIFIED',
        'Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED', 'Q3A_BUNDLE_WAVEFORM_CAPTURE VERIFIED',
        'Q3A_BUNDLE_SCOPE REPLAYED_ASSERTION_ACTIVATION_FOR_SERIALIZED_TIR', 'Q3A_BUNDLE_STATUS REVALIDATED') {
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains $line) {
            throw "The activation bundle did not reopen with $line. $verified $(Get-Content $stderr -Raw)"
        }
    }
    $page = @(& $exe debug $bundle 2> $stderr) -join [char]10
    $embedded = [regex]::Match($page, '(?s)<script id="debug-data" type="application/json">(.*?)</script>')
    if ($LASTEXITCODE -ne 0 -or !$embedded.Success) { throw 'Activation waveform did not open in debug.' }
    $data = $embedded.Groups[1].Value | ConvertFrom-Json
    if ($data.run.Result -cne 'ACTIVATION_REACHED' -or $data.run.Obligation -cne 'activation' -or
        $data.run.'Activation replay bound' -cne '1' -or $data.assertion.file -notmatch 'pdr_temporal_assumptions\.sv$' -or
        $data.assertion.line -le 0) {
        throw 'The debug page did not preserve the activation result and original assertion source.'
    }
    'PASS: activation of a proved assertion published an indexed trace and source-correlated debug page.'

    $manifest.result.status = 'BOUNDED_FAIL'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash $manifestPath).Hash.ToLowerInvariant() |
        Set-Content (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
    $verified = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $verified -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content $stderr -Raw) -notmatch 'run configuration does not match') {
        throw 'The saved activation goal did not reject a relabelled failure result.'
    }
    'PASS: verifier rejects a failure result that disagrees with the saved activation goal.'

    $entry = @($manifest.artifacts | Where-Object role -CEQ 'run_configuration')
    if ($entry.Count -ne 1) { throw 'Activation bundle lost its recorded search configuration.' }
    $configPath = Join-Path $bundle $entry[0].path
    $config = [IO.File]::ReadAllText($configPath)
    if (!$config.Contains('"goal":"activation"')) { throw 'Expected the saved initiating activation goal.' }
    [IO.File]::WriteAllText($configPath, $config.Replace('"goal":"activation"','"goal":"safety"'))
    $entry[0].sha256 = (Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()
    $entry[0].size_bytes = (Get-Item -LiteralPath $configPath).Length
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash $manifestPath).Hash.ToLowerInvariant() |
        Set-Content (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
    $verified = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $verified -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content $stderr -Raw) -notmatch 'not linked to a matching replay-validated query') {
        throw 'An activation trace was misclassified as an assertion failure after refreshing the manifest hash.'
    }
    'PASS: verifier rejects a relabelled activation even with a refreshed manifest hash.'

    $manifest.queries[0].kind = 'assertion'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash $manifestPath).Hash.ToLowerInvariant() |
        Set-Content (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
    $verified = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $verified -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content $stderr -Raw) -notmatch 'bundle BMC witness replay failed') {
        throw 'The activation trace must also fail revalidation as a counterexample when both labels change.'
    }
    'PASS: original assertion replay also rejects the relabelled trace after both result and query labels agree.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-activation-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
