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
module relay_slice(input logic [2:0] d, output logic [2:0] q);
    assign q = d;
endmodule
module part_demo(
    input logic [7:4] d,
    input logic [4:7] a,
    input logic [1:-2] n,
    input logic [64'sd9223372036854775807:64'sd9223372036854775806] top_limit,
    input logic [63:0] wide,
    input logic [3:0] base,
    input logic signed [3:0] signed_base,
    output logic [2:0] d_plus, d_minus, a_plus, a_minus, signed_plus, unsigned_minus, relay,
    output logic [1:0] limit_slice,
    output logic invariant
);
    logic [2:0] expected, ascending_expected, descending_minus_expected;
    logic [1:0] limit_expected;
    assign d_plus = d[base +: 3];
    assign d_minus = d[base -: 3];
    assign a_plus = a[base +: 3];
    assign a_minus = a[base -: 3];
    assign signed_plus = n[signed_base +: 3];
    assign unsigned_minus = n[4'd0 -: 3];
    assign limit_slice = top_limit[wide -: 2];
    relay_slice child(.d(d[base +: 3]), .q(relay));
    always_comb begin
        case (base)
            4'd2: expected = {d[4], 2'bxx};
            4'd3: expected = {d[5:4], 1'bx};
            4'd4: expected = d[6:4];
            4'd5: expected = d[7:5];
            4'd6: expected = {1'bx, d[7:6]};
            4'd7: expected = {2'bxx, d[7]};
            default: expected = 3'bxxx;
        endcase
    end
    always_comb begin
        case (base)
            4'd2: ascending_expected = {2'bxx, a[4]};
            4'd3: ascending_expected = {1'bx, a[4:5]};
            4'd4: ascending_expected = a[4:6];
            4'd5: ascending_expected = a[5:7];
            4'd6: ascending_expected = {a[6:7], 1'bx};
            4'd7: ascending_expected = {a[7], 2'bxx};
            default: ascending_expected = 3'bxxx;
        endcase
        case (base)
            4'd4: descending_minus_expected = {d[4], 2'bxx};
            4'd5: descending_minus_expected = {d[5:4], 1'bx};
            4'd6: descending_minus_expected = d[6:4];
            4'd7: descending_minus_expected = d[7:5];
            4'd8: descending_minus_expected = {1'bx, d[7:6]};
            4'd9: descending_minus_expected = {2'bxx, d[7]};
            default: descending_minus_expected = 3'bxxx;
        endcase
        case (wide)
            64'h7ffffffffffffffe: limit_expected = {top_limit[64'sd9223372036854775806], 1'bx};
            64'h7fffffffffffffff: limit_expected = top_limit;
            64'h8000000000000000: limit_expected = {1'bx, top_limit[64'sd9223372036854775807]};
            default: limit_expected = 2'bxx;
        endcase
    end
    assign invariant = (d_plus === expected) && (relay === expected) &&
        (a_plus === ascending_expected) && (d_minus === descending_minus_expected) &&
        (limit_slice === limit_expected);
endmodule
'@
$sampled = @'
module sampled_part(input logic clk, input logic [7:4] d, input logic [3:0] base);
    logic [2:0] q;
    always_ff @(posedge clk) begin q <= d[base +: 3]; end
    p_partial: assert property (@(posedge clk)
        (base === 4'd6) |=> (q === {1'bx, $past(d[7:6])}));
    p_direct: assert property (@(posedge clk)
        (base === 4'd8) |-> (d[base +: 3] === 3'bxxx));
    c_z: cover property (@(posedge clk) ((base === 4'd6) && (d === 4'bz100)) |=> (q === 3'bxz1));
endmodule
'@
function Fixture($Name, $Top, $Source) {
    $Source | Set-Content -LiteralPath "$root/$Name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2',('top ' + $Top),('source systemverilog "{0}.sv"' -f $Name),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath "$root/$Name.q3a" -Encoding utf8NoBOM
}
Fixture indexed part_demo $comb
Fixture sampled sampled_part $sampled
Fixture width-zero part_demo ($comb.Replace('assign d_plus = d[base +: 3];','assign d_plus = d[base +: 0];'))
Fixture width-variable part_demo ($comb.Replace('assign d_plus = d[base +: 3];','assign d_plus = d[base +: signed_base];'))

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
        throw "Indexed slice certificate did not revalidate for $Name."
    }
    $lines | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

$inputs = @('--input','d','z1x0','--input','a','z1x0','--input','n','z1x0',
    '--input','top_limit','z1','--input','wide',('1' + ('0' * 63)),'--input','signed_base','1110')
$cases = @(
    @{id='inside'; base='0101'; expected=@('z1x','x0x','1x0','xz1')},
    @{id='partial'; base='0110'; expected=@('xz1','1x0','x0x','z1x')},
    @{id='below'; base='0011'; expected=@('x0x','xxx','xz1','xxx')},
    @{id='above'; base='1000'; expected=@('xxx','xz1','xxx','x0x')},
    @{id='unknown'; base='0z01'; expected=@('xxx','xxx','xxx','xxx')}
)
$names = @('d_plus','d_minus','a_plus','a_minus')
foreach ($entry in $cases) {
    $result = Run "eval-$($entry.id)" EVALUATED 0 (@('dev-eval-four-state',"$root/indexed.q3a",
        '--input','base',$entry.base) + $inputs)
    for ($index = 0; $index -lt $names.Count; ++$index) {
        $name = $names[$index]
        if ($result.signals.$name -cne $entry.expected[$index]) {
            throw "Wrong $name for $($entry.id): got $($result.signals.$name), expected $($entry.expected[$index])."
        }
    }
    if ($result.signals.invariant -cne '1' -or $result.signals.relay -cne $entry.expected[0] -or
        $result.signals.signed_plus -cne '1x0' -or $result.signals.unsigned_minus -cne '1x0' -or
        $result.signals.limit_slice -cne 'xz') { throw 'A hierarchical, signed or 64-bit-boundary slice was incorrect.' }
}
$proofs = [ordered]@{}
$path = "$root/comb-proof"
$proofs.comb = Check-Proof comb PROVEN four-state-exact @("$root/indexed.q3a",
    '--expect','invariant','1','--evidence-dir',$path) $path
$base = @("$root/sampled.q3a",'--property')
foreach ($name in 'p_partial','p_direct') {
    $path = "$root/proof-$name"
    $proofs[$name] = Check-Proof $name BOUNDED_PASS four-state-sampled-sva ($base + @(
        $name,'--evidence-dir',$path,'--steps','1')) $path
}
$path = "$root/witness"
$options = $base + @('c_z','--evidence-dir',$path,'--steps','1')
$hit = Run hit COVERED 0 (@('dev-prove-four-state') + $options)
$replay = Run replay COVERED 0 (@('dev-verify-four-state') + $options)
if (!$replay.witness_revalidated -or $replay.witness_sha256 -cne $hit.witness_sha256 -or
    $replay.trace[1].q -cne 'xz1' -or $replay.witness_sha256 -cne (Hash "$path/cover.q3awitness")) {
    throw 'A partially out-of-range slice witness did not preserve its valid Z bit.'
}
foreach ($name in 'width-zero','width-variable') {
    $null = Run $name REJECTED 2 (@('dev-eval-four-state',"$root/$name.q3a",'--input','base','0000') + $inputs)
    if ((Get-Content "$root/$name.stderr.txt" -Raw) -notmatch 'width must be 1..64|bounds must be supported constant expressions') {
        throw "Incorrect invalid slice-width diagnostic for $name."
    }
}
[ordered]@{
    status = 'FOUR_STATE_INDEXED_PARTS_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    directed_cases = $cases.Count
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
    rejected_width_cases = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: indexed slices in both directions, partial X fill, signed and 64-bit bases, child inputs, three certificates and a Z witness.'
