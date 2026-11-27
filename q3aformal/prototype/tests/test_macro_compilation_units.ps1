#requires -Version 7.0
param([string]$Executable,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
if (!$Executable) { $Executable=Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$exe=(Resolve-Path -LiteralPath $Executable).Path
$out=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$tick=[char]96
$definition="$($tick)define ENABLED 1'b1"
$rtl="module macro_top(input logic clk, output logic q); assign q = $($tick)ENABLED; p_value: assert property (@(posedge clk) q); p_wrong: assert property (@(posedge clk) !q); endmodule"
[IO.File]::WriteAllText((Join-Path $out 'design.sv'),$rtl)
[IO.File]::WriteAllText((Join-Path $out 'defs.sv'),$definition)
[IO.File]::WriteAllText((Join-Path $out 'defs.svh'),$definition)
[IO.File]::WriteAllText((Join-Path $out 'include-only.sv'),"$($tick)include ""defs.svh""")
[IO.File]::WriteAllText((Join-Path $out 'blank.sv'),'// no active declarations')
[IO.File]::WriteAllText((Join-Path $out 'broken.sv'),"$($tick)ifdef NO_SUCH_MACRO")
@('Q3AFORMAL_PROJECT 1','top macro_top','source "blank.sv"') |
    Set-Content -LiteralPath (Join-Path $out legacy-empty.q3a) -Encoding utf8
@('Q3AFORMAL_PROJECT 2','top macro_top','source systemverilog "defs.sv"') |
    Set-Content -LiteralPath (Join-Path $out no-top.q3a) -Encoding utf8
@('Q3AFORMAL_PROJECT 2','top macro_top','source systemverilog "broken.sv"','source systemverilog "design.sv"') |
    Set-Content -LiteralPath (Join-Path $out invalid-unit.q3a) -Encoding utf8

function Run-JSON([string]$Id,[int]$Exit,[string]$Status,[string[]]$Options) {
    $err=Join-Path $out "$Id.stderr.txt"
    $stdout=@(& $exe @Options 2> $err)
    $rc=$LASTEXITCODE
    $stdout | Set-Content -LiteralPath (Join-Path $out "$Id.json") -Encoding utf8
    if ($rc -ne $Exit -or $stdout.Count -ne 1) {
        throw "Unexpected $Id exit $rc. $stdout $(Get-Content -LiteralPath $err -Raw)"
    }
    $state=$stdout[0] | ConvertFrom-Json
    if ($state.status -cne $Status -or $state.exit_code -ne $Exit) { throw "Unexpected $Id status. $stdout" }
    return $state
}

$results=foreach($variant in @(@{id='ordered';first='defs.sv'},@{id='included';first='include-only.sv'})) {
    $id=$variant.id
    $project=Join-Path $out "$id.q3a"
    @('Q3AFORMAL_PROJECT 2','top macro_top',('source systemverilog "'+$variant.first+'"'),
        'source systemverilog "blank.sv"','source systemverilog "design.sv"') |
        Set-Content -LiteralPath $project -Encoding utf8
    $parsed=@(& $exe --parse-project $project)
    if ($LASTEXITCODE -ne 0 -or @($parsed -cmatch '^Q3A_SYNTAX_OK').Count -ne 3) {
        throw "Project inspection lost the empty units or design in $id. $parsed"
    }
    foreach($mode in 'bmc','induction') {
        $case="$id-$mode"
        $bundle=Join-Path $out "$case-bundle"
        if ($mode -ceq 'bmc') {
            $payload=Run-JSON $case 0 'BOUNDED_FAIL' @('prove',$project,'--engine','bmc','--property','p_wrong','--frames','0','--bundle-dir',$bundle)
        } else {
            $payload=Run-JSON $case 0 'PROVEN' @('prove',$project,'--engine','induction','--property','p_value',
                '--output-prefix',(Join-Path $out "$case-proof"),'--bundle-dir',$bundle)
        }
        $check=@(& $exe --verify-bundle $bundle --require-source-model)
        if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $check -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "$case could not regenerate the source and revalidate."
        }
        $check | Set-Content -LiteralPath (Join-Path $out "$case.verify.txt") -Encoding utf8
        $saved=Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
        if ($saved.project.sources.Count -ne 3 -or $saved.project.sources[0].path -cne $variant.first -or
            ($id -ceq 'included' -and $saved.project.headers[0].path -cne 'defs.svh')) {
            throw "$case dropped empty source units or a header from the archive."
        }
        [ordered]@{id=$case;status=$payload.status;source_units=3;source_required=$true}
    }
}
$noTop=Run-JSON no-top 2 'ELABORATION_ERROR' @('prove',(Join-Path $out no-top.q3a),'--engine','bmc','--property','p_value','--frames','0')
$legacy=Run-JSON legacy-empty 2 'SETUP_ERROR' @('prove',(Join-Path $out legacy-empty.q3a),'--engine','bmc','--property','p_value','--frames','0')
$invalid=Run-JSON invalid-unit 2 'SETUP_ERROR' @('prove',(Join-Path $out invalid-unit.q3a),'--engine','bmc','--property','p_value','--frames','0')
$direct=@(& $exe --parse (Join-Path $out 'blank.sv') 2> (Join-Path $out 'blank-direct.stderr.txt'))
if ($LASTEXITCODE -eq 0 -or $direct.Count -ne 0 -or $invalid.diagnostics[0].location.file -cne 'broken.sv' -or
    $legacy.diagnostics[0].location.file -cne 'blank.sv') { throw 'Empty-unit tolerance masked an unsupported path or directive error.' }
[ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();cases=$results;
    top_missing_rejected=($noTop.exit_code -eq 2);raw_empty_rejected=$true;v1_empty_rejected=$true;malformed_directives_rejected=$true} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out qualification.json) -Encoding utf8
'PASS: four source-backed results, ordered and include-only macro units, and four rejected boundary cases.'
