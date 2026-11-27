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
$comb = @'
module relay_bit(input logic i, output logic o);
    assign o = i;
endmodule
module indexed_demo(
    input logic [7:4] descending,
    input logic [4:7] ascending,
    input logic [1:-2] signed_range,
    input logic signed [3:0] idx,
    input logic [3:0] unsigned_idx,
    input logic [63:0] wide_idx,
    output logic d, a, signed_read, unsigned_read, wide_read, relayed, invalid_constant, unknown_constant, invariant
);
    logic expected;
    assign d = descending[idx];
    always_comb begin a = ascending[idx]; end
    assign signed_read = signed_range[idx];
    assign unsigned_read = signed_range[unsigned_idx];
    assign wide_read = descending[wide_idx];
    assign invalid_constant = descending[4'd8];
    assign unknown_constant = descending[4'bx1z0];
    relay_bit child(.i(descending[idx]), .o(relayed));
    assign expected = (idx === 4'd4) ? descending[4] :
                      (idx === 4'd5) ? descending[5] :
                      (idx === 4'd6) ? descending[6] :
                      (idx === 4'd7) ? descending[7] : 1'bx;
    assign invariant = (d === expected) && (relayed === expected);
endmodule
'@
$sampled = @'
module sampled_index(input logic clk, input logic [3:0] data, input logic [2:0] idx);
    logic q;
    always_ff @(posedge clk) begin q <= data[idx]; end
    p_bad_index: assert property (@(posedge clk)
        ((idx === 3'b100) || (idx === 3'b0x1) || (idx === 3'b1z0)) |=> (q === 1'bx));
    p_direct: assert property (@(posedge clk) (idx === 3'b100) |-> (data[idx] === 1'bx));
    c_preserve_z: cover property (@(posedge clk)
        ((idx === 3'b010) && (data === 4'b0z10)) |=> (q === 1'bz));
endmodule
'@
function Fixture($Name, $Top, $Source) {
    $Source | Set-Content -LiteralPath "$root/$Name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2',('top ' + $Top),('source systemverilog "{0}.sv"' -f $Name),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath "$root/$Name.q3a" -Encoding utf8NoBOM
}
Fixture indexed indexed_demo $comb
Fixture sampled sampled_index $sampled
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
        throw "Selector certificate did not revalidate for $Name."
    }
    $lines | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

$known = ('0' * 61) + '101'
$large = '1' + ('0' * 63)
$cases = @(
    @{id='descending-right'; idx='0100'; unsigned='0000'; wide=$known; expect=@('0','z','x','1','x')},
    @{id='descending-left'; idx='0111'; unsigned='0001'; wide=(('0' * 61) + '111'); expect=@('z','0','x','z','z')},
    @{id='negative'; idx='1110'; unsigned='1110'; wide=$large; expect=@('x','x','0','x','x')},
    @{id='signed-z'; idx='0001'; unsigned='0001'; wide=$known; expect=@('x','x','z','z','x')},
    @{id='unknown'; idx='x101'; unsigned='0z01'; wide=('z' + ('0' * 63)); expect=@('x','x','x','x','x')}
)
$signals = @('d','a','signed_read','unsigned_read','wide_read')
foreach ($case in $cases) {
    $value = Run "eval-$($case.id)" EVALUATED 0 @('dev-eval-four-state',"$root/indexed.q3a",
        '--input','descending','z1x0','--input','ascending','z1x0','--input','signed_range','z1x0',
        '--input','idx',$case.idx,'--input','unsigned_idx',$case.unsigned,'--input','wide_idx',$case.wide)
    for ($bit = 0; $bit -lt $signals.Count; ++$bit) {
        $signal = $signals[$bit]
        if ($value.signals.$signal -cne $case.expect[$bit]) {
            throw "Incorrect $signal on $($case.id). Expected $($case.expect[$bit]), got $($value.signals.$signal)."
        }
    }
    if ($value.signals.invalid_constant -cne 'x' -or $value.signals.unknown_constant -cne 'x' -or
        $value.signals.invariant -cne '1' -or $value.signals.relayed -cne $case.expect[0]) {
        throw "Constant or hierarchical bit-select mismatch in $($case.id)."
    }
}
$path = "$root/comb-proof"
$proofs = [ordered]@{ combinational = Check-Proof combinational PROVEN four-state-exact @("$root/indexed.q3a",
    '--expect','invariant','1','--evidence-dir',$path) $path }
$base = @("$root/sampled.q3a",'--property')
$path = "$root/sampled-proof"
$proofs.sampled = Check-Proof sampled BOUNDED_PASS four-state-sampled-sva ($base + @(
    'p_bad_index','--evidence-dir',$path,'--steps','2')) $path
$path = "$root/direct-proof"
$proofs.direct = Check-Proof direct BOUNDED_PASS four-state-sampled-sva ($base + @(
    'p_direct','--evidence-dir',$path,'--steps','0')) $path
$path = "$root/z-witness"
$options = $base + @('c_preserve_z','--evidence-dir',$path,'--steps','1')
$hit = Run hit COVERED 0 (@('dev-prove-four-state') + $options)
$replay = Run replay COVERED 0 (@('dev-verify-four-state') + $options)
if (!$replay.witness_revalidated -or $replay.witness_sha256 -cne $hit.witness_sha256 -or
    $replay.trace[1].q -cne 'z' -or $replay.witness_sha256 -cne (Hash "$path/cover.q3awitness")) {
    throw 'A selected Z bit did not independently replay.'
}

[ordered]@{
    status = 'FOUR_STATE_INDEXED_BITS_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    directed_cases = $cases.Count
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: variable bit reads, ascending and signed ranges, invalid index values, nested ports, three certificates and sampled Z replay.'
