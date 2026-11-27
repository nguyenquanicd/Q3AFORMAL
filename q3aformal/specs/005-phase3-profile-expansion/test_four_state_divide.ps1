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

function Expected([int]$A, [int]$B) {
    if ($B -eq 0) { return 'xxxxxxxxxxxxxxxx' }
    $sa = if ($A -ge 2) { $A - 4 } else { $A }
    $sb = if ($B -ge 2) { $B - 4 } else { $B }
    $uq = [int][Math]::Truncate($A / $B)
    $sq = [int][Math]::Truncate($sa / $sb)
    (Bits $uq 4) + (Bits ($A - $uq * $B) 4) + (Bits $sq 4) + (Bits ($sa - $sq * $sb) 4)
}
$rows = foreach ($a in 0..3) {
    foreach ($b in 0..3) {
        "4'b$(Bits (($a -shl 2) -bor $b) 4): expected = 16'b$(Expected $a $b);"
    }
}
@"
module division_demo(input logic [1:0] a, b,
    output logic [3:0] uq, ur, mixed, zero,
    output logic signed [3:0] sq, sr,
    output logic [63:0] overflow, negative_remainder,
    output logic oracle);
    logic signed [1:0] sa, sb;
    logic [15:0] expected;
    assign sa = a;
    assign sb = b;
    assign uq = a / b;
    assign ur = a % b;
    assign sq = sa / sb;
    assign sr = sa % sb;
    assign mixed = sa / b;
    assign zero = a / 4'd0;
    assign overflow = 64'sh8000000000000000 / -64'sd1;
    assign negative_remainder = 64'sh8000000000000001 % 64'sd2;
    always_comb begin
        case ({a,b})
            $($rows -join "`n            ")
            default: expected = 16'bxxxxxxxxxxxxxxxx;
        endcase
    end
    assign oracle = {uq,ur,sq,sr} === expected;
endmodule
"@ | Set-Content -LiteralPath "$root/division.sv" -Encoding utf8NoBOM
@'
module sample_division(input logic clk, input logic [3:0] dividend, divisor);
    logic [3:0] q, r;
    always_ff @(posedge clk) begin
        q <= dividend / divisor;
        r <= dividend % divisor;
    end
    p_good: assert property (@(posedge clk)
        ((dividend === 4'd5) && (divisor === 4'd3)) |=> ((q === 4'd1) && (r === 4'd2)));
    p_bad: assert property (@(posedge clk)
        ((dividend === 4'd5) && (divisor === 4'd3)) |=> (r === 4'd1));
    c_zero: cover property (@(posedge clk)
        ((dividend === 4'd5) && (divisor === 4'd0)) |=> ((q === 4'bxxxx) && (r === 4'bxxxx)));
    c_bound: cover property (@(posedge clk) 1'b1 ##(6/3) 1'b1);
endmodule
'@ | Set-Content -LiteralPath "$root/sampled.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top division_demo','source systemverilog "division.sv"',$profile) |
    Set-Content -LiteralPath "$root/division.q3a" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top sample_division','source systemverilog "sampled.sv"',$profile) |
    Set-Content -LiteralPath "$root/sampled.q3a" -Encoding utf8NoBOM

foreach ($a in 0..3) {
    foreach ($b in 0..3) {
        $result = Run "known-$a-$b" EVALUATED 0 @('dev-eval-four-state',"$root/division.q3a",
            '--input','a',(Bits $a 2),'--input','b',(Bits $b 2))
        $f = $result.signals
        if (($f.uq + $f.ur + $f.sq + $f.sr) -cne (Expected $a $b) -or
            $f.mixed -cne $f.uq -or $f.zero -cne 'xxxx' -or
            $f.overflow -cne ('1' + ('0' * 63)) -or $f.negative_remainder -cne ('1' * 64)) {
            throw "Packed arithmetic differs for inputs $a and $b."
        }
    }
}
foreach ($case in @(
    @{ id='unknown-dividend'; a='x1'; b='01' },
    @{ id='high-impedance-divisor'; a='11'; b='1z' }
)) {
    $result = Run $case.id EVALUATED 0 @('dev-eval-four-state',"$root/division.q3a",
        '--input','a',$case.a,'--input','b',$case.b)
    $f = $result.signals
    if (($f.uq + $f.ur + $f.sq + $f.sr) -cne ('x' * 16)) {
        throw "An indeterminate operand produced a known result for $($case.id)."
    }
}

$proofs = [ordered]@{}
foreach ($case in @(
    @{ name='oracle'; status='PROVEN'; kind='four-state-exact';
        args=@("$root/division.q3a",'--expect','oracle','1','--evidence-dir',"$root/oracle") },
    @{ name='sampled-proof'; status='BOUNDED_PASS'; kind='four-state-sampled-sva';
        args=@("$root/sampled.q3a",'--property','p_good','--evidence-dir',"$root/sampled-proof",'--steps','1') }
)) {
    $name = $case.name
    $proof = Run "$name-prove" $case.status 0 (@('dev-prove-four-state') + $case.args)
    $reopened = Run "$name-reopen" REVALIDATED 0 (@('dev-verify-four-state') + $case.args)
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $case.kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) { throw "Invalid certificate for $name." }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}
$argsCover = @("$root/sampled.q3a",'--property','c_zero','--evidence-dir',"$root/cover",'--steps','1')
$hit = Run cover COVERED 0 (@('dev-prove-four-state') + $argsCover)
$replay = Run cover-replay COVERED 0 (@('dev-verify-four-state') + $argsCover)
$bad = Run counterexample COUNTEREXAMPLE 0 @('dev-prove-four-state',"$root/sampled.q3a",
    '--property','p_bad','--evidence-dir',"$root/failed",'--steps','1')
