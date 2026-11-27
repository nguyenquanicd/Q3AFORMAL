#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CheckerPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$base = @"
module assumption_demo(input logic clk, req, data);
    p_no_z: assert property (@(posedge clk) data !== 1'bz);
    p_no_x: assert property (@(posedge clk) data !== 1'bx);
    p_turn: assert property (@(posedge clk) req |=> !req);
    p_false: assert property (@(posedge clk) 1'b0);
    ASSUMPTIONS
endmodule
"@
$fixtures = [ordered]@{
    local="a_no_z: assume property (@(posedge clk) data !== 1'bz);"
    different="a_no_z: assume property (@(posedge clk) data !== 1'bx);"
    x_impossible="a_bad: assume property (@(posedge clk) 1'bx);"
    z_impossible="a_bad: assume property (@(posedge clk) 1'bz);"
    temporal='a_turn: assume property (@(posedge clk) req |=> !req);'
    sequence='a_direct: assume property (@(posedge clk) req ##1 !req);'
}
foreach ($case in $fixtures.Keys) {
    Set-Content -LiteralPath "$root/$case.sv" -Value $base.Replace('ASSUMPTIONS',$fixtures[$case]) -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$case.q3a" -Value @(
        'Q3AFORMAL_PROJECT 2','top assumption_demo',"source systemverilog `"$case.sv`"",
        'option profile Q3A-FOUR-STATE-DEVELOPMENT'
    ) -Encoding utf8NoBOM
}
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, $Project, $Property, [string]$Steps, $Directory, [switch]$Verify) {
    $command = if ($Verify) { 'dev-verify-four-state' } else { 'dev-prove-four-state' }
    $result = @(& $exe $command "$root/$Project.q3a" --property $Property --evidence-dir $Directory --steps $Steps 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $result | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $value = $result | ConvertFrom-Json
    if ($value.status -cne $Status -or $actual -ne $Code -or $value.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code. $result $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $value
}
$proofs = [ordered]@{}
foreach ($item in @(
    @{name='local'; property='p_no_z'; steps='2'},
    @{name='temporal'; property='p_turn'; steps='3'},
    @{name='sequence'; property='p_turn'; steps='1'}
)) {
    $id = $item.name
    $path = "$root/proof-$id"
    $proved = Run "proved-$id" BOUNDED_PASS 0 $id $item.property $item.steps $path
    $checked = Run "verified-$id" REVALIDATED 0 $id $item.property $item.steps $path -Verify
    if ($checked.proof_sha256 -cne $proved.proof_sha256 -or $checked.query_sha256 -cne (Hash "$path/query.cnf")) {
        throw "Wrong proof identity for $id."
    }
    $records = @(& $checker --check-drat "$path/query.cnf" "$path/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind four-state-sampled-sva)
    if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Standalone check failed for $id." }
    $proofs[$id] = $checked.proof_sha256
}
$path = "$root/no-counterexample-dir"
$closed = Run closed COUNTEREXAMPLE 0 local p_no_x '1' $path
if (!$closed.source_replayed -or $closed.signals.data -cne 'x' -or $closed.assumption_boundary_open -or
    @($closed.trace | Where-Object data -CEQ 'z').Count) { throw 'Known environment restrictions were not replayed.' }
$pending = Run pending WITNESS_PENDING_ASSUMPTION 1 temporal p_false '1' $path
if (!$pending.source_replayed -or !$pending.assumption_boundary_open -or
    ($pending.trace[0].req -ceq '1' -and $pending.trace[1].req -cne '0')) {
    throw 'Temporal witness failed completed constraints or lacked an open boundary flag.'
}
$partial = Run partial WITNESS_PENDING_ASSUMPTION 1 sequence p_false '0' $path
if (!$partial.assumption_boundary_open -or $partial.trace.Count -ne 1) { throw 'An unfinished direct assumption was treated as complete.' }
if (Test-Path -LiteralPath $path) { throw 'A witness unexpectedly published a proof.' }

foreach ($item in @(
    @{name='x_impossible'; steps='0'},
    @{name='z_impossible'; steps='0'},
    @{name='sequence'; steps='2'}
)) {
    $destination = "$root/contradiction-$($item.name)"
    $null = Run "inconsistent-$($item.name)" INCONSISTENT 1 $item.name p_false $item.steps $destination
    if (Test-Path -LiteralPath $destination) { throw 'An inconsistent environment published an assertion proof.' }
}
$null = Run changed-environment REJECTED 2 different p_no_z '2' "$root/proof-local" -Verify
[ordered]@{
    status = 'FOUR_STATE_ASSUMPTIONS_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $proofs
    replayed_witnesses = 3
    provisional_witnesses = 2
    inconsistent_environments = 3
    changed_environment_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: three reopened proofs, three replayed witnesses, three inconsistent environments and source-bound assumption identity.'
