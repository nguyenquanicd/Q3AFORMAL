param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$scratch = New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-manifest-' + [Guid]::NewGuid()))
$root = $scratch.FullName
$v1 = Join-Path $root 'v1.q3a'
$v2 = Join-Path $root 'v2.q3a'
$stderr = Join-Path $root 'stderr.txt'
$bundle = Join-Path $root 'bundle'
$tail = @(
    'top counter4_fail',
    'property_source systemverilog "counter fixture.sv"',
    'option profile Q3A-P0-R0.9.1',
    'option engine bmc',
    'option property p_wraps_to_zero',
    'option depth 1'
)

function Expect-Status($Code, $Status, $Arguments) {
    $output = & $exe prove @Arguments 2> $stderr
    $actual = $LASTEXITCODE
    $parsed = $output | ConvertFrom-Json
    if ($actual -ne $Code -or $parsed.exit_code -ne $Code -or $parsed.status -cne $Status) {
        throw "Expected $Code / $Status. Got $actual / $output. $(Get-Content $stderr -Raw)"
    }
}

try {
    $fixture = Join-Path $prototype 'corpus/source-model-vectors/counter4_fail.sv'
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $root 'counter fixture.sv')
    @('Q3AFORMAL_PROJECT 1', 'top counter4_fail', 'source "counter fixture.sv"') |
        Set-Content -LiteralPath $v1
    (@('Q3AFORMAL_PROJECT 2') + $tail) | Set-Content -LiteralPath $v2
    $model1 = & $exe --lower-project $v1
    if ($LASTEXITCODE -ne 0) { throw 'Legacy manifest could not be lowered.' }
    $model2 = & $exe --lower-project $v2
    if ($LASTEXITCODE -ne 0 -or ($model1 -join [char]10) -cne ($model2 -join [char]10)) {
        throw 'Equivalent manifests did not yield identical lowered output.'
    }
    Expect-Status 0 'BOUNDED_FAIL' @($v2)
    Expect-Status 1 'BOUNDED_PASS' @($v2, '--engine', 'bmc', '--property',
        'p_wraps_to_zero', '--frames', '0')
    Expect-Status 0 'BOUNDED_FAIL' @($v2, '--engine', 'bmc', '--property',
        'p_wraps_to_zero', '--frames', '1', '--bundle-dir', $bundle)
    $manifest = Get-Content (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.project.manifest_schema -cne 'Q3AFORMAL_PROJECT_2') {
        throw 'Product bundle did not record the source manifest schema.'
    }
    $reopened = & $exe --verify-bundle $bundle
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'Product manifest bundle could not be revalidated.'
    }
    foreach ($case in @(
        @{ Lines = @('Q3AFORMAL_PROJECT 3') + $tail; Error = 'first non-comment line' },
        @{ Lines = @('Q3AFORMAL_PROJECT 1') + $tail; Error = 'unsupported manifest directive: property_source' },
        @{ Lines = @('Q3AFORMAL_PROJECT 2') + $tail + 'option depth 2'; Error = 'duplicate option: depth' },
        @{ Lines = @('Q3AFORMAL_PROJECT 2') + $tail + 'option seed 9'; Error = 'unsupported option or value: seed' },
        @{ Lines = @('Q3AFORMAL_PROJECT 2') + $tail + 'source vhdl "file.vhd"'; Error = 'source language must be systemverilog' },
        @{ Lines = @('Q3AFORMAL_PROJECT 2') + $tail + 'source systemverilog file.sv'; Error = 'expected a quoted source path' },
        @{ Lines = @('Q3AFORMAL_PROJECT 2') + $tail + 'source systemverilog "../outside.sv"'; Error = "source path may not contain '..'" }
    )) {
        $case.Lines | Set-Content -LiteralPath $v2
        Expect-Status 2 'SETUP_ERROR' @($v2)
        if ((Get-Content -LiteralPath $stderr -Raw) -notmatch [regex]::Escape($case.Error)) {
            throw "Expected manifest diagnostic '$($case.Error)'."
        }
    }
    @'
