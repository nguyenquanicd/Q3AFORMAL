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

$symbols = '0','1','x','z'
$words = foreach ($hi in $symbols) { foreach ($lo in $symbols) { "$hi$lo" } }
function Compare-Casex($A, $B) {
    for ($bit = 0; $bit -lt $A.Length; $bit++) {
        if (($A[$bit] -in '0','1') -and ($B[$bit] -in '0','1') -and $A[$bit] -cne $B[$bit]) {
            return '0'
        }
    }
    '1'
}
$rows = foreach ($a in $words) {
    foreach ($b in $words) { "4'b$a${b}: expected = 1'b$(Compare-Casex $a $b);" }
}
@"
module decode(input logic [1:0] a, b,
    output logic [1:0] exact_choice, z_choice, x_choice,
    output logic dynamic_match, signed_match, mixed_match, oracle);
    logic signed [1:0] sa;
    logic expected;
    assign sa = a;
    always_comb begin
        case (a)
            2'b00, 2'b01: exact_choice = 2'd1;
            2'b1x: exact_choice = 2'd2;
            default: exact_choice = 2'd3;
        endcase
        casez (a)
            2'b00, 2'b01: z_choice = 2'd1;
            2'b1x: z_choice = 2'd2;
            default: z_choice = 2'd3;
        endcase
        casex (a)
            2'b00, 2'b01: x_choice = 2'd1;
            2'b1x: x_choice = 2'd2;
            default: x_choice = 2'd3;
        endcase
        casex (a)
            b: dynamic_match = 1'b1;
            default: dynamic_match = 1'b0;
        endcase
        casex (sa)
            4'sb11x1: signed_match = 1'b1;
            default: signed_match = 1'b0;
        endcase
        casex (sa)
            4'b00x1: mixed_match = 1'b1;
            default: mixed_match = 1'b0;
        endcase
        case ({a,b})
            $($rows -join "`n            ")
            default: expected = 1'b0;
        endcase
    end
    assign oracle = dynamic_match === expected;
endmodule
"@ | Set-Content -LiteralPath "$root/decode.sv" -Encoding utf8NoBOM
@'
module sampled(input logic clk, input logic [1:0] d);
    logic [1:0] q;
    always_ff @(posedge clk) begin
        casex (d)
            2'b0x: q <= 2'd1;
        endcase
    end
    p_pick: assert property (@(posedge clk) (d === 2'bxz) |=> (q === 2'd1));
    c_hold: cover property (@(posedge clk) (d === 2'b11) |=> (q === 2'bxx));
endmodule
'@ | Set-Content -LiteralPath "$root/sampled.sv" -Encoding utf8NoBOM
foreach ($name in 'decode','sampled') {
    @('Q3AFORMAL_PROJECT 2',"top $name",('source systemverilog "{0}.sv"' -f $name),$profile) |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
}

foreach ($case in @(
    @{ id='selector-x'; a='x0'; b='00'; choices='111101' },
    @{ id='selector-z'; a='1z'; b='10'; choices='111010' },
    @{ id='binary'; a='11'; b='11'; choices='111110' }
)) {
    $result = Run $case.id EVALUATED 0 @('dev-eval-four-state',"$root/decode.q3a",'--input','a',$case.a,'--input','b',$case.b)
    $f = $result.signals
    if (($f.exact_choice + $f.z_choice + $f.x_choice) -cne $case.choices -or $f.oracle -cne '1') {
        throw "Case selection or priority differs for $($case.id)."
    }
    if ($case.id -ceq 'binary' -and ($f.signed_match + $f.mixed_match) -cne '11') {
        throw 'Case context did not correctly extend signed or mixed operands.'
    }
}

$proofs = [ordered]@{}
foreach ($case in @(
    @{ name='oracle'; status='PROVEN'; kind='four-state-exact';
        args=@("$root/decode.q3a",'--expect','oracle','1','--evidence-dir',"$root/oracle") },
    @{ name='priority'; status='BOUNDED_PASS'; kind='four-state-sampled-sva';
        args=@("$root/sampled.q3a",'--property','p_pick','--evidence-dir',"$root/priority",'--steps','1') }
)) {
    $name = $case.name
    $proof = Run "$name-proof" $case.status 0 (@('dev-prove-four-state') + $case.args)
    $reopened = Run "$name-reopen" REVALIDATED 0 (@('dev-verify-four-state') + $case.args)
    $out = @(& $checker --check-drat "$root/$name/query.cnf" "$root/$name/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $case.kind)
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) {
        throw "Independent certificate check failed for $name."
    }
    $out | Set-Content -LiteralPath "$root/$name-checker.txt" -Encoding utf8NoBOM
    $proofs[$name] = $proof.proof_sha256
}
$options = @("$root/sampled.q3a",'--property','c_hold','--evidence-dir',"$root/hold",'--steps','1')
$hit = Run cover COVERED 0 (@('dev-prove-four-state') + $options)
$replay = Run cover-replay COVERED 0 (@('dev-verify-four-state') + $options)
if (!$replay.witness_revalidated -or $hit.witness_sha256 -cne $replay.witness_sha256 -or
    $replay.trace[0].d -cne '11' -or $replay.trace[1].q -cne 'xx') {
    throw 'Sequential no-match hold did not revalidate from source.'
}
@('Q3AFORMAL_PROJECT 2','top sampled','source systemverilog "sampled.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notlike '*casex requires the four-state*') {
    throw 'Baseline grammar did not reject casex.'
}
[ordered]@{
    status = 'FOUR_STATE_CASEX_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/decode.sv"
    oracle_input_pairs = $rows.Count
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: case, casez and casex priority, 256 dynamic patterns, signed sizing, certificates and hold replay.'
