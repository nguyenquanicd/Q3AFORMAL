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
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'

function Bits([int]$Value, [int]$Width) {
    [Convert]::ToString($Value -band ((1 -shl $Width) - 1), 2).PadLeft($Width, '0')
}
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Id, $Status, [int]$Code, [string[]]$Arguments) {
    $raw = & $exe @Arguments 2> "$root/$Id.stderr.txt"
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($actual -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Id expected $Status/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

# Generate the independent 16-entry known-input oracle. Case matching sends
# the remaining 240 combinations of two packed four-state inputs to all X.
$rows = foreach ($a in 0..3) {
    foreach ($b in 0..3) {
        $sa = if ($a -ge 2) { $a - 4 } else { $a }
        $sb = if ($b -ge 2) { $b - 4 } else { $b }
        "4'b$(Bits (($a -shl 2) -bor $b) 4): expected = 12'b$(Bits ($a * $b) 4)$(Bits ($sa * $sb) 4)$(Bits ($a * $b) 4);"
    }
}
@"
module multiply_demo(
    input logic [1:0] a, b, input logic [63:0] w,
    output logic [3:0] u, m, precedence, zero,
    output logic signed [3:0] s,
    output logic [1:0] low,
    output logic [63:0] twice,
    output logic oracle
);
    logic signed [1:0] sa, sb;
    logic [11:0] expected;
    assign sa = a;
    assign sb = b;
    assign u = a * b;
    assign s = sa * sb;
    assign m = sa * b;
    assign low = a * b;
    assign precedence = 4'd1 + a * b;
    assign zero = a * 4'd0;
    assign twice = w * 64'd2;
    always_comb begin
        case ({a,b})
            $($rows -join "`n            ")
            default: expected = 12'bxxxxxxxxxxxx;
        endcase
    end
    assign oracle = {u,s,m} === expected;
endmodule
"@ | Set-Content -LiteralPath "$root/multiply.sv" -Encoding utf8NoBOM
@'
module product_demo(input logic clk, input logic [1:0] d);
    logic [3:0] q;
    always_ff @(posedge clk) begin q <= d * 4'd3; end
    p_good: assert property (@(posedge clk) (d === 2'b11) |=> (q === 4'd9));
    p_bad: assert property (@(posedge clk) (d === 2'b11) |=> (q === 4'd8));
    c_unknown: cover property (@(posedge clk) (d === 2'b1z) |=> (q === 4'bxxxx));
endmodule
'@ | Set-Content -LiteralPath "$root/product.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top multiply_demo','source systemverilog "multiply.sv"',$profile) |
    Set-Content -LiteralPath "$root/multiply.q3a" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top product_demo','source systemverilog "product.sv"',$profile) |
    Set-Content -LiteralPath "$root/product.q3a" -Encoding utf8NoBOM

foreach ($a in 0..3) {
    foreach ($b in 0..3) {
        $sa = if ($a -ge 2) { $a - 4 } else { $a }
        $sb = if ($b -ge 2) { $b - 4 } else { $b }
        $w = '1' + ('0' * 62) + '1'
        $r = Run "known-$a-$b" EVALUATED 0 @('dev-eval-four-state',"$root/multiply.q3a",
            '--input','a',(Bits $a 2),'--input','b',(Bits $b 2),'--input','w',$w)
        if ($r.signals.u -cne (Bits ($a * $b) 4) -or $r.signals.s -cne (Bits ($sa * $sb) 4) -or
            $r.signals.m -cne (Bits ($a * $b) 4) -or $r.signals.low -cne (Bits ($a * $b) 2) -or
            $r.signals.precedence -cne (Bits (1 + $a * $b) 4) -or $r.signals.twice -cne (('0' * 62) + '10')) {
            throw "Incorrect packed product for inputs $a and $b."
        }
    }
}
foreach ($case in @(
    @{ id = 'left-z-right-zero'; a = 'z1'; b = '00' },
    @{ id = 'left-zero-right-x'; a = '00'; b = '1x' }
)) {
    $r = Run $case.id EVALUATED 0 @('dev-eval-four-state',"$root/multiply.q3a",
        '--input','a',$case.a,'--input','b',$case.b,'--input','w',( ('0' * 63) + 'z'))
    if (($r.signals.u + $r.signals.s + $r.signals.m) -cne ('x' * 12) -or
        $r.signals.twice -cne ('x' * 64) -or ($case.a -ceq 'z1' -and $r.signals.zero -cne 'xxxx')) {
        throw "Incorrect propagation of X or Z for $($case.id)."
    }
}

$proofs = [ordered]@{}
foreach ($case in @(
    @{ name = 'oracle'; status = 'PROVEN'; kind = 'four-state-exact';
        options = @("$root/multiply.q3a",'--expect','oracle','1','--evidence-dir',"$root/oracle") },
    @{ name = 'sampled'; status = 'BOUNDED_PASS'; kind = 'four-state-sampled-sva';
        options = @("$root/product.q3a",'--property','p_good','--evidence-dir',"$root/sampled",'--steps','1') }
)) {
    $name = $case.name
    $proof = Run "$name-proof" $case.status 0 (@('dev-prove-four-state') + $case.options)
    $reopened = Run "$name-reopen" REVALIDATED 0 (@('dev-verify-four-state') + $case.options)
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $case.kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) { throw "Invalid certificate for $name." }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}
$cover = @("$root/product.q3a",'--property','c_unknown','--evidence-dir',"$root/cover",'--steps','1')
$hit = Run cover COVERED 0 (@('dev-prove-four-state') + $cover)
$replay = Run cover-replay COVERED 0 (@('dev-verify-four-state') + $cover)
$bad = Run counterexample COUNTEREXAMPLE 0 @('dev-prove-four-state',"$root/product.q3a",
    '--property','p_bad','--evidence-dir',"$root/failed",'--steps','1')
if (!$replay.witness_revalidated -or $hit.witness_sha256 -cne $replay.witness_sha256 -or
    $replay.trace[0].d -cne '1z' -or $replay.trace[1].q -cne 'xxxx' -or
    !$bad.source_replayed -or $bad.trace[0].d -cne '11' -or $bad.trace[1].q -cne '1001') {
    throw 'Multiplication cover or counterexample replay did not preserve the expected sample.'
}

@('Q3AFORMAL_PROJECT 2','top product_demo','source systemverilog "product.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notmatch "operator '\*'") {
    throw 'Baseline profile did not reject multiplication.'
}
[ordered]@{
    status = 'FOUR_STATE_MULTIPLICATION_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/multiply.sv"
    oracle_input_combinations = 256
    directed_evaluations = 18
    proof_sha256 = $proofs
    unknown_witness_sha256 = $replay.witness_sha256
    counterexample_sample = $bad.failure_sample
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: packed multiplication across 256 four-state pairs, signed sizing, truncation, 64-bit overflow, proof checks and source replay.'
