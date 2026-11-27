
#requires -Version 7.0
param([string]$ExecutablePath, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (!$ExecutablePath) {
    $ExecutablePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe'
}
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$out = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$header = 'module test(input logic clk);'
$declaration = @('sequence probe;', "1'b1;", 'endsequence')
$manifest = Join-Path $out 'project.q3a'
$moduleFile = Join-Path $out 'design.sv'
$propertyFile = Join-Path $out 'checks.sv'
$projectBase = @('Q3AFORMAL_PROJECT 2', 'top test', 'source systemverilog "design.sv"')
$cases = @(
    @{id='module'; file='design.sv'; line=2; source=@($header) + $declaration + 'endmodule'},
    @{id='generate'; file='design.sv'; line=3; source=@($header, 'generate if (1) begin : g') + $declaration + @('end endgenerate', 'endmodule')},
    @{id='property-source'; file='checks.sv'; line=1; source=$declaration}
)
$checks = foreach ($case in $cases) {
    $project = $projectBase
    if ($case.file -ceq 'checks.sv') {
        @($header, 'endmodule') | Set-Content -LiteralPath $moduleFile -Encoding utf8
        $case.source | Set-Content -LiteralPath $propertyFile -Encoding utf8
        $project += 'property_source systemverilog "checks.sv"'
    } else {
        $case.source | Set-Content -LiteralPath $moduleFile -Encoding utf8
    }
    $project | Set-Content -LiteralPath $manifest -Encoding utf8
    foreach ($engine in 'bmc', 'induction', 'pdr') {
        $caseName = "$($case.id)-$engine"
        $bundle = Join-Path $out "$caseName-bundle"
        $prefix = Join-Path $out "$caseName-proof"
        $log = Join-Path $out "$caseName.stderr.txt"
        $opts = switch ($engine) {
            bmc { @('--frames', '1') }
            induction { @('--k', '1', '--output-prefix', $prefix) }
            pdr { @('--max-depth', '4', '--evidence-dir', $prefix) }
        }
        $output = @(& $exe prove $manifest --engine $engine --property p_check @opts --bundle-dir $bundle 2> $log)
        $exit = $LASTEXITCODE
        $output | Set-Content -LiteralPath (Join-Path $out "$caseName.json") -Encoding utf8
        if ($output.Count -ne 1) { throw "Expected one result for $caseName. $output" }
        $result = $output[0] | ConvertFrom-Json
        if ($exit -ne 2 -or $result.status -cne 'UNSUPPORTED' -or $result.exit_code -ne 2 -or
            $result.diagnostics.Count -ne 1) { throw "Unexpected result for $caseName. $output" }
        $diagnostic = $result.diagnostics[0]
        if ($diagnostic.code -cne 'Q3A_PARSE_ERROR' -or $diagnostic.location.file -cne $case.file -or
            $diagnostic.location.line -ne $case.line -or $diagnostic.location.column -ne 1 -or
            $diagnostic.message -cnotmatch 'named sequence declarations' -or
            (Test-Path -LiteralPath $bundle) -or @(Get-ChildItem -LiteralPath $out -Filter "$caseName-proof*").Count) {
            throw "Unexpected rejection at $caseName. $output"
        }
        [ordered]@{scope=$case.id; engine=$engine; verdict=$result.status; location=$diagnostic.location}
    }
}
$projectBase | Set-Content -LiteralPath $manifest -Encoding utf8
@($header, "property p_named; @(posedge clk) 1'b1; endproperty",
    'p_check: assert property (p_named);', 'endmodule') | Set-Content -LiteralPath $moduleFile -Encoding utf8
$log = Join-Path $out 'named-property.stderr.txt'
$positive = @(& $exe prove $manifest --engine bmc --property p_check --frames 1 2> $log)
$exit = $LASTEXITCODE
$positive | Set-Content -LiteralPath (Join-Path $out 'named-property.json') -Encoding utf8
if ($exit -ne 1 -or $positive.Count -ne 1 -or ($positive[0] | ConvertFrom-Json).status -cne 'BOUNDED_PASS') {
    throw "The supported named property failed. $positive"
}
[ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();
    rejected=@($checks); named_property_status='BOUNDED_PASS'} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'qualification.json')
'PASS: nine source-located named-sequence rejections and one supported named property.'

