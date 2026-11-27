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
$project = "$root/conjunction.q3a"
$manifest = @('Q3AFORMAL_PROJECT 2', 'top and_demo')
($manifest + 'source systemverilog "conjunction.sv"' + 'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
($manifest + 'source systemverilog "baseline.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
@'
module and_demo(input logic clk);
    c_base: cover property (@(posedge clk) 1'b1 ##1 1'b1 and 1'b1 ##2 1'b1);
endmodule
'@ | Set-Content -LiteralPath "$root/baseline.sv" -Encoding utf8NoBOM
@'
module and_demo(input logic clk, d);
    logic q, r;
    always_ff @(posedge clk) begin
        q <= 1'b1;
        r <= q;
    end
    c_late: cover property (@(posedge clk)
        (d === 1'b1) ##2 (d === 1'bz) and (d === 1'b1) ##1 (d === 1'bx));
    c_precedence: cover property (@(posedge clk)
        1'b1 ##3 1'b1 and 1'b1 ##1 1'b1 intersect 1'b1[*2]);
    c_concat: cover property (@(posedge clk)
        1'b1 ##1 (1'b1[*2] and 1'b1 ##2 1'b1) ##1 1'b1);
    c_repeat: cover property (@(posedge clk)
        (1'b1[*2] and 1'b1 ##0 1'b1)[*2]);
    c_unknown: cover property (@(posedge clk) 1'b1 ##2 1'b1 and 1'b1 ##1 1'bx);
    c_not_ready: cover property (@(posedge clk) 1'b1 ##2 1'b1 and 1'b1 ##1 1'b1);
    p_both: assert property (@(posedge clk)
        (1'b1 ##[1:2] 1'b1 and 1'b1[*2]) |-> (r === 1'bx));
    p_goal: assert property (@(posedge clk)
        1'b1 |-> ((1'b1 ##1 (q === 1'b1)) and (1'b1 ##2 (r === 1'b1))));
endmodule
'@ | Set-Content -LiteralPath "$root/conjunction.sv" -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Id, $Property, $Steps, $Status, [int]$Code, [switch]$Verify) {
    $command = if ($Verify) { 'dev-verify-four-state' } else { 'dev-prove-four-state' }
    $raw = & $exe $command $project --property $Property --evidence-dir "$root/$Property" --steps $Steps 2> "$root/$Id.stderr.txt"
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($actual -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Id expected $Status/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$witnesses = [ordered]@{}
foreach ($item in @(
    @{ name = 'c_late'; sample = 2 },
    @{ name = 'c_precedence'; sample = 3 },
    @{ name = 'c_concat'; sample = 4 },
    @{ name = 'c_repeat'; sample = 3 }
)) {
    $name = $item.name
    $hit = Run "$name-hit" $name $item.sample COVERED 0
    $reopened = Run "$name-replay" $name $item.sample COVERED 0 -Verify
    if (!$hit.source_replayed -or !$reopened.witness_revalidated -or $reopened.attempt_sample -ne 0 -or
        $reopened.match_sample -ne $item.sample -or $reopened.witness_sha256 -cne $hit.witness_sha256) {
        throw "Incorrect endpoint or saved witness for $name."
    }
    if ($name -ceq 'c_late' -and ($reopened.trace.d -join '') -cne '1xz') {
        throw 'The conjunction lost a predicate at an unequal endpoint.'
    }
    $witnesses[$name] = $reopened.witness_sha256
}

$proofs = [ordered]@{}
foreach ($item in @(
    @{ name = 'c_unknown'; steps = 2; cover = $true },
    @{ name = 'c_not_ready'; steps = 1; cover = $true },
    @{ name = 'p_goal'; steps = 2; cover = $false }
)) {
    $name = $item.name
    $status = if ($item.cover) { 'NOT_FOUND_WITHIN_BOUND' } else { 'BOUNDED_PASS' }
    $kind = if ($item.cover) { 'four-state-sampled-cover' } else { 'four-state-sampled-sva' }
    $proof = Run "$name-certificate" $name $item.steps $status ([int]$item.cover)
    $reopened = Run "$name-check" $name $item.steps REVALIDATED 0 -Verify
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) {
        throw "Certificate check failed for $name."
    }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}

$failure = Run later-antecedent-end p_both 2 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.antecedent_end_sample -ne 2 -or $failure.failure_sample -ne 2 -or
    $failure.trace[1].r -cne 'x' -or $failure.trace[2].r -cne '1') {
    throw 'An earlier successful conjunction masked a later failing obligation.'
}
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notlike "*temporal operator 'and'*") {
    throw 'The baseline grammar did not reject sequence conjunction.'
}

[ordered]@{
    status = 'FOUR_STATE_SEQUENCE_CONJUNCTION_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/conjunction.sv"
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    replayed_failure_sample = $failure.failure_sample
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: sequence conjunction preserves unequal endpoints, timing precedence, proof checks and source replay.'
