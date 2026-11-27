#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CheckerPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = "$root/sequence.q3a"
$source = "$root/sequence.sv"
Set-Content -LiteralPath $project -Encoding utf8NoBOM -Value @(
    'Q3AFORMAL_PROJECT 2','top sequence_demo','source systemverilog "sequence.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT'
)
Set-Content -LiteralPath $source -Encoding utf8NoBOM -Value @"
module sequence_demo(input logic clk, req, data);
    logic q, r, age, armed;
    always_ff @(posedge clk) begin
        q <= req;
        r <= q;
        armed <= 1'b1;
        age <= armed === 1'bx;
    end
    p_direct: assert property (@(posedge clk) 1'b1 ##2 1'b1);
    p_pipeline: assert property (@(posedge clk) req |=> q ##1 r);
    p_range: assert property (@(posedge clk) req |-> 1'b1 ##[1:2] q);
    p_repeat_range: assert property (@(posedge clk) 1'b1[*1:3]);
    p_unknown: assert property (@(posedge clk) req[*2] ##0 (data === 1'bx) |-> data);
    p_all_matches: assert property (@(posedge clk) (armed === 1'bx) ##[1:2] 1'b1 |-> age);
    p_delayed_fail: assert property (@(posedge clk) req |=> 1'b1 ##2 1'b0);
endmodule
"@
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, [string[]]$ArgsList) {
    $raw = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $exit = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($result.status -cne $Status -or $exit -ne $Code -or $result.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $result
}
$proof = @('dev-prove-four-state',$project,'--property')
$verify = @('dev-verify-four-state',$project,'--property')
$hashes = [ordered]@{}
foreach ($name in 'p_direct','p_pipeline','p_range','p_repeat_range') {
    $folder = "$root/proof-$name"
    $claim = @($name,'--evidence-dir',$folder,'--steps','4')
    $a = Run "proved-$name" BOUNDED_PASS 0 ($proof + $claim)
    $b = Run "reopened-$name" REVALIDATED 0 ($verify + $claim)
    if ($a.proof_sha256 -cne $b.proof_sha256 -or $a.proof_sha256 -cne (Hash "$folder/proof.q3adrat") -or
        $a.query_sha256 -cne (Hash "$folder/query.cnf")) { throw "Wrong archive identity for $name." }
    $out = @(& $checker --check-drat "$folder/query.cnf" "$folder/proof.q3adrat" --model-sha256 $a.proof_model_sha256 --query-kind four-state-sampled-sva)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Standalone check failed for $name." }
    $out | Set-Content -LiteralPath "$root/checker-$name.txt" -Encoding utf8NoBOM
    $hashes[$name] = $a.proof_sha256
}
$unknown = Run unknown COUNTEREXAMPLE 0 ($proof + @('p_unknown','--evidence-dir',"$root/unused-unknown",'--steps','1'))
if (!$unknown.source_replayed -or $unknown.attempt_sample -ne 0 -or $unknown.antecedent_end_sample -ne 1 -or
    $unknown.failure_sample -ne 1 -or $unknown.trace[0].req -cne '1' -or $unknown.trace[1].req -cne '1' -or
    $unknown.signals.data -cne 'x') { throw 'Repeated antecedent did not replay the exact X failure.' }
$all = Run all-matches COUNTEREXAMPLE 0 ($proof + @('p_all_matches','--evidence-dir',"$root/unused-all",'--steps','2'))
if (!$all.source_replayed -or $all.attempt_sample -ne 0 -or $all.antecedent_end_sample -ne 2 -or
    $all.failure_sample -ne 2 -or $all.trace[1].age -cne '1' -or $all.trace[2].age -cne '0') {
    throw 'A shorter successful antecedent match masked a longer failed one.'
}
$delayed = Run delayed COUNTEREXAMPLE 0 ($proof + @('p_delayed_fail','--evidence-dir',"$root/unused-delayed",'--steps','3'))
if (!$delayed.source_replayed -or $delayed.attempt_sample -ne 0 -or $delayed.antecedent_end_sample -ne 0 -or
    $delayed.failure_sample -ne 3 -or $delayed.trace.Count -ne 4 -or $delayed.trace[0].req -cne '1') {
    throw 'Incorrect nonoverlapped delayed failure location.'
}
$null = Run incomplete-delay REJECTED 2 ($proof + @('p_delayed_fail','--evidence-dir',"$root/unused-tail",'--steps','2'))
$null = Run incomplete-direct REJECTED 2 ($proof + @('p_direct','--evidence-dir',"$root/unused-direct",'--steps','1'))
$null = Run wrong-bound REJECTED 2 ($verify + @('p_pipeline','--evidence-dir',"$root/proof-p_pipeline",'--steps','3'))
[ordered]@{
    status = 'FOUR_STATE_FINITE_SVA_SEQUENCE_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $hashes
    replayed_counterexamples = 3
    rejected_cases = 3
    source_sha256 = Hash $source
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: four finite sequence certificates, three replayed failures, three rejected bounds or artifacts.'
