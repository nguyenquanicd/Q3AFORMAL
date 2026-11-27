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
$project = "$root/sequence-or.q3a"
$design = @('Q3AFORMAL_PROJECT 2', 'top sequence_or', 'source systemverilog "sequence-or.sv"')
($design + 'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
$design | Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
@'
module sequence_or(input logic clk);
    logic stage1, stage2;
    always_ff @(posedge clk) begin
        stage1 <= 1'b1;
        stage2 <= stage1;
    end
    p_either: assert property (@(posedge clk) 1'b1 |-> (1'b0 ##1 1'b1 or 1'b1 ##2 1'b1));
    p_both: assert property (@(posedge clk) (1'b1 ##1 1'b1 or 1'b1 ##2 1'b1) |-> (stage2 === 1'bx));
    c_early: cover property (@(posedge clk) 1'b1 ##3 1'b1 or 1'b1 ##1 1'b1);
    c_concat: cover property (@(posedge clk) 1'b1 ##1 (1'b0 or (1'b1 ##1 1'b1)) ##1 1'b1);
    c_repeat: cover property (@(posedge clk) ((1'b1 ##1 1'b1) or 1'b0)[*2]);
    c_none: cover property (@(posedge clk) (1'bx ##1 1'b1) or (1'bz ##2 1'b1));
endmodule
'@ | Set-Content -LiteralPath "$root/sequence-or.sv" -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Id, $Property, $Steps, $Expected, $Code, [switch]$Verify) {
    $command = if ($Verify) { 'dev-verify-four-state' } else { 'dev-prove-four-state' }
    $raw = & $exe $command $project --property $Property --evidence-dir "$root/artifacts-$Property" --steps $Steps 2> "$root/$Id.stderr.txt"
    $exitCode = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($result.status -cne $Expected -or $exitCode -ne $Code -or $result.exit_code -ne $Code) {
        throw "$Id expected $Expected/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$proofs = [ordered]@{}
foreach ($test in @(
    @{ name = 'p_either'; status = 'BOUNDED_PASS'; exit = 0; kind = 'four-state-sampled-sva' },
    @{ name = 'c_none'; status = 'NOT_FOUND_WITHIN_BOUND'; exit = 1; kind = 'four-state-sampled-cover' }
)) {
    $name = $test.name
    $proof = Run $name $name 2 $test.status $test.exit
    $reopened = Run "reopen-$name" $name 2 REVALIDATED 0 -Verify
    $directory = "$root/artifacts-$name"
    $checked = @(& $checker --check-drat "$directory/query.cnf" "$directory/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $test.kind)
    if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256 -or
        $proof.proof_sha256 -cne (Hash "$directory/proof.q3adrat")) {
        throw "Certificate check failed for $name."
    }
    $checked | Set-Content -LiteralPath "$root/checker-$name.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}

$failure = Run p_both p_both 2 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.antecedent_end_sample -ne 2 -or $failure.failure_sample -ne 2 -or
    $failure.trace[1].stage2 -cne 'x' -or $failure.trace[2].stage2 -cne '1') {
    throw 'A shorter successful match masked the failing second antecedent endpoint.'
}

$witnesses = [ordered]@{}
foreach ($test in @(
    @{ name = 'c_early'; endpoint = 1 },
    @{ name = 'c_concat'; endpoint = 3 },
    @{ name = 'c_repeat'; endpoint = 3 }
)) {
    $name = $test.name
    $hit = Run $name $name $test.endpoint COVERED 0
    $reopened = Run "reopen-$name" $name $test.endpoint COVERED 0 -Verify
    if (!$hit.source_replayed -or $hit.attempt_sample -ne 0 -or
        $hit.match_sample -ne $test.endpoint -or !$reopened.witness_revalidated -or
        $hit.witness_sha256 -cne $reopened.witness_sha256) {
        throw "Incorrect replay or disjunction endpoint for $name."
    }
    $witnesses[$name] = $hit.witness_sha256
}

& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content -LiteralPath "$root/baseline.stderr.txt" -Raw) -notlike "*temporal operator 'or'*") {
    throw 'The default grammar did not reject sequence disjunction.'
}
[ordered]@{
    status = 'FOUR_STATE_SEQUENCE_OR_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    replayed_failure_sample = $failure.failure_sample
    baseline_rejected = $true
    source_sha256 = Hash "$root/sequence-or.sv"
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: finite SVA disjunction certificates, antecedent endpoints, cover witnesses, and baseline rejection.'
