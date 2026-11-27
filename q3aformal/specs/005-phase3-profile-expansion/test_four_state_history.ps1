#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CheckerPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = @('Q3AFORMAL_PROJECT 2','top history_demo','source systemverilog "history.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT')
$rtl = @"
module history_demo(input logic clk, input logic [1:0] d);
    logic [1:0] q, r;
    always_ff @(posedge clk) begin q <= d; r <= q; end
    p_initial: assert property (@(posedge clk) `$past(d, 2) === 2'bxx);
    p_pipeline: assert property (@(posedge clk) q === `$past(d));
    p_two: assert property (@(posedge clk) r === `$past(d, 2));
    p_stable_z: assert property (@(posedge clk) ((d === 2'bzz) && (`$past(d) === 2'bzz)) |-> `$stable(d));
    p_changed_zx: assert property (@(posedge clk) ((d === 2'bxx) && (`$past(d) === 2'bzz)) |-> `$changed(d));
    p_msb_only: assert property (@(posedge clk) ((d === 2'b11) && (`$past(d) === 2'b01)) |-> !`$rose(d));
    p_bad_rose: assert property (@(posedge clk) ((d === 2'b01) && (`$past(d) === 2'bzz)) |-> !`$rose(d));
    p_bad_fell: assert property (@(posedge clk) ((d === 2'b00) && (`$past(d) === 2'bzz)) |-> !`$fell(d));
    p_implicit_start: assert property (@(posedge clk) (d === 2'b01) |-> !`$rose(d));
endmodule
"@
Set-Content -LiteralPath "$root/history.q3a" -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/history.sv" -Value $rtl -Encoding utf8NoBOM
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, [string[]]$ArgsList) {
    $raw = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $exit = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $parsed = $raw | ConvertFrom-Json
    if ($parsed.status -cne $Status -or $exit -ne $Code -or $parsed.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $parsed
}
$project = "$root/history.q3a"
$prove = @('dev-prove-four-state',$project,'--property')
$verify = @('dev-verify-four-state',$project,'--property')
$evidence = [ordered]@{}
$cases = [ordered]@{p_initial='1'; p_pipeline='4'; p_two='4'; p_stable_z='1'; p_changed_zx='1'; p_msb_only='1'}
foreach ($name in $cases.Keys) {
    $dir = "$root/proof-$name"
    $options = @($name,'--evidence-dir',$dir,'--steps',$cases[$name])
    $proved = Run "proved-$name" BOUNDED_PASS 0 ($prove + $options)
    $checked = Run "checked-$name" REVALIDATED 0 ($verify + $options)
    if ($proved.proof_sha256 -cne $checked.proof_sha256 -or $checked.query_sha256 -cne (Hash "$dir/query.cnf")) {
        throw 'Source regeneration changed the archive identity.'
    }
    $records = @(& $checker --check-drat "$dir/query.cnf" "$dir/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind four-state-sampled-sva)
    if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Failed standalone check for $name." }
    $records | Set-Content -LiteralPath "$root/checker-$name.txt" -Encoding utf8NoBOM
    $evidence[$name] = $checked.proof_sha256
}

foreach ($entry in @(@{name='p_bad_rose'; current='01'},@{name='p_bad_fell'; current='00'})) {
    $witness = Run $entry.name COUNTEREXAMPLE 0 ($prove + @($entry.name,'--evidence-dir',"$root/unused",'--steps','1'))
    if (!$witness.source_replayed -or $witness.failure_sample -ne 1 -or $witness.trace[0].d -cne 'zz' -or
        $witness.trace[1].d -cne $entry.current -or $witness.trace[1].q -cne 'zz') {
        throw 'X/Z-aware edge did not replay at the correct sample.'
    }
}
$initial = Run early-edge COUNTEREXAMPLE 0 ($prove + @('p_implicit_start','--evidence-dir',"$root/unused",'--steps','0'))
if (!$initial.source_replayed -or $initial.failure_sample -ne 0 -or $initial.signals.d -cne '01') {
    throw 'An edge relative to the initial X sample was suppressed.'
}
$late = Run later-history COUNTEREXAMPLE 0 ($prove + @('p_initial','--evidence-dir',"$root/unused",'--steps','2'))
if (!$late.source_replayed -or $late.failure_sample -ne 2 -or $late.trace[0].d -ceq 'xx' -or
    $late.trace[2].r -cne $late.trace[0].d) {
    throw 'Two-sample history was not filled with the actual source value.'
}
foreach ($entry in @(
    @{name='gated'; text='$past(d, 2, d[0])'},
    @{name='expression'; text='$past(d & d, 2)'},
    @{name='oversize'; text='$past(d, 129)'},
    @{name='sample-clock'; text='$past(clk, 2)'}
)) {
    $name = $entry.name
    Set-Content -LiteralPath "$root/$name.sv" -Value $rtl.Replace('$past(d, 2)',$entry.text) -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$name.q3a" -Value ($manifest -replace 'history\.sv',"$name.sv") -Encoding utf8NoBOM
    $null = Run $name REJECTED 2 @('dev-prove-four-state',"$root/$name.q3a",'--property','p_initial','--evidence-dir',"$root/unused-$name",'--steps','2')
}
[ordered]@{
    status = 'FOUR_STATE_HISTORY_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $evidence
    replayed_counterexamples = 4
    rejected_cases = 4
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: six source-checked history certificates, four replayed X/Z and startup witnesses, and four rejections.'