$bound = Run constant-bound COVERED 0 @('dev-prove-four-state',"$root/sampled.q3a",
    '--property','c_bound','--evidence-dir',"$root/bound",'--steps','2')
if (!$replay.witness_revalidated -or $replay.witness_sha256 -cne $hit.witness_sha256 -or
    $replay.trace[0].divisor -cne '0000' -or $replay.trace[1].q -cne 'xxxx' -or $replay.trace[1].r -cne 'xxxx' -or
    !$bad.source_replayed -or $bad.trace[1].r -cne '0010' -or $bound.match_sample -ne 2) {
    throw 'The sampled unknown, arithmetic counterexample or a constant bound did not replay.'
}

@('Q3AFORMAL_PROJECT 2','top sample_division','source systemverilog "sampled.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or !(Get-Content "$root/baseline.stderr.txt" -Raw).Contains("operator '/'")) {
    throw 'Baseline profile did not reject division.'
}
(Get-Content "$root/sampled.sv" -Raw).Replace('6/3','6/0') | Set-Content "$root/zero-delay.sv" -Encoding utf8NoBOM
(Get-Content "$root/sampled.q3a" -Raw).Replace('sampled.sv','zero-delay.sv') | Set-Content "$root/zero-delay.q3a" -Encoding utf8NoBOM
$null = Run zero-delay REJECTED 2 @('dev-prove-four-state',"$root/zero-delay.q3a",
    '--property','c_bound','--evidence-dir',"$root/invalid-delay",'--steps','2')
if ((Get-Content "$root/zero-delay.stderr.txt" -Raw) -notlike '*division by zero in constant bound*') {
    throw 'A zero divisor in a delay did not produce the expected source diagnostic.'
}

[ordered]@{
    status = 'FOUR_STATE_DIVISION_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/division.sv"
    oracle_input_pairs = 256
    directed_evaluations = 18
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
    counterexample_sample = $bad.failure_sample
    constant_bound_sample = $bound.match_sample
    rejected_cases = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: packed division and remainder over 256 four-state input pairs, two checked certificates, signed overflow, and sampled replay.'
