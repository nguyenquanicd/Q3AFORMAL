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
$project = "$root/first.q3a"
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'
@('Q3AFORMAL_PROJECT 2','top earliest','source systemverilog "first.sv"',$profile) |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
@'
module earliest(input logic clk);
    logic q, r, s;
    always_ff @(posedge clk) begin
        q <= 1'b1;
        r <= q;
        s <= r;
    end
    sequence starting;
        (q === 1'bx) ##[1:2] 1'b1;
    endsequence
    p_first: assert property (@(posedge clk) first_match(starting) |-> (r === 1'bx));
    p_every: assert property (@(posedge clk) starting |-> (r === 1'bx));
    c_late: cover property (@(posedge clk) first_match((1'b1 ##1 1'b0) or (1'b1 ##2 1'b1)));
    c_unknown: cover property (@(posedge clk) first_match((1'b1 ##1 1'bx) or (1'b1 ##2 1'b1)));
    c_ties: cover property (@(posedge clk)
        first_match(1'b0 or (1'b0 ##1 1'b1) or (1'b1 ##1 1'b1)));
    c_concat_absent: cover property (@(posedge clk) first_match(starting) ##1 (s === 1'b1));
    c_concat_control: cover property (@(posedge clk) starting ##1 (s === 1'b1));
    c_repeat: cover property (@(posedge clk) first_match(1'b1 ##[1:2] 1'b1)[*2]);
    c_nested: cover property (@(posedge clk)
        first_match((1'b1 ##3 1'b1) or (first_match(1'b1 ##[1:2] 1'b1) ##1 1'b1)));
endmodule
'@ | Set-Content -LiteralPath "$root/first.sv" -Encoding utf8NoBOM

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
foreach ($test in @(
    @{ name='c_late'; sample=2 },
    @{ name='c_unknown'; sample=2 },
    @{ name='c_ties'; sample=1 },
    @{ name='c_concat_control'; sample=3 },
    @{ name='c_repeat'; sample=3 },
    @{ name='c_nested'; sample=2 }
)) {
    $name = $test.name
    $hit = Run "$name-hit" $name $test.sample COVERED 0
    $reopened = Run "$name-replay" $name $test.sample COVERED 0 -Verify
    if (!$hit.source_replayed -or !$reopened.witness_revalidated -or $reopened.attempt_sample -ne 0 -or
        $reopened.match_sample -ne $test.sample -or $reopened.witness_sha256 -cne $hit.witness_sha256) {
        throw "Incorrect endpoint or replay for $name."
    }
    $witnesses[$name] = $reopened.witness_sha256
}

$proofs = [ordered]@{}
foreach ($test in @(
    @{ name='p_first'; steps=2; cover=$false },
    @{ name='c_concat_absent'; steps=3; cover=$true }
)) {
    $name = $test.name
    $status = if ($test.cover) { 'NOT_FOUND_WITHIN_BOUND' } else { 'BOUNDED_PASS' }
    $kind = if ($test.cover) { 'four-state-sampled-cover' } else { 'four-state-sampled-sva' }
    $proof = Run "$name-proof" $name $test.steps $status ([int]$test.cover)
    $reopened = Run "$name-reopen" $name $test.steps REVALIDATED 0 -Verify
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) {
        throw "Independent certificate check failed for $name."
    }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}
$failure = Run all-endpoints p_every 2 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.antecedent_end_sample -ne 2 -or $failure.failure_sample -ne 2) {
    throw 'The control property lost the later failing endpoint.'
}

foreach ($case in @(
    @{ name='baseline'; source="first_match(1'b1 ##1 1'b1)"; profile=@(); diagnostic="temporal operator 'first_match'" },
    @{ name='match-item'; source="first_match(1'b1 ##1 1'b1, value = 1'b0)"; profile=@($profile); diagnostic='first_match sequence match items' }
)) {
    $name = $case.name
    @"
module earliest(input logic clk);
    c_bad: cover property (@(posedge clk) $($case.source));
endmodule
"@ | Set-Content -LiteralPath "$root/$name.sv" -Encoding utf8NoBOM
    (@('Q3AFORMAL_PROJECT 2','top earliest',('source systemverilog "{0}.sv"' -f $name)) + $case.profile) |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
    & $exe --parse-project "$root/$name.q3a" > "$root/$name.stdout.txt" 2> "$root/$name.stderr.txt"
    if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/$name.stderr.txt" -Raw) -notlike "*$($case.diagnostic)*") {
        throw "Incorrect rejection for $name."
    }
}

[ordered]@{
    status = 'FOUR_STATE_FIRST_MATCH_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/first.sv"
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    unfiltered_failure_sample = $failure.failure_sample
    rejected_cases = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: earliest match selection, ties, unknown earlier predicates, nested sequences, repetition, and independently checked proof and replay.'
