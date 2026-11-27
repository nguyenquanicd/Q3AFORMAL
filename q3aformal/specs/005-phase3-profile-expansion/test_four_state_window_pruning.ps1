#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$PreviousExecutablePath,
    [Parameter(Mandatory)][string]$CheckerPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$previous = (Resolve-Path -LiteralPath $PreviousExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = "$root/window.q3a"
@('Q3AFORMAL_PROJECT 2','top window_demo','source systemverilog "window.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
    Set-Content -LiteralPath $project -Encoding utf8NoBOM
$common = (@("d[*1:4]") * 5) -join ' ##1 '
$wide = (@("d[*1:12]") * 8) -join ' ##1 '
@"
module window_demo(input logic clk, d);
    c_common: cover property (@(posedge clk) $common);
    a_common: assert property (@(posedge clk) 1'b1 ##[1:5] 1'b1);
    c_stress: cover property (@(posedge clk) $wide);
endmodule
"@ | Set-Content -LiteralPath "$root/window.sv" -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Claim($Id, $Binary, $Command, $Property, $Steps, $Path, $Expected, $Code) {
    $raw = & $Binary $Command $project --property $Property --evidence-dir $Path --steps $Steps 2> "$root/$Id.stderr.txt"
    $exitCode = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($exitCode -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Expected) {
        throw "$Id expected $Expected/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$prove = 'dev-prove-four-state'
$verify = 'dev-verify-four-state'
$oldProof = Invoke-Claim old-proof $previous $prove a_common 5 "$root/prior-proof" BOUNDED_PASS 0
$freshProof = Invoke-Claim new-proof $exe $prove a_common 5 "$root/fresh-proof" BOUNDED_PASS 0
$reopened = Invoke-Claim new-proof-reopened $exe $verify a_common 5 "$root/fresh-proof" REVALIDATED 0
if ($oldProof.query_sha256 -cne $freshProof.query_sha256 -or
    $freshProof.proof_sha256 -cne $reopened.proof_sha256 -or
    $oldProof.proof_model_sha256 -ceq $freshProof.proof_model_sha256) {
    throw 'Pruning changed the existing query or lost the build identity.'
}
$oldWitness = Invoke-Claim old-witness $previous $prove c_common 4 "$root/prior-witness" COVERED 0
$freshWitness = Invoke-Claim new-witness $exe $prove c_common 4 "$root/fresh-witness" COVERED 0
$replay = Invoke-Claim new-witness-reopened $exe $verify c_common 4 "$root/fresh-witness" COVERED 0
if (!$replay.witness_revalidated -or $replay.witness_sha256 -cne $freshWitness.witness_sha256 -or
    $replay.attempt_sample -ne 0 -or $replay.match_sample -ne 4 -or
    (ConvertTo-Json -InputObject $replay.trace -Compress) -cne
    (ConvertTo-Json -InputObject $oldWitness.trace -Compress)) {
    throw 'The new build changed a previously reachable cover match.'
}
$null = Invoke-Claim out-of-build-witness $exe $verify c_common 4 "$root/prior-witness" REJECTED 2

$null = Invoke-Claim prior-stress $previous $prove c_stress 7 "$root/prior-stress" REJECTED 2
$miss = Invoke-Claim stress-short $exe $prove c_stress 6 "$root/miss" NOT_FOUND_WITHIN_BOUND 1
$check = @(& $checker --check-drat "$root/miss/query.cnf" "$root/miss/proof.q3adrat" --model-sha256 $miss.proof_model_sha256 --query-kind four-state-sampled-cover)
if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
    throw 'The independent checker rejected the impossible short-window cover certificate.'
}
$check | Set-Content -LiteralPath "$root/checker-miss.txt" -Encoding utf8NoBOM
$hit = Invoke-Claim stress-hit $exe $prove c_stress 7 "$root/hit" COVERED 0
$opened = Invoke-Claim stress-reopen $exe $verify c_stress 7 "$root/hit" COVERED 0
if (!$opened.witness_revalidated -or $opened.attempt_sample -ne 0 -or $opened.match_sample -ne 7 -or
    $opened.witness_sha256 -cne $hit.witness_sha256 -or
    @($opened.trace | Where-Object d -cne '1').Count -ne 0) {
    throw 'Incorrect replay for the eight-sample cover witness.'
}
$null = Invoke-Claim stress-over-limit $exe $prove c_stress 95 "$root/over-budget" RESOURCE_LIMIT 1
if (Test-Path -LiteralPath "$root/over-budget") { throw 'Resource failure published evidence.' }

[ordered]@{
    status = 'FOUR_STATE_BOUNDED_PATH_PRUNING_QUALIFIED'
    executable_sha256 = Hash $exe
    previous_binary_sha256 = Hash $previous
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/window.sv"
    unchanged_query_sha256 = $oldProof.query_sha256
    fresh_proof_sha256 = $freshProof.proof_sha256
    fresh_witness_sha256 = $freshWitness.witness_sha256
    prior_build_witness_rejected = $true
    stress_cover_sample = $opened.match_sample
    stress_witness_sha256 = $opened.witness_sha256
    shorter_window_proof_sha256 = $miss.proof_sha256
    wider_window_resource_limit = $true
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: pruned bounded cover, independent miss checking, identical query and trace across builds, and wider-window resource limit.'
