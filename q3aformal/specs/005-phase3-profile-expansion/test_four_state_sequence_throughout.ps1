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
$project = "$root/throughout.q3a"
$manifest = @('Q3AFORMAL_PROJECT 2', 'top throughout_demo')
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'
($manifest + 'source systemverilog "throughout.sv"' + $profile) |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
@'
module throughout_demo(input logic clk, grant, req, ack);
    logic armed, finished, guard;
    always_ff @(posedge clk) begin
        armed <= 1'b1;
        finished <= armed;
    end
    assign guard = (armed !== 1'b1) || (finished === 1'b1);
    c_protocol: cover property (@(posedge clk) grant throughout req ##2 ack);
    c_shifted: cover property (@(posedge clk)
        (grant === 1'b0) ##1 (grant throughout (req ##[1:2] ack)));
    c_nested: cover property (@(posedge clk) grant throughout req throughout (1'b1 ##2 ack));
    c_right_length: cover property (@(posedge clk)
        guard throughout ((1'b1 ##2 1'b1) or 1'b1));
    c_gap: cover property (@(posedge clk) guard throughout (1'b1 ##2 1'b1));
    c_unknown: cover property (@(posedge clk) grant throughout (grant === 1'bx));
    p_gap: assert property (@(posedge clk) guard throughout (1'b1 ##2 1'b1));
    p_taut: assert property (@(posedge clk) 1'b1 throughout (1'b1 ##[1:2] 1'b1));
endmodule
'@ | Set-Content -LiteralPath "$root/throughout.sv" -Encoding utf8NoBOM

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
    @{ name = 'c_protocol'; sample = 2; check_grant = '111' },
    @{ name = 'c_shifted'; sample = 2; check_grant = '011' },
    @{ name = 'c_nested'; sample = 2; check_grant = '111' },
    @{ name = 'c_right_length'; sample = 0 }
)) {
    $name = $item.name
    $hit = Run "$name-hit" $name $item.sample COVERED 0
    $reopened = Run "$name-replay" $name $item.sample COVERED 0 -Verify
    if (!$hit.source_replayed -or !$reopened.witness_revalidated -or $reopened.attempt_sample -ne 0 -or
        $reopened.match_sample -ne $item.sample -or $reopened.witness_sha256 -cne $hit.witness_sha256) {
        throw "Incorrect endpoint or saved witness for $name."
    }
    if ($item.check_grant -and ($reopened.trace.grant -join '') -cne $item.check_grant) {
        throw "The guard did not hold at the required samples for $name."
    }
    if ($name -ceq 'c_nested' -and ($reopened.trace.req -join '') -cne '111') {
        throw 'A nested guard was not enforced through the whole sequence.'
    }
    $witnesses[$name] = $reopened.witness_sha256
}

$proofs = [ordered]@{}
foreach ($item in @(
    @{ name = 'c_gap'; steps = 2; cover = $true },
    @{ name = 'c_unknown'; steps = 0; cover = $true },
    @{ name = 'p_taut'; steps = 2; cover = $false }
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

$failure = Run gap-failure p_gap 2 COUNTEREXAMPLE 0
if (!$failure.source_replayed -or $failure.attempt_sample -ne 0 -or
    $failure.failure_sample -ne 2 -or ($failure.trace.guard -join '') -cne '101') {
    throw 'The guard failure in the delay gap was not independently reproduced.'
}

foreach ($case in @(
    @{ name = 'baseline'; expression = "1'b1 throughout (1'b1 ##2 1'b1)"; profile = @(); exit = 1; diagnostic = "temporal operator 'throughout'" },
    @{ name = 'invalid-left'; expression = "(1'b1 ##1 1'b1) throughout 1'b1"; profile = @($profile); exit = 2; diagnostic = 'throughout requires a scalar expression' }
)) {
    $name = $case.name
    ($manifest + ('source systemverilog "{0}.sv"' -f $name) + $case.profile) |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
    @"
module throughout_demo(input logic clk);
    c_bad: cover property (@(posedge clk) $($case.expression));
endmodule
"@ | Set-Content -LiteralPath "$root/$name.sv" -Encoding utf8NoBOM
    $invocation = if ($case.profile) {
        @('dev-prove-four-state', "$root/$name.q3a", '--property', 'c_bad', '--evidence-dir', "$root/bad-evidence", '--steps', '1')
    } else {
        @('--parse-project', "$root/$name.q3a")
    }
    & $exe @invocation > "$root/$name.stdout.txt" 2> "$root/$name.stderr.txt"
    if ($LASTEXITCODE -ne $case.exit -or (Test-Path "$root/bad-evidence") -or
        (Get-Content "$root/$name.stderr.txt" -Raw) -notlike "*$($case.diagnostic)*") {
        throw "Expected $name rejection."
    }
}

[ordered]@{
    status = 'FOUR_STATE_SEQUENCE_THROUGHOUT_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/throughout.sv"
    model_sha256 = $failure.model_sha256
    proof_sha256 = $proofs
    witness_sha256 = $witnesses
    replayed_failure_sample = $failure.failure_sample
    rejected_cases = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: throughout guard checks in delay gaps, nested and shifted windows, four replays, three independent certificates, and two rejections.'
