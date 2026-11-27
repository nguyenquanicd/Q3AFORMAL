param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-witness-corpus-' + [Guid]::NewGuid().ToString('N')))).FullName
$stderr = Join-Path $root 'stderr.txt'

$hierarchy = @(
    @{ Project = 'child-module-property'; Instances = @('u_leaf') },
    @{ Project = 'nested-child-module-property'; Instances = @('u_wrapper.u_leaf') },
    @{ Project = 'generated-child-property-bit'; Instances = @(0..3 | ForEach-Object { "g_lane[$_].u_leaf" }) },
    @{ Project = 'generated-nested-child-property-bit'; Instances = @(0..3 | ForEach-Object { "g_lane[$_].u_wrapper.u_inner.u_leaf" }) }
)
$cases = @(
    foreach ($entry in $hierarchy) {
        foreach ($instance in $entry.Instances) {
            @{ Project = $entry.Project; Property = "$instance.p_not_copy"; File = 'child_module_property.sv';
               Line = 16; Text = 'assert property (p_not_copy)'; Engines = @('bmc','induction','pdr'); Cover = $false }
        }
    }
    @{ Project = 'pdr-temporal-assumptions'; Property = 'p_too_strong'; File = 'pdr_temporal_assumptions.sv';
       Line = 4; Text = 'p_too_strong: assert property'; Engines = @('bmc','pdr'); Cover = $false }
    @{ Project = 'pdr-temporal-assumptions'; Property = 'c_allowed'; File = 'pdr_temporal_assumptions.sv';
       Line = 6; Text = 'c_allowed: cover property'; Engines = @('bmc','pdr'); Cover = $true }
    @{ Project = 'pdr-pipeline'; Property = 'p_bad'; File = 'pdr_pipeline.sv';
       Line = 9; Text = 'p_bad: assert property'; Engines = @('bmc','pdr'); Cover = $false }
    @{ Project = 'dollar-label'; Property = 'p$fail'; File = 'dollar-label.sv'; SourceRoot = $root;
       Line = 2; Text = 'p$fail: assert property'; Engines = @('bmc'); Cover = $false }
)

try {
    Push-Location -LiteralPath $root
    @('Q3AFORMAL_PROJECT 2', 'top label_fixture', 'source systemverilog "dollar-label.sv"') |
        Set-Content -LiteralPath (Join-Path $root 'dollar-label.q3a')
    @('module label_fixture(input logic clk);', '    p$fail: assert property (@(posedge clk) 1''b0);', 'endmodule') |
        Set-Content -LiteralPath (Join-Path $root 'dollar-label.sv')
    $count = 0
    foreach ($case in $cases) {
        $sourceRoot = if ($case.SourceRoot) { $case.SourceRoot } else { $prototype }
        $project = Join-Path $sourceRoot ($case.Project + '.q3a')
        $file = if ($case.SourceRoot) { $case.File } else { 'corpus/source-model-vectors/' + $case.File }
        $original = Get-Content -LiteralPath (Join-Path $sourceRoot $file) -Raw
        foreach ($engine in $case.Engines) {
            $count++
            $flags = switch ($engine) {
                'bmc' { '--frames'; '4' }
                'induction' { '--output-prefix'; (Join-Path $root "proof-$count") }
                'pdr' { '--evidence-dir'; (Join-Path $root "cert-$count") }
            }
            if ($case.Cover) { $flags += @('--bundle-dir', (Join-Path $root "bundle-$count")) }
            $expected = if ($case.Cover) { 'COVERED' } elseif ($engine -ceq 'bmc') { 'BOUNDED_FAIL' } else { 'FAIL' }
            $result = & $exe prove $project --engine $engine --property $case.Property @flags 2>$stderr |
                ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $result.status -cne $expected -or
                $result.properties[0].name -cne $case.Property -or !$result.bundle_dir) {
                throw "$engine $($case.Property) expected $expected. $(Get-Content $stderr -Raw)"
            }
            $bundle = $result.bundle_dir
            $verified = @(& $exe --verify-bundle $bundle 2>$stderr)
            $required = 'Q3A_BUNDLE_MODEL_CONTEXT VERIFIED', 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED', 'Q3A_BUNDLE_STATUS REVALIDATED'
            if ($LASTEXITCODE -ne 0 -or @($required | Where-Object { $verified -cnotcontains $_ }).Count) {
                throw "$engine $($case.Property) failed witness revalidation. $verified $(Get-Content $stderr -Raw)"
            }
            $page = @(& $exe debug $bundle 2>$stderr) -join [char]10
            $payload = [regex]::Match($page, '(?s)<script id="debug-data" type="application/json">(.*?)</script>')
            if ($LASTEXITCODE -ne 0 -or !$payload.Success) {
                throw "$engine $($case.Property) could not open the debug witness. $(Get-Content $stderr -Raw)"
            }
            $view = $payload.Groups[1].Value | ConvertFrom-Json -AsHashtable
            if ($view.run.Property -cne $case.Property -or $view.assertion.file -cne $file -or
                $view.assertion.line -ne $case.Line -or $view.assertion.column -lt 1 -or
                $view.clocks -cnotcontains 'clk' -or $view.sources[$file] -cne $original -or
                (($view.sources[$file] -split '\r?\n')[$case.Line - 1] -cnotlike "*$($case.Text)*")) {
                throw "$engine $($case.Property) debug provenance differs from $($file):$($case.Line)."
            }
            "PASS $engine $($case.Project) $($case.Property) $expected $($file):$($case.Line)"
        }
    }
    "PASS: $count checked witness-to-source paths."
} finally {
    Pop-Location
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-witness-corpus-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
