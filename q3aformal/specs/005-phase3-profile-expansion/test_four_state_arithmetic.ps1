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

@'
module arithmetic_demo(
    input logic signed [1:0] a,
    input logic signed [3:0] b,
    input logic [3:0] u,
    input logic [63:0] wide,
    output logic signed [3:0] sum, diff,
    output logic signed [1:0] neg,
    output logic [3:0] signed_order, mixed_order,
    output logic [63:0] wide_sum,
    output logic invariant
);
    assign sum = a + b;
    assign diff = a - b;
    assign neg = -a;
    assign signed_order = {a < b, a > b, a <= b, a >= b};
    assign mixed_order = {a < u, a > u, a <= u, a >= u};
    assign wide_sum = wide + 64'd1;
    assign invariant = ((sum - b) === (a + 4'sd0)) || ((b ^ b) !== 4'b0000);
endmodule
'@ | Set-Content -LiteralPath "$root/arithmetic.sv" -Encoding utf8NoBOM
@'
module counter_demo(input logic clk, input logic [3:0] d);
    logic [3:0] q;
    always_ff @(posedge clk) begin q <= d + 4'd1; end
    p_wrap: assert property (@(posedge clk) (d === 4'hf) |=> (q === 4'd0));
    p_growth: assert property (@(posedge clk) (d < 4'hf) |=> (q > 4'd0));
    p_bad: assert property (@(posedge clk) (d === 4'hf) |=> (q > 4'd0));
    c_unknown: cover property (@(posedge clk) (d === 4'b1z01) |=> (q === 4'bxxxx));
endmodule
'@ | Set-Content -LiteralPath "$root/counter.sv" -Encoding utf8NoBOM
foreach ($case in @(@{id='arithmetic'; top='arithmetic_demo'},@{id='counter'; top='counter_demo'})) {
    @('Q3AFORMAL_PROJECT 2',('top ' + $case.top),('source systemverilog "{0}.sv"' -f $case.id),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
        Set-Content -LiteralPath "$root/$($case.id).q3a" -Encoding utf8NoBOM
}

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
    $records = @(& $checker --check-drat "$Path/query.cnf" "$Path/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind $Kind)
    if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proved.proof_sha256 -cne $checked.proof_sha256 -or $checked.proof_sha256 -cne (Hash "$Path/proof.q3adrat")) {
        throw "Arithmetic certificate did not revalidate for $Name."
    }
    $records | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

$cases = @(
    @{id='wrap'; a='11'; b='0001'; u='0001'; wide=('1' * 64);
        sum='0000'; diff='1110'; neg='01'; signed_order='1010'; mixed_order='0101'; wide_sum=('0' * 64)},
    @{id='equal'; a='10'; b='1110'; u='0010'; wide=('0' + ('1' * 63));
        sum='1100'; diff='0000'; neg='10'; signed_order='0011'; mixed_order='0011'; wide_sum=('1' + ('0' * 63))},
    @{id='z'; a='1z'; b='0001'; u='0001'; wide=(('0' * 32) + 'z' + ('0' * 31));
        sum='xxxx'; diff='xxxx'; neg='xx'; signed_order='xxxx'; mixed_order='xxxx'; wide_sum=('x' * 64)},
    @{id='x'; a='01'; b='1x00'; u='0001'; wide=('0' * 64);
        sum='xxxx'; diff='xxxx'; neg='11'; signed_order='xxxx'; mixed_order='0011'; wide_sum=(('0' * 63) + '1')}
)
foreach ($case in $cases) {
    $evaluated = Run "eval-$($case.id)" EVALUATED 0 @('dev-eval-four-state',"$root/arithmetic.q3a",
        '--input','a',$case.a,'--input','b',$case.b,'--input','u',$case.u,'--input','wide',$case.wide)
    foreach ($output in 'sum','diff','neg','signed_order','mixed_order','wide_sum') {
        if ($evaluated.signals.$output -cne $case[$output]) { throw "Incorrect $output in $($case.id)." }
    }
}

$proofs = [ordered]@{}
$path = "$root/equiv-proof"
$proofs.invariant = Check-Proof invariant PROVEN four-state-exact @("$root/arithmetic.q3a",
    '--expect','invariant','1','--evidence-dir',$path) $path
$base = @("$root/counter.q3a",'--property')
foreach ($name in 'p_wrap','p_growth') {
    $path = "$root/proof-$name"
    $proofs[$name] = Check-Proof $name BOUNDED_PASS four-state-sampled-sva ($base + @(
        $name,'--evidence-dir',$path,'--steps','1')) $path
}
$path = "$root/xz-witness"
$options = $base + @('c_unknown','--evidence-dir',$path,'--steps','1')
$hit = Run covered COVERED 0 (@('dev-prove-four-state') + $options)
$replayed = Run replayed COVERED 0 (@('dev-verify-four-state') + $options)
if ($hit.trace[0].d -cne '1z01' -or $hit.trace[1].q -cne 'xxxx' -or !$replayed.witness_revalidated -or
    $hit.witness_sha256 -cne $replayed.witness_sha256) { throw 'Unknown arithmetic witness did not replay.' }
$bad = Run counterexample COUNTEREXAMPLE 0 (@('dev-prove-four-state') + $base + @(
    'p_bad','--evidence-dir',"$root/no-proof",'--steps','1'))
if (!$bad.source_replayed -or $bad.trace[0].d -cne '1111' -or $bad.trace[1].q -cne '0000') {
    throw 'The wraparound counterexample did not independently replay.'
}

[ordered]@{
    status = 'FOUR_STATE_ARITHMETIC_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    directed_cases = $cases.Count
    proof_sha256 = $proofs
    witness_sha256 = $replayed.witness_sha256
    counterexample_replayed = $true
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: signed, mixed-sign, X/Z and 64-bit arithmetic, three checked proofs, one reopened cover and one replayed counterexample.'
