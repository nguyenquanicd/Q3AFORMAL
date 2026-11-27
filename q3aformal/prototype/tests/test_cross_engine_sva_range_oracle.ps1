#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = Join-Path $root 'project.q3a'
$source = Join-Path $root 'range_contract.sv'
@('Q3AFORMAL_PROJECT 2','top range_contract','source systemverilog "range_contract.sv"') |
    Set-Content -LiteralPath $project -Encoding utf8
@'
module range_contract #(parameter logic A1 = 1'b0, parameter logic A2 = 1'b0,
                        parameter logic B2 = 1'b0, parameter logic B3 = 1'b0)
    (input logic clk, output logic [2:0] phase, output logic a, b, c);
    always_ff @(posedge clk) begin
        if (phase < 3'd5) phase <= phase + 3'd1;
    end
    assign a = (phase == 3'd1 && A1) || (phase == 3'd2 && A2);
    assign b = (phase == 3'd2 && B2) || (phase == 3'd3 && B3);
    assign c = phase == 3'd4;
    p_all_matches: assert property (@(posedge clk) (phase == 3'd0) ##1 a[*1:2] |=> b ##[1:2] c);
    c_any_match: cover property (@(posedge clk) (phase == 3'd0) ##1 a[*1:2] |=> b ##[1:2] c);
endmodule
'@ | Set-Content -LiteralPath $source -Encoding utf8

function Invoke-Checked([string]$Name, [int]$Code, [string]$Program, [string[]]$Options) {
    $stderr = Join-Path $root "$Name.stderr.txt"
    $stdout = @(& $Program @Options 2> $stderr)
    $actual = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Name.stdout.txt") -Encoding utf8
    if ($actual -ne $Code) {
        throw "$Name expected exit $Code, got $actual. $stdout $(Get-Content -LiteralPath $stderr -Raw)"
    }
    return $stdout -join [char]10
}

$cases = foreach ($vector in 0..15) {
    # There is only one possible starting phase, and no transition returns to zero.
    # The short match uses b at phase 2 and c two cycles later.
    # The long match uses b at phase 3 and c one cycle later.
    $short = [bool]($vector -band 1)
    $long = $short -and [bool]($vector -band 2)
    $shortConsequence = [bool]($vector -band 4)
    $longConsequence = [bool]($vector -band 8)
    $failure = ($short -and !$shortConsequence) -or ($long -and !$longConsequence)
    $hit = ($short -and $shortConsequence) -or ($long -and $longConsequence)
    $common = @($project)
    $pins = @('A1','A2','B2','B3')
    for ($bit = 0; $bit -lt $pins.Count; ++$bit) {
        $value = ($vector -shr $bit) -band 1
        $common += @('--parameter',$pins[$bit],"1'b$value")
    }
    $verdicts = foreach ($engine in 'bmc','pdr','induction') {
        foreach ($property in 'p_all_matches','c_any_match') {
            $cover = $property -ceq 'c_any_match'
            if ($cover -and $engine -ceq 'induction') { continue }
            $witness = if ($cover) { $hit } else { $failure }
            $id = "$vector-$engine-$property"
            $bundle = Join-Path $root "$id-bundle"
            $proof = Join-Path $root "$id-proof"
            $argsForRun = @('prove') + $common + @('--engine',$engine,'--property',$property)
            if ($engine -ceq 'bmc') {
                $expected = if ($cover) {
                    if ($witness) { 'COVERED' } else { 'BOUNDED_COVER_MISS' }
                } elseif ($witness) { 'BOUNDED_FAIL' } else { 'BOUNDED_PASS' }
                $code = if ($witness) { 0 } else { 1 }
                $argsForRun += @('--frames','5')
            } elseif ($engine -ceq 'pdr') {
                $expected = if ($cover) {
                    if ($witness) { 'COVERED' } else { 'UNREACHABLE' }
                } elseif ($witness) { 'FAIL' } else { 'PROVEN' }
                $code = 0
                $argsForRun += @('--max-depth','8','--evidence-dir',$proof)
            } else {
                $expected = if ($witness) { 'FAIL' } else { 'PROVEN' }
                $code = 0
                $argsForRun += @('--k','1','--output-prefix',$proof)
            }
            if ($witness -or $engine -ceq 'induction') { $argsForRun += @('--bundle-dir',$bundle) }
            $result = Invoke-Checked $id $code $exe $argsForRun | ConvertFrom-Json
            if ($result.status -cne $expected -or $result.properties[0].name -cne $property -or
                $result.properties[0].status -cne $expected) {
                throw "$id expected $expected but returned $($result.status)."
            }
            if ($witness -or $engine -ceq 'induction') {
                $check = Invoke-Checked "$id-replay" 0 $exe @('--verify-bundle',$bundle,'--require-source-model')
                if ($check -notmatch '(?m)^Q3A_BUNDLE_STATUS REVALIDATED$') {
                    throw "$id required source-backed evidence."
                }
            }
            if ($witness -and $engine -ceq 'induction') {
                $manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
                $indexed = @($manifest.artifacts | Where-Object role -CEQ 'indexed_induction_witness')
                if ($indexed.Count -ne 1 -or $indexed[0].path -notmatch '/base\.trace\.q3atrace$') {
                    throw "$id expected one indexed reachable base witness."
                }
                $window = Invoke-Checked "$id-native" 0 $exe @('trace','window',
                    (Join-Path $bundle $indexed[0].path),'--first','0','--last','0','--signal','phase') |
                    ConvertFrom-Json
                if ($window.signals[0].changes[0][1] -cne '0x0') {
                    throw "$id expected a reachable base witness starting at phase zero."
                }
            } elseif ($witness) {
                $traceFile = @(Get-ChildItem -LiteralPath $bundle -Recurse -Filter trace.json)
                if ($traceFile.Count -ne 1) { throw "$id expected one replay witness." }
                $trace = Get-Content -LiteralPath $traceFile[0].FullName -Raw | ConvertFrom-Json
                if ($trace.frames[0].signals.phase -cne '0x0' -or
                    ($cover -and $trace.frames[$trace.candidate_frame].signals.phase -cne '0x4')) {
                    throw "$id witness does not start or cover at the expected phase."
                }
            } elseif ($engine -ceq 'pdr') {
                $check = Invoke-Checked "$id-source" 0 $exe (@('verify-pdr') + $common +
                    @('--property',$property,'--evidence-dir',$proof))
                if ($check -notmatch '(?m)^Q3A_PDR_CERTIFICATE VERIFIED$') {
                    throw "$id required a source-backed certificate."
                }
                $model = $result.certificate.model_sha256
                foreach ($kind in 'initiation','consecution','safety') {
                    $check = Invoke-Checked "$id-$kind" 0 $checker @('--check-drat',
                        (Join-Path $proof "$kind.cnf"),(Join-Path $proof "$kind.q3adrat"),
                        '--model-sha256',$model,'--query-kind',"pdr-$kind")
                    if ($check -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED$') { throw "$id rejected $kind." }
                }
            } elseif ($engine -ceq 'induction') {
                $manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
                foreach ($kind in 'base','step') {
                    $query = @($manifest.queries | Where-Object id -CEQ $kind)
                    if ($query.Count -ne 1 -or $query[0].status -cne 'UNSAT_CHECKED') {
                        throw "$id did not archive a checked $kind query."
                    }
                    $check = Invoke-Checked "$id-$kind" 0 $checker @('--check-drat',
                        (Join-Path $bundle $query[0].cnf_path),"$proof.$kind.q3adrat",
                        '--model-sha256',$manifest.model.sha256,'--query-kind',$query[0].kind)
                    if ($check -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED$') { throw "$id rejected $kind." }
                }
            }
            [ordered]@{engine=$engine;property=$property;status=$result.status;witness=$witness}
        }
    }
    [ordered]@{trace=$vector;short=$short;long=$long;assertion_failure=$failure;cover_hit=$hit;results=@($verdicts)}
}
[ordered]@{
    schema='Q3AFORMAL_CROSS_ENGINE_SVA_RANGE_ORACLE_1'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    cases=@($cases)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: all 16 patterns matched the independent assertion and cover oracle across the supported engines.'
