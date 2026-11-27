param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-property-inventory-' + [Guid]::NewGuid()))).FullName
$stderr = Join-Path $root 'stderr.txt'

function Read-Inventory([string]$Project) {
    $first = @(& $exe properties $Project 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $first.Count -ne 1) {
        throw "Failed to inspect properties. $(Get-Content $stderr -Raw)"
    }
    $second = @(& $exe properties $Project 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $second.Count -ne 1 -or $first[0] -cne $second[0]) {
        throw 'Property inventory is not deterministic.'
    }
    $first[0] | ConvertFrom-Json
}

try {
    $project = Join-Path $prototype 'pdr-temporal-assumptions.q3a'
    $inventory = Read-Inventory $project
    if ($inventory.schema_version -ne 1 -or $inventory.source_set_sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $inventory.properties.Count -ne 5) {
        throw 'Incorrect property inventory identity or count.'
    }
    $assume = $inventory.properties | Where-Object name -CEQ env_next
    $target = $inventory.properties | Where-Object name -CEQ p_too_strong
    $cover = $inventory.properties | Where-Object name -CEQ c_allowed
    if ($assume.kind -cne 'assume' -or ($assume.signals.model -join ',') -cne 'a,b,clk' -or
        $cover.kind -cne 'cover' -or ($cover.signals.rtl -join ',') -cne 'a,b,clk' -or
        $target.kind -cne 'assert' -or $target.clock -cne 'clk' -or $target.edge -cne 'posedge' -or
        $target.source.file -cne 'corpus/source-model-vectors/pdr_temporal_assumptions.sv' -or $target.source.line -ne 4 -or
        ($target.signals.rtl -join ',') -cne 'a,b,clk' -or $target.signals.model -ccontains 'a' -or
        @($target.signals.model -cmatch '^__q3a_history_data_').Count -ne 1 -or
        @($target.signals.model -cmatch '^__q3a_history_valid_').Count -ne 1) {
        throw "Invalid assertion, assumption, cover, sampling or history mapping: $($target | ConvertTo-Json -Depth 8)"
    }
    $nested = (Read-Inventory (Join-Path $prototype 'lower-sva-nested-past.q3a')).properties[0]
    $pipeline = (Read-Inventory (Join-Path $prototype 'pdr-pipeline.q3a')).properties | Where-Object name -CEQ p_bad
    if (($nested.signals.rtl -join ',') -cne 'a,b,clk' -or
        ($pipeline.signals.rtl -join ',') -cne 'a,clk,q2') {
        throw 'Nested history did not resolve to its RTL inputs or the inventory expanded ordinary design drivers.'
    }
    'PASS: deterministic assertion/assumption/cover inventory, nested history and direct signal boundaries.'

    $bundle = Join-Path $root 'witness'
    $result = & $exe prove $project --engine bmc --property p_too_strong --frames 4 --bundle-dir $bundle 2>$stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'BOUNDED_FAIL') {
        throw "Could not generate property inventory bundle. $(Get-Content $stderr -Raw)"
    }
    $manifestPath = Join-Path $bundle 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $entry = $manifest.artifacts | Where-Object role -CEQ property_result
    $propertyPath = Join-Path $bundle $entry.path
    $report = Get-Content -LiteralPath $propertyPath -Raw
    $saved = $report | ConvertFrom-Json
    $verified = @(& $exe --verify-bundle $bundle 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_PROPERTY_SIGNALS VERIFIED' -or
        $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $saved.schema_version -cne 'Q3A-PROPERTY-RESULT-2' -or
        ($saved.signals.rtl -join ',') -cne ($target.signals.rtl -join ',') -or
        ($saved.signals.model -join ',') -cne ($target.signals.model -join ',')) {
        throw "Property inventory was not verified in the result bundle. $verified $(Get-Content $stderr -Raw)"
    }
    foreach ($key in 'rtl', 'model') {
        $modified = $report | ConvertFrom-Json
        $modified.signals.$key = @('clk')
        $modified | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $propertyPath
        $entry.size_bytes = (Get-Item -LiteralPath $propertyPath).Length
        $entry.sha256 = (Get-FileHash -LiteralPath $propertyPath).Hash.ToLowerInvariant()
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath
        (Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() |
            Set-Content -LiteralPath (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
        $output = @(& $exe --verify-bundle $bundle 2>$stderr)
        if ($LASTEXITCODE -ne 1 -or $output -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            (Get-Content -LiteralPath $stderr -Raw) -cnotmatch 'property signal inventory does not match') {
            throw "Verifier accepted or misclassified a rehashed $key inventory mismatch. $output"
        }
    }
    'PASS: saved signal inventory agrees with the CLI, and both rehashed mismatch cases were rejected.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-property-inventory-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