module pdr_parameter #(parameter W = 0) (input logic clk);
    p_value: assert property (@(posedge clk) W == 1);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'parameter.sv')
    $parameterManifest = @(
        'Q3AFORMAL_PROJECT 2',
        'top pdr_parameter',
        'source systemverilog "parameter.sv"',
        'option engine bmc',
        'option property p_value',
        'option depth 0'
    )
    $parameterManifest | Set-Content -LiteralPath $v2
    Expect-Status 0 'BOUNDED_FAIL' @($v2)
    ($parameterManifest + 'parameter W 1') | Set-Content -LiteralPath $v2
    Expect-Status 1 'BOUNDED_PASS' @($v2)
    Expect-Status 0 'BOUNDED_FAIL' @($v2, '--parameter', 'W', '0')
    Expect-Status 2 'SETUP_ERROR' @($v2, '--parameter', 'W', '0', '--parameter', 'W', '1')
    ($parameterManifest + 'parameter W 0') | Set-Content -LiteralPath $v2
    $parameterProof = Join-Path $root 'overridden-proof'
    $recordPath = Join-Path $root 'pdr-run.json'
    $oldPrivateLimit = $env:Q3A_MEMORY_LIMIT_MIB
    $oldReserve = $env:Q3A_MEMORY_RESERVE_MIB
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '128'
        $env:Q3A_MEMORY_RESERVE_MIB = '64'
        $arguments = @('prove', $v2, '--parameter', 'W', '1', '--timeout-ms', '30000',
            '--run-record', $recordPath, '--engine', 'pdr', '--property', 'p_value',
            '--max-depth', '7', '--evidence-dir', $parameterProof)
        $output = & $exe @arguments 2> $stderr
        if ($LASTEXITCODE -ne 0) { throw "PDR run with resolved configuration failed: $output" }
        $result = $output | ConvertFrom-Json
        $configuration = $result.pdr_configuration
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $root 'parameter.sv')).Hash.ToLowerInvariant()
        if ($result.status -cne 'PROVEN' -or $result.timeout_ms -ne 30000 -or
            $null -eq $result.elapsed_ms -or $configuration.engine -cne 'pdr' -or
            $configuration.manifest_version -ne 2 -or $configuration.top_module -cne 'pdr_parameter' -or
            $configuration.property_kind -cne 'assert' -or $configuration.goal -cne 'safety' -or
            $configuration.clock -cne 'clk' -or $configuration.maximum_depth -ne 7 -or
            $configuration.maximum_search_queries -ne 10000 -or $configuration.parameters.W -cne '1' -or
            $configuration.source_set_sha256 -cne $result.source_set_sha256 -or
            $configuration.build_id -cne $result.certificate.build_id -or
            $configuration.sources.Count -ne 1 -or $configuration.sources[0].path -cne 'parameter.sv' -or
            $configuration.sources[0].sha256 -cne $sourceHash -or
            $configuration.search_private_limit_bytes -le 0 -or
            $configuration.search_private_limit_bytes -gt 128MB -or
            $configuration.search_physical_reserve_bytes -ne 64MB -or
            ($result.run_configuration | ConvertTo-Json -Depth 8 -Compress) -cne
                ($configuration | ConvertTo-Json -Depth 8 -Compress) -or
            (Get-Content -LiteralPath $recordPath -Raw).TrimEnd() -cne $output) {
            throw 'Successful PDR record did not preserve the resolved run configuration.'
        }
        foreach ($case in @(
            @{ Engine='bmc'; Status='BOUNDED_PASS'; Code=1; DepthProperty='transition_count';
               Options=@('--frames','1') },
            @{ Engine='induction'; Status='PROVEN'; Code=0; DepthProperty='induction_depth';
               Options=@('--k','1','--output-prefix',(Join-Path $root 'induction-proof')) }
        )) {
            $recordPath = Join-Path $root "$($case.Engine)-run.json"
            $arguments = @('prove', $v2, '--parameter', 'W', '1', '--timeout-ms', '30000',
                '--run-record', $recordPath, '--engine', $case.Engine, '--property', 'p_value') + $case.Options
            $output = & $exe @arguments 2> $stderr
            if ($LASTEXITCODE -ne $case.Code) { throw "$($case.Engine) resolved run failed: $output" }
            $other = $output | ConvertFrom-Json
            $resolved = $other.run_configuration
            if ($other.status -cne $case.Status -or $other.properties[0].name -cne 'p_value' -or
                $null -eq $other.elapsed_ms -or $null -ne $other.pdr_configuration -or
                $resolved.engine -cne $case.Engine -or $resolved.($case.DepthProperty) -ne 1 -or
                $null -ne $resolved.maximum_search_queries -or $resolved.workers -ne 1 -or
                !$resolved.reset_initial_policy -or
                $resolved.search_private_limit_bytes -le 0 -or $resolved.search_private_limit_bytes -gt 128MB -or
                $resolved.search_physical_reserve_bytes -ne 64MB -or
                (Get-Content -LiteralPath $recordPath -Raw).TrimEnd() -cne $output) {
                throw "$($case.Engine) result and persisted record lost their effective run controls."
            }
            foreach ($field in 'build_id','source_set_sha256','manifest_version','top_module',
                'semantic_profile','property_kind','goal','clock','parameters','macros',
                'include_dirs','sources','headers','assumptions','reset_initial_policy') {
                if ((ConvertTo-Json -InputObject $resolved.$field -Depth 8 -Compress) -cne
                    (ConvertTo-Json -InputObject $configuration.$field -Depth 8 -Compress)) {
                    throw "$($case.Engine) disagrees with PDR on common input field $field."
                }
            }
        }
    } finally {
        $env:Q3A_MEMORY_LIMIT_MIB = $oldPrivateLimit
        $env:Q3A_MEMORY_RESERVE_MIB = $oldReserve
    }
    $null = & $exe verify-pdr $v2 --property p_value --evidence-dir $parameterProof 2> $stderr
    if ($LASTEXITCODE -ne 3) { throw 'A different effective parameter must invalidate the certificate.' }
    $verified = & $exe verify-pdr $v2 --parameter W 1 --property p_value --evidence-dir $parameterProof
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw 'The same effective parameter must revalidate the certificate.'
    }
    @('Q3AFORMAL_PROJECT 1', 'top pdr_parameter', 'source "parameter.sv"') |
        Set-Content -LiteralPath $v1
    $verified = & $exe verify-pdr $v1 --parameter W 1 --property p_value --evidence-dir $parameterProof
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw 'The version 1 manifest must reopen a certificate for the same version 2 model.'
    }
    Write-Output 'PASS: both manifest versions, parameter precedence, resolved run records across three engines, cross-version PDR evidence, bundles and seven rejected manifests.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), $scratch.Name)
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
