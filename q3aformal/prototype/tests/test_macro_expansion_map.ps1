
#requires -Version 7.0
param([string]$Executable,
      [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (!$Executable) {
    $Executable = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe'
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
$help = @(& $exe --help)
if ($LASTEXITCODE -ne 0 -or ($help -join [char]10) -notmatch '(?m)^  --preprocess-project PROJECT$') {
    throw 'Product help omits the preprocessing diagnostic'
}
$out = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$tick = [char]96
function Write-Input([string]$Name,[string[]]$Lines) {
    $path = Join-Path $out $Name
    $Lines | Set-Content -LiteralPath $path -Encoding utf8
}
function Run-Preprocess([string]$Name,[int]$ExpectedExit) {
    $err = Join-Path $out "$Name.stderr.txt"
    $lines = @(& $exe --preprocess-project (Join-Path $out "$Name.q3a") 2> $err)
    if ($LASTEXITCODE -ne $ExpectedExit -or ($ExpectedExit -eq 0 -and $lines.Count -ne 1) -or
        ($ExpectedExit -ne 0 -and $lines.Count -ne 0)) {
        throw "$Name failed. $lines $(Get-Content -LiteralPath $err -Raw)"
    }
    if ($ExpectedExit -eq 0) {
        $lines | Set-Content -LiteralPath (Join-Path $out "$Name.json") -Encoding utf8
        return $lines[0] | ConvertFrom-Json
    }
}
Write-Input 'defs.sv' @("$($tick)define ONE 1'b1", "$($tick)define CHAIN $($tick)ONE", "$($tick)define EMPTY")
Write-Input 'defs.svh' @("$($tick)define HEADER_ONE 1'b1",
    "module header_leaf(output logic q); assign q = $($tick)HEADER_ONE; endmodule")
Write-Input 'top.sv' @("$($tick)include $($tick)HDR", 'module top(input logic clk, output logic q);',
    "assign q = $($tick)CHAIN $($tick)EMPTY;", 'p_value: assert property (@(posedge clk) q);', 'endmodule')
Write-Input 'no-include.sv' @('module top(input logic clk, output logic q);',
    "assign q = $($tick)CHAIN;", 'endmodule')
Write-Input 'broken.sv' @("$($tick)UNKNOWN")
Write-Input 'trace.q3a' @('Q3AFORMAL_PROJECT 2','top top','define HDR "defs.svh"',
    'source systemverilog "defs.sv"','source systemverilog "top.sv"')
Write-Input 'no-include.q3a' @('Q3AFORMAL_PROJECT 2','top top',
    'source systemverilog "defs.sv"','source systemverilog "no-include.sv"')
Write-Input 'legacy.q3a' @('Q3AFORMAL_PROJECT 1','top top','source "top.sv"')
Write-Input 'broken.q3a' @('Q3AFORMAL_PROJECT 2','top top','source systemverilog "broken.sv"')
$report = Run-Preprocess trace 0
if ($report.schema_version -ne 1 -or $report.units.Count -ne 2 -or
    $report.units[0].path -cne 'defs.sv' -or $report.units[0].expansions.Count -ne 0 -or
    $report.units[1].path -cne 'top.sv' -or $report.units[1].expansions.Count -ne 4) {
    throw 'Compilation unit order or expansion count changed'
}
$unit = $report.units[1]
$include,$header,$nested,$empty = $unit.expansions
if ($include.use -cne 'include_operand' -or $include.invocation.file -cne 'top.sv' -or
    $include.invocation.line -ne 1 -or $include.output_begin -ne $include.output_end -or
    $include.steps[0].name -cne 'HDR' -or $include.steps[0].definition.file -cne '<manifest macro>') {
    throw 'The include operand lost its location or referenced definition'
}
if ($header.use -cne 'source_tokens' -or $header.invocation.file -cne 'defs.svh' -or
    $header.steps[0].definition.file -cne 'defs.svh' -or $header.steps[0].definition.line -ne 1 -or
    $unit.tokens[$header.output_begin].text -cne "1'b1" -or $header.output_end -ne ($header.output_begin + 1)) {
    throw 'The header expansion lost its location or token interval'
}
if ($nested.invocation.file -cne 'top.sv' -or $nested.invocation.line -ne 3 -or
    $nested.invocation.column -le 0 -or $nested.invocation.byte_offset -le 0 -or
    ($nested.steps.name -join ',') -cne 'CHAIN,ONE' -or $nested.steps[0].definition.file -cne 'defs.sv' -or
    ($nested.steps.definition.line -join ',') -ne '2,1' -or
    $nested.output_end -ne ($nested.output_begin + 1) -or $unit.tokens[$nested.output_begin].text -cne "1'b1" -or
    $empty.output_begin -ne $nested.output_end -or $empty.output_end -ne $empty.output_begin -or
    $empty.steps[0].name -cne 'EMPTY') { throw 'Nested or empty expansion provenance is incorrect' }
$plain = Run-Preprocess 'no-include' 0
if ($plain.units[1].expansions.Count -ne 1 -or ($plain.units[1].expansions[0].steps.name -join ',') -cne 'CHAIN,ONE') {
    throw 'Macro tracing requires an include directive unexpectedly'
}
Run-Preprocess legacy 1
Run-Preprocess broken 1
if ((Get-Content (Join-Path $out 'legacy.stderr.txt') -Raw) -notmatch 'manifest version 2' -or
    (Get-Content (Join-Path $out 'broken.stderr.txt') -Raw) -notmatch 'broken\.sv:1:') {
    throw 'Expected a manifest version diagnostic and a source-located macro error'
}
$certificate = Join-Path $out 'pdr-certificate'
$pdr = @(& $exe prove (Join-Path $out 'trace.q3a') --engine pdr --property p_value --evidence-dir $certificate)
if ($LASTEXITCODE -ne 0 -or $pdr.Count -ne 1) { throw "PDR failed. $pdr" }
$pdr | Set-Content (Join-Path $out 'pdr.json') -Encoding utf8
$pdrResult = $pdr[0] | ConvertFrom-Json
if ($pdrResult.status -cne 'PROVEN' -or $pdrResult.run_configuration.source_set_sha256 -cne $report.source_set_sha256) {
    throw "Diagnostic and PDR proof selected different project identities. $pdr"
}
$pdrCheck = @(& $exe verify-pdr (Join-Path $out 'trace.q3a') --property p_value --evidence-dir $certificate)
if ($LASTEXITCODE -ne 0) { throw "PDR certificate could not be reopened. $pdrCheck" }
$pdrCheck | Set-Content (Join-Path $out 'pdr.verify.txt') -Encoding utf8
$bundle = Join-Path $out 'proof-bundle'
$proof = @(& $exe prove (Join-Path $out 'trace.q3a') --engine induction --property p_value --output-prefix (Join-Path $out 'induction') --bundle-dir $bundle)
if ($LASTEXITCODE -ne 0 -or $proof.Count -ne 1) { throw "Induction failed. $proof" }
$proof | Set-Content (Join-Path $out 'proof.json') -Encoding utf8
$result = $proof[0] | ConvertFrom-Json
if ($result.status -cne 'PROVEN' -or $result.run_configuration.source_set_sha256 -cne $report.source_set_sha256) {
    throw "Diagnostic and proof selected different project identities. $proof"
}
$verified = @(& $exe --verify-bundle $bundle --require-source-model)
if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
    $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') { throw "Proof bundle revalidation failed. $verified" }
$verified | Set-Content (Join-Path $out 'proof.verify.txt') -Encoding utf8
[ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();
    source_set_sha256=$report.source_set_sha256; trace_entries=4; no_include_trace=$true;
    legacy_diagnostic=$true; invalid_macro_diagnostic=$true; pdr_status=$pdrResult.status; pdr_certificate_verified=$true; source_bundle_verified=$true} |
    ConvertTo-Json | Set-Content (Join-Path $out 'qualification.json') -Encoding utf8
'PASS: macro provenance and source-backed proof share the same ordered project identity.'
