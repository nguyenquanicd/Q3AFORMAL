#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$vcd = Join-Path $root 'external.vcd'
$html = Join-Path $root 'external-waveform.html'
$stderr = Join-Path $root 'viewer.stderr.txt'
@'
$timescale 10ps $end
$scope module dut $end
$var wire 4 A data [3:0] $end
$var event 1 E pulse $end
$var wire 1 B clock_bit $end
$scope module child $end
$var reg 4 A alias [0:3] $end
$var wire 1 C </script><script>unexpected()</script> $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
bX1 A
0B
0C
#5
1E
bX1 A
#15
bZ A
#9007199254740993
1B
'@ | Set-Content -LiteralPath $vcd -Encoding ascii
$out = @(& $exe trace view-vcd $vcd 2> $stderr)
if ($LASTEXITCODE -ne 0) { throw "Viewer generation failed. $(Get-Content $stderr -Raw)" }
$out | Set-Content -LiteralPath $html -Encoding utf8
& node (Join-Path $PSScriptRoot 'external_vcd_view_test.cjs') $html
if ($LASTEXITCODE -ne 0) { throw 'External VCD viewer regression failed.' }
$null = & $exe trace view-vcd $vcd --q3a-roundtrip 2> $stderr
if ($LASTEXITCODE -ne 2 -or (Get-Content $stderr -Raw) -notmatch 'invalid VCD viewer options') {
    throw 'Viewer must reject unsupported options.'
}
$malformed = Join-Path $root 'malformed.vcd'
(Get-Content -LiteralPath $vcd -Raw).Replace('bZ A','bZ UNKNOWN') |
    Set-Content -LiteralPath $malformed -Encoding ascii
$null = & $exe trace view-vcd $malformed 2> $stderr
if ($LASTEXITCODE -ne 2 -or (Get-Content $stderr -Raw) -notmatch 'unknown signal identifier') {
    throw 'Malformed VCD must retain a source diagnostic.'
}
[ordered]@{
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    input_sha256 = (Get-FileHash -LiteralPath $vcd).Hash.ToLowerInvariant()
    viewer_sha256 = (Get-FileHash -LiteralPath $html).Hash.ToLowerInvariant()
    method = 'Node VM with simulated DOM'
    input_errors = 2
    verdict = 'PASS'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
