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

$combinational = @'
module signed_leaf(input logic signed [1:0] value, output logic below);
    assign below = value < 2'sd0;
endmodule
module signed_wrap(input logic [1:0] value, output logic below);
    signed_leaf leaf(.value(value), .below(below));
endmodule
module signed_top(input logic [1:0] value, output logic below, output logic invariant);
    signed_wrap wrapper(.value(value), .below(below));
    logic expected;
    assign expected = ((value[1] === 1'bx) || (value[1] === 1'bz) ||
                       (value[0] === 1'bx) || (value[0] === 1'bz)) ? 1'bx : value[1];
    assign invariant = below === expected;
endmodule
'@
$sequential = @'
module lane(input logic clk, input logic [1:0] d, output logic [1:0] q);
    always_ff @(posedge clk) begin q <= d; end
    p_history: assert property (@(posedge clk) q === $past(d));
    c_zx: cover property (@(posedge clk) (d === 2'bzx) |=> (q === 2'bzx));
endmodule
module wrap(input logic clk, input logic [1:0] x, y, output logic [1:0] qx, qy);
    lane left(.clk(clk), .d(x), .q(qx));
    lane right(.clk(clk), .d(y), .q(qy));
endmodule
module nested_top(input logic clk, input logic [1:0] d, e, output logic [1:0] qx, qy);
    wrap box(.clk(clk), .x({d[0], d[1]}), .y(e), .qx(qx), .qy(qy));
    p_independent: assert property (@(posedge clk)
        ((d === 2'bxz) && (e === 2'bxz)) |=> ((qx === 2'bzx) && (qy === 2'bxz)));
endmodule
'@
$registered = @'
module only_state(input logic clk, input logic [1:0] d, output logic [1:0] q);
    always_ff @(posedge clk) begin q <= d; end
endmodule
module state_top(input logic clk, input logic [1:0] d, output logic [1:0] q);
    only_state register(.clk(clk), .d(d), .q(q));
endmodule
'@
function Fixture($Name, $Top, $Source) {
    $Source | Set-Content -LiteralPath "$root/$Name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2',('top ' + $Top),('source systemverilog "{0}.sv"' -f $Name),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath "$root/$Name.q3a" -Encoding utf8NoBOM
}
Fixture comb signed_top $combinational
Fixture seq nested_top $sequential
Fixture output state_top $registered
Fixture bad-child signed_top $combinational.Replace('input logic signed','input bit signed')
Fixture derived-clock nested_top $sequential.Replace('wrap box(.clk(clk),','wrap box(.clk(~clk),')
Fixture wrong-width state_top $registered.Replace('module state_top(input logic clk, input logic [1:0] d, output logic [1:0] q);',
    'module state_top(input logic clk, input logic [1:0] d, output logic [2:0] q);')

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $ExpectedStatus, [int]$Code, [string[]]$Arguments) {
    $raw = @(& $exe @Arguments 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $value = $raw | ConvertFrom-Json
    if ($actual -ne $Code -or $value.exit_code -ne $Code -or $value.status -cne $ExpectedStatus) {
        throw "$Name expected $ExpectedStatus/$Code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $value
}
function Check-Proof($Name, $ExpectedStatus, $Kind, [string[]]$Options, $Path) {
    $proved = Run "prove-$Name" $ExpectedStatus 0 (@('dev-prove-four-state') + $Options)
    $checked = Run "verify-$Name" REVALIDATED 0 (@('dev-verify-four-state') + $Options)
    $lines = @(& $checker --check-drat "$Path/query.cnf" "$Path/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind $Kind)
    if ($LASTEXITCODE -ne 0 -or $lines -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $checked.proof_sha256 -cne $proved.proof_sha256 -or $checked.proof_sha256 -cne (Hash "$Path/proof.q3adrat")) {
        throw "Hierarchy certificate did not revalidate for $Name."
    }
    $lines | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

foreach ($case in @(@{bits='11'; expected='1'},@{bits='01'; expected='0'},@{bits='1z'; expected='x'})) {
    $value = Run "eval-$($case.bits)" EVALUATED 0 @('dev-eval-four-state',"$root/comb.q3a",'--input','value',$case.bits)
    if ($value.signals.below -cne $case.expected -or $value.signals.invariant -cne '1') {
        throw 'A nested signed formal lost its declared interpretation.'
    }
}
$path = "$root/proof-comb"
$proofs = [ordered]@{ signed = Check-Proof signed PROVEN four-state-exact @("$root/comb.q3a",
    '--expect','invariant','1','--evidence-dir',$path) $path }
$path = "$root/proof-initial"
$proofs.initial = Check-Proof initial BOUNDED_PASS four-state-sampled-exact @("$root/output.q3a",
    '--expect','q','xx','--evidence-dir',$path,'--steps','0') $path

$base = @("$root/seq.q3a",'--property')
foreach ($name in 'box.left.p_history','box.right.p_history','p_independent') {
    $path = "$root/proof-$name"
    $proofs[$name] = Check-Proof $name BOUNDED_PASS four-state-sampled-sva ($base + @(
        $name,'--evidence-dir',$path,'--steps','2')) $path
}
$path = "$root/nested-witness"
$opts = $base + @('box.left.c_zx','--evidence-dir',$path,'--steps','1')
$hit = Run hit COVERED 0 (@('dev-prove-four-state') + $opts)
$replay = Run replay COVERED 0 (@('dev-verify-four-state') + $opts + @('--vcd',"$root/nested.vcd"))
if (!$replay.witness_revalidated -or $replay.witness_sha256 -cne $hit.witness_sha256 -or
    $replay.trace[0].d -cne 'xz' -or $replay.trace[1].qx -cne 'zx' -or
    $replay.vcd_sha256 -cne (Hash "$root/nested.vcd")) {
    throw 'The nested four-state witness failed source replay.'
}
$wave = & $exe trace import-vcd "$root/nested.vcd" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or !$wave.four_state -or !(($wave.signals | Where-Object {
    ($_.scope -join '.') -ceq 'nested_top.box.left'
}) | Select-Object -First 1)) {
    throw 'The exported waveform lost the nested RTL scope.'
}

$null = Run bad-child REJECTED 2 @('dev-eval-four-state',"$root/bad-child.q3a",'--input','value','00')
if ((Get-Content "$root/bad-child.stderr.txt" -Raw) -notmatch 'must use logic: signed_leaf') {
    throw 'The frontend failed to check an instantiated child signal type.'
}
$null = Run derived-clock REJECTED 2 @('dev-prove-four-state',"$root/derived-clock.q3a",'--property',
    'p_independent','--evidence-dir',"$root/no-derived",'--steps','1')
if ((Get-Content "$root/derived-clock.stderr.txt" -Raw) -notmatch 'clock must connect directly') {
    throw 'The derived hierarchical clock did not fail with the expected diagnostic.'
}
$null = Run wrong-width REJECTED 2 @('dev-prove-four-state',"$root/wrong-width.q3a",'--expect','q','xxx',
    '--evidence-dir',"$root/no-width",'--steps','0')
if ((Get-Content "$root/wrong-width.stderr.txt" -Raw) -notmatch 'width') { throw 'A hierarchical width mismatch did not fail closed.' }

[ordered]@{
    status = 'FOUR_STATE_HIERARCHY_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
    vcd_sha256 = $replay.vcd_sha256
    rejected_cases = 3
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: five hierarchical certificates, nested X/Z history and waveform replay, and three targeted rejections.'
