#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CheckerPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = @('Q3AFORMAL_PROJECT 2','top example','source systemverilog "sva.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT')
$project = "$root/example.q3a"
$rtl = @"
module example(input logic clk, req, data, output logic q);
    logic warm;
    always_ff @(posedge clk) begin q <= req; warm <= 1'b1; end
    p_inactive_x: assert property (@(posedge clk) 1'bx |-> 1'b0);
    p_inactive_z: assert property (@(posedge clk) 1'bz |-> 1'b0);
    p_startup: assert property (@(posedge clk) q === 1'bx);
    p_exact: assert property (@(posedge clk) q === q);
    property next_req;
        @(posedge clk) req |=> q;
    endproperty
    p_next: assert property (next_req);
    p_bad_next: assert property (@(posedge clk) req |=> !q);
    p_bad_x: assert property (@(posedge clk) (data === 1'bx) |-> data);
    p_bad_z: assert property (@(posedge clk) (data === 1'bz) |-> data);
    p_bare: assert property (@(posedge clk) q);
    p_early: assert property (@(posedge clk) warm);
endmodule
"@
Set-Content -LiteralPath $project -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/sva.sv" -Value $rtl -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, [string[]]$ArgsList) {
    $text = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $exitCode = $LASTEXITCODE
    $text | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $result = $text | ConvertFrom-Json
    if ($result.status -cne $Status -or $exitCode -ne $Code -or $result.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code, got $text $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $result
}

$search = @('dev-prove-four-state',$project,'--property')
$verify = @('dev-verify-four-state',$project,'--property')
$cases = [ordered]@{p_inactive_x='0'; p_inactive_z='0'; p_startup='0'; p_exact='2'; p_next='3'}
$evidence = [ordered]@{}
foreach ($name in $cases.Keys) {
    $proofDir = "$root/proof-$name"
    $options = @($name,'--evidence-dir',$proofDir,'--steps',$cases[$name])
    $proof = Run "prove-$name" BOUNDED_PASS 0 ($search + $options)
    $checked = Run "reopen-$name" REVALIDATED 0 ($verify + $options)
    if ($checked.property -cne $name -or $checked.steps -ne [int]$cases[$name] -or
        $checked.proof_sha256 -cne $proof.proof_sha256 -or (Hash "$proofDir/query.cnf") -cne $checked.query_sha256) {
        throw "Unexpected certificate identity for $name."
    }
    $records = @(& $checker --check-drat "$proofDir/query.cnf" "$proofDir/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind four-state-sampled-sva)
    if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Standalone checker rejected $name." }
    $records | Set-Content -LiteralPath "$root/checker-$name.txt" -Encoding utf8NoBOM
    $evidence[$name] = $checked.proof_sha256
}

foreach ($bit in 'x','z') {
    $name = "p_bad_$bit"
    $result = Run $name COUNTEREXAMPLE 0 ($search + @($name,'--evidence-dir',"$root/unused-$bit",'--steps','0'))
    if ($result.attempt_sample -ne 0 -or $result.failure_sample -ne 0 -or
        !$result.source_replayed -or $result.signals.data -cne $bit) {
        throw "Expected a same-sample $bit consequent failure."
    }
}
$result = Run next-bad COUNTEREXAMPLE 0 ($search + @('p_bad_next','--evidence-dir',"$root/unused-next",'--steps','1'))
if ($result.attempt_sample -ne 0 -or $result.failure_sample -ne 1 -or
    $result.trace[0].req -cne '1' -or $result.trace[1].q -cne '1' -or !$result.source_replayed) {
    throw 'Wrong nonoverlapped antecedent or consequent sample.'
}
$result = Run bare-x COUNTEREXAMPLE 0 ($search + @('p_bare','--evidence-dir',"$root/unused-bare",'--steps','0'))
if ($result.failure_sample -ne 0 -or $result.signals.q -cne 'x') { throw 'Unknown bare assertion did not fail.' }
$result = Run completed-earlier COUNTEREXAMPLE 0 ($search + @('p_early','--evidence-dir',"$root/unused-early",'--steps','2'))
if ($result.attempt_sample -ne 0 -or $result.failure_sample -ne 0 -or $result.trace.Count -ne 3 -or
    $result.signals.warm -cne 'x' -or $result.trace[2].warm -cne '1') {
    throw 'A failure preceding the final sample was lost.'
}
$null = Run incomplete REJECTED 2 ($search + @('p_next','--evidence-dir',"$root/unused-tail",'--steps','0'))
$null = Run omitted-bound REJECTED 2 ($search + @('p_exact','--evidence-dir',"$root/unused-bound"))
$null = Run wrong-bound REJECTED 2 ($verify + @('p_next','--evidence-dir',"$root/proof-p_next",'--steps','2'))
$null = Run wrong-property REJECTED 2 ($verify + @('p_bad_next','--evidence-dir',"$root/proof-p_next",'--steps','3'))
foreach ($entry in @(
    @{name='history'; pattern='q === q'; value='q === $past(q && q)'},
    @{name='delayed'; pattern='q === q'; value='(q === q) ##129 (q === q)'},
    @{name='disable'; pattern='(posedge clk) q === q'; value='(posedge clk) disable iff (req) q === q'}
)) {
    $name = $entry.name
    $changed = $rtl.Replace($entry.pattern, $entry.value)
    Set-Content -LiteralPath "$root/$name.sv" -Value $changed -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$name.q3a" -Value ($manifest -replace 'sva\.sv',"$name.sv") -Encoding utf8NoBOM
    $null = Run $name REJECTED 2 @('dev-prove-four-state',"$root/$name.q3a",'--property','p_exact','--evidence-dir',"$root/reject-$name",'--steps','3')
}

$comb = $rtl.Replace("    always_ff @(posedge clk) begin q <= req; warm <= 1'b1; end", "    assign q = req; assign warm = 1'b1;")
Set-Content -LiteralPath "$root/comb.sv" -Value $comb -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/comb.q3a" -Value ($manifest -replace 'sva\.sv','comb.sv') -Encoding utf8NoBOM
$null = Run assertion-only-clock BOUNDED_PASS 0 @('dev-prove-four-state',"$root/comb.q3a",'--property','p_exact','--evidence-dir',"$root/comb-proof",'--steps','1')

[ordered]@{
    status = 'FOUR_STATE_SVA_BOUNDED_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $evidence
    counterexamples_replayed = 5
    rejected_cases = 7
    assertion_only_clock = 'BOUNDED_PASS'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: five reopened SVA proofs with standalone checking, five replayed failures, seven rejections and an assertion-only clock.'
