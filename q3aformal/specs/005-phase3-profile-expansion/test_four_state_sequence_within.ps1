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
$project = "$root/within.q3a"
$manifest = @('Q3AFORMAL_PROJECT 2', 'top within_demo')
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'
($manifest + 'source systemverilog "within.sv"' + $profile) |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
@'
module within_demo(input logic clk);
    logic q, r, s, first, second;
    always_ff @(posedge clk) begin
        q <= 1'b1;
        r <= q;
        s <= r;
    end
    assign first = (q === 1'b1) && (r === 1'bx);
    assign second = (r === 1'b1) && (s === 1'bx);
    c_inside: cover property (@(posedge clk) first ##1 second within 1'b1 ##3 1'b1);
    c_end_touch: cover property (@(posedge clk) first ##1 second within 1'b1 ##2 1'b1);
    c_start_touch: cover property (@(posedge clk) (q === 1'bx) ##1 first within 1'b1 ##1 1'b1);
    c_concat: cover property (@(posedge clk) (first within (1'b1 ##3 1'b1)) ##1 (s === 1'b1));
    c_late_inner: cover property (@(posedge clk) second ##2 1'b1 within 1'b1 ##3 1'b1);
    c_no_room: cover property (@(posedge clk) 1'b1 ##3 1'b1 within 1'b1 ##1 1'b1);
    c_outer_failed: cover property (@(posedge clk) first within 1'b1 ##2 1'bx);
    p_ends: assert property (@(posedge clk) (first within (1'b1 ##[1:3] 1'b1)) |-> (s === 1'bx));
    p_goal: assert property (@(posedge clk) 1'b1 |-> (1'b1 within (1'b1 ##1 1'b1)));
endmodule
'@ | Set-Content -LiteralPath "$root/within.sv" -Encoding utf8NoBOM

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
    @{ name = 'c_inside'; sample = 3 },
    @{ name = 'c_end_touch'; sample = 2 },
    @{ name = 'c_start_touch'; sample = 1 },
    @{ name = 'c_concat'; sample = 4 }
)) {
    $name = $item.name
    $hit = Run "$name-hit" $name $item.sample COVERED 0
    $reopened = Run "$name-replay" $name $item.sample COVERED 0 -Verify
    if (!$hit.source_replayed -or !$reopened.witness_revalidated -or $reopened.attempt_sample -ne 0 -or
        $reopened.match_sample -ne $item.sample -or $reopened.witness_sha256 -cne $hit.witness_sha256) {
        throw "Incorrect endpoint or saved witness for $name."
    }
    if ($name -ceq 'c_inside' -and (($reopened.trace.first -join '') -cne '0100' -or
        ($reopened.trace.second -join '') -cne '0010')) {
        throw 'The inner match did not start and finish strictly inside the enclosing match.'
    }
    $witnesses[$name] = $reopened.witness_sha256
}

$proofs = [ordered]@{}
foreach ($item in @(
    @{ name = 'c_late_inner'; steps = 3; cover = $true },
    @{ name = 'c_no_room'; steps = 1; cover = $true },
    @{ name = 'c_outer_failed'; steps = 2; cover = $true },
    @{ name = 'p_goal'; steps = 1; cover = $false }
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

$failure = Run enclosing-endpoints p_ends 3 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.antecedent_end_sample -ne 3 -or $failure.failure_sample -ne 3 -or
    $failure.trace[2].s -cne 'x' -or $failure.trace[3].s -cne '1') {
    throw 'A passing shorter enclosing match hid a later failing obligation.'
}
($manifest + 'source systemverilog "baseline.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
@'
module within_demo(input logic clk);
    c_baseline: cover property (@(posedge clk) 1'b1 within (1'b1 ##2 1'b1));
endmodule
'@ | Set-Content -LiteralPath "$root/baseline.sv" -Encoding utf8NoBOM
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notlike "*temporal operator 'within'*") {
    throw 'The baseline grammar did not reject within.'
}

[ordered]@{
    status = 'FOUR_STATE_SEQUENCE_WITHIN_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/within.sv"
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    replayed_failure_sample = $failure.failure_sample
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: finite containment at interior and boundary samples, four cover witnesses, four independent certificates, and a replayed counterexample.'
