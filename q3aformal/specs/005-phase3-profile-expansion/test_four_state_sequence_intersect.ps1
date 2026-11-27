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
$manifest = @('Q3AFORMAL_PROJECT 2', 'top match_demo', 'source systemverilog "intersection.sv"')
$project = "$root/intersection.q3a"
($manifest + 'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
($manifest[0..1] + 'source systemverilog "baseline.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
@'
module match_demo(input logic clk);
    c_baseline: cover property (@(posedge clk) 1'b1 ##1 1'b1 intersect 1'b1 ##1 1'b1);
endmodule
'@ | Set-Content -LiteralPath "$root/baseline.sv" -Encoding utf8NoBOM
@'
module match_demo(input logic clk, d);
    logic q, r;
    always_ff @(posedge clk) begin
        q <= 1'b1;
        r <= q;
    end
    c_equal: cover property (@(posedge clk)
        (d === 1'bz) ##[1:3] (d === 1'bx) intersect 1'b1 ##2 1'b1);
    c_misaligned: cover property (@(posedge clk) 1'b1 ##1 1'b1 intersect 1'b1 ##2 1'b1);
    c_unknown: cover property (@(posedge clk) 1'b1 ##1 1'b1 intersect 1'b1 ##1 1'bx);
    c_same_sample: cover property (@(posedge clk) (d === 1'b0) intersect (d === 1'b1));
    c_disjunction: cover property (@(posedge clk)
        1'b1 ##1 1'b1 or 1'b1 ##2 1'b1 intersect 1'b1 ##3 1'b1);
    c_concat: cover property (@(posedge clk)
        1'b1 ##1 ((1'b1 ##[1:2] 1'b1) intersect 1'b1[*2]) ##1 1'b1);
    c_repeat: cover property (@(posedge clk)
        ((1'b1 ##1 1'b1) intersect 1'b1[*2])[*2]);
    p_all: assert property (@(posedge clk)
        ((1'b1 ##[1:3] 1'b1) intersect (1'b1 ##[1:2] 1'b1)) |-> (r === 1'bx));
    p_consequent: assert property (@(posedge clk)
        1'b1 |=> ((1'b1 ##1 1'b1) intersect ((q === 1'b1) ##1 (r === 1'b1))));
endmodule
'@ | Set-Content -LiteralPath "$root/intersection.sv" -Encoding utf8NoBOM

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
    @{ name = 'c_equal'; sample = 2 },
    @{ name = 'c_disjunction'; sample = 1 },
    @{ name = 'c_concat'; sample = 3 },
    @{ name = 'c_repeat'; sample = 3 }
)) {
    $name = $item.name
    $hit = Run "$name-hit" $name $item.sample COVERED 0
    $reopened = Run "$name-replay" $name $item.sample COVERED 0 -Verify
    if (!$hit.source_replayed -or !$reopened.witness_revalidated -or
        $reopened.attempt_sample -ne 0 -or $reopened.match_sample -ne $item.sample -or
        $reopened.witness_sha256 -cne $hit.witness_sha256) {
        throw "Incorrect endpoint or saved witness for $name."
    }
    if ($name -ceq 'c_equal' -and ($reopened.trace[0].d -cne 'z' -or $reopened.trace[2].d -cne 'x')) {
        throw 'The intersection lost an operand predicate at its start or end.'
    }
    $witnesses[$name] = $reopened.witness_sha256
}

$proofs = [ordered]@{}
foreach ($item in @(
    @{ name = 'c_misaligned'; steps = 2; kind = 'four-state-sampled-cover' },
    @{ name = 'c_unknown'; steps = 1; kind = 'four-state-sampled-cover' },
    @{ name = 'c_same_sample'; steps = 0; kind = 'four-state-sampled-cover' },
    @{ name = 'p_consequent'; steps = 2; kind = 'four-state-sampled-sva' }
)) {
    $name = $item.name
    $isCover = $item.kind -ceq 'four-state-sampled-cover'
    $status = if ($isCover) { 'NOT_FOUND_WITHIN_BOUND' } else { 'BOUNDED_PASS' }
    $proof = Run "$name-certificate" $name $item.steps $status ([int]$isCover)
    $reopened = Run "$name-check" $name $item.steps REVALIDATED 0 -Verify
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $item.kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) {
        throw "Certificate check failed for $name."
    }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}

$failure = Run both-endpoints p_all 2 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.antecedent_end_sample -ne 2 -or $failure.failure_sample -ne 2 -or
    $failure.trace[1].r -cne 'x' -or $failure.trace[2].r -cne '1') {
    throw 'An earlier successful intersection masked a later failing obligation.'
}
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notlike "*temporal operator 'intersect'*") {
    throw 'The baseline grammar did not reject sequence intersection.'
}
$expanded = (@("1'b1[*1:12]") * 7) -join ' ##1 '
foreach ($test in @(
    @{ id = 'expansion-limit'; expression = $expanded; diagnostic = 'intersection exceeds the lowered SVA term limit' },
    @{ id = 'offset-limit'; expression = "1'b1 ##129 1'b1"; diagnostic = 'intersection operands must fit the finite 128-sample profile' }
)) {
    $id = $test.id
    ($manifest[0..1] + ('source systemverilog "{0}.sv"' -f $id) + 'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
        Set-Content -LiteralPath "$root/$id.q3a" -Encoding utf8NoBOM
    @"
module match_demo(input logic clk);
    c_bad: cover property (@(posedge clk) ($($test.expression)) intersect 1'b1);
endmodule
"@ | Set-Content -LiteralPath "$root/$id.sv" -Encoding utf8NoBOM
    $null = & $exe dev-prove-four-state "$root/$id.q3a" --property c_bad --evidence-dir "$root/$id-evidence" --steps 0 2> "$root/$id.stderr.txt"
    if ($LASTEXITCODE -ne 2 -or (Test-Path -LiteralPath "$root/$id-evidence") -or
        (Get-Content "$root/$id.stderr.txt" -Raw) -notlike "*$($test.diagnostic)*") {
        throw "Incorrect rejection for $id."
    }
}

[ordered]@{
    status = 'FOUR_STATE_SEQUENCE_INTERSECTION_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/intersection.sv"
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    replayed_failure_sample = $failure.failure_sample
    baseline_rejected = $true
    limit_rejections = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: finite sequence intersection preserves shared endpoints across delays, repetition, disjunction, proofs and source replay.'
