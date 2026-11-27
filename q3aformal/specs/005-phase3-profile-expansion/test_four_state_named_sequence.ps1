#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$CheckerPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'
$project = "$root/sequence.q3a"
@'
module leaf(input logic clk, req, ack);
    sequence beat;
        req ##1 ack;
    endsequence : beat
    c_hit: cover property (@(posedge clk) beat());
endmodule

module named_demo(input logic clk, req1, ack1, req2, ack2);
    leaf lane_left(.clk(clk), .req(req1), .ack(ack1));
    leaf lane_right(.clk(clk), .req(req2), .ack(ack2));
    sequence twice();
        beat[*2];
    endsequence
    sequence beat;
        req1 ##1 ack1;
    endsequence
    c_twice: cover property (@(posedge clk) twice);
    c_shift: cover property (@(posedge clk) 1'b1 ##1 beat());
    property p_reused;
        @(posedge clk) beat() |-> ack1;
    endproperty
    p_good: assert property (p_reused);
endmodule
'@ | Set-Content -LiteralPath "$root/named.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top named_demo','source systemverilog "named.sv"',$profile) |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top named_demo','source systemverilog "named.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Id, $Status, [int]$Code, [string[]]$Arguments) {
    $raw = & $exe @Arguments 2> "$root/$Id.stderr.txt"
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($actual -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Id expected $Status/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$rawModel = & $exe dev-lower-four-state $project 2> "$root/model.stderr.txt"
if ($LASTEXITCODE -ne 0) { throw "Cannot export the named sequence model. $(Get-Content "$root/model.stderr.txt" -Raw)" }
$rawModel | Set-Content -LiteralPath "$root/model.json" -Encoding utf8NoBOM -NoNewline
$modelHash = Hash "$root/model.json"
$model = $rawModel | ConvertFrom-Json
$terms = ($model.properties | Where-Object name -ceq 'c_twice').antecedent.terms
$bodyLine = 1 + [array]::IndexOf([string[]](Get-Content "$root/named.sv"), '        req1 ##1 ack1;')
if (($terms.predicate.value -join ',') -cne 'req1,ack1,req1,ack1' -or
    ($terms.delay_from_previous -join ',') -cne '0,1,1,1' -or
    @($terms.predicate.source | Where-Object {$_.file -cne 'named.sv' -or $_.line -ne $bodyLine}).Count -ne 0) {
    throw 'Expansion lost offsets or source provenance of the declared sequence.'
}

$witnesses = [ordered]@{}
foreach ($test in @(
    @{ name='c_twice'; last=3; request='req1'; acknowledge='ack1'; first=0 },
    @{ name='c_shift'; last=2; request='req1'; acknowledge='ack1'; first=1 },
    @{ name='lane_left.c_hit'; last=1; request='req1'; acknowledge='ack1'; first=0 },
    @{ name='lane_right.c_hit'; last=1; request='req2'; acknowledge='ack2'; first=0 }
)) {
    $name = $test.name
    $options = @($project,'--property',$name,'--evidence-dir',"$root/witness-$name",'--steps',[string]$test.last)
    $hit = Run "$name-hit" COVERED 0 (@('dev-prove-four-state') + $options)
    $replay = Run "$name-replay" COVERED 0 (@('dev-verify-four-state') + $options)
    if (!$replay.witness_revalidated -or $replay.model_sha256 -cne $modelHash -or
        $hit.witness_sha256 -cne $replay.witness_sha256 -or $replay.match_sample -ne $test.last -or
        $replay.trace[$test.first].($test.request) -cne '1' -or $replay.trace[$test.last].($test.acknowledge) -cne '1') {
        throw "Incorrect trace or scope for $name."
    }
    $witnesses[$name] = $replay.witness_sha256
}

$options = @($project,'--property','p_good','--evidence-dir',"$root/proof",'--steps','1')
$proof = Run proof BOUNDED_PASS 0 (@('dev-prove-four-state') + $options)
$reopened = Run proof-reopen REVALIDATED 0 (@('dev-verify-four-state') + $options)
$out = @(& $checker --check-drat "$root/proof/query.cnf" "$root/proof/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind four-state-sampled-sva)
if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
    $proof.proof_sha256 -cne $reopened.proof_sha256) {
    throw 'The named sequence certificate did not verify.'
}
$out | Set-Content -LiteralPath "$root/standalone.txt" -Encoding utf8NoBOM

& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notlike '*named sequence declarations*') {
    throw 'Baseline sequence declaration was not rejected.'
}
foreach ($test in @(
    @{ name='recursive'; declaration='sequence first; second; endsequence sequence second; first; endsequence'; ref='first'; diagnostic='recursive or excessively nested named sequence' },
    @{ name='missing'; declaration=''; ref='missing()'; diagnostic="unresolved named sequence 'missing'" },
    @{ name='duplicate'; declaration="sequence twice; 1'b1; endsequence sequence twice; 1'b0; endsequence"; ref='twice'; diagnostic='conflicting named sequence declaration' },
    @{ name='parameterized'; declaration='sequence with_arg(logic x); x; endsequence'; ref='with_arg'; diagnostic='named sequence parameters are outside' }
)) {
    $name = $test.name
    @"
module invalid(input logic clk);
  $($test.declaration)
  c_bad: cover property (@(posedge clk) $($test.ref));
endmodule
"@ | Set-Content -LiteralPath "$root/$name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2','top invalid',('source systemverilog "{0}.sv"' -f $name),$profile) |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
    $null = Run "$name-rejected" REJECTED 2 @('dev-prove-four-state',"$root/$name.q3a",
        '--property','c_bad','--evidence-dir',"$root/invalid-$name",'--steps','2')
    if ((Get-Content "$root/$name-rejected.stderr.txt" -Raw) -notlike "*$($test.diagnostic)*") {
        throw "Incorrect rejection for $name."
    }
}

[ordered]@{
    status = 'FOUR_STATE_NAMED_SEQUENCE_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    model_sha256 = $modelHash
    source_sha256 = Hash "$root/named.sv"
    proof_sha256 = $proof.proof_sha256
    witness_sha256 = $witnesses
    rejected_cases = 5
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: module-local named sequences, forward and repeated calls, per-instance scope, original source mapping, and checked evidence.'
