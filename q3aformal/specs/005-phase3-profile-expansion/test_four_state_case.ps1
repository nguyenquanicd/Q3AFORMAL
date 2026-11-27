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
module case_demo(input logic [1:0] sel, output logic [1:0] plain, w,
    output logic predicate, output logic invariant);
    logic [1:0] plain_ref, wildcard_ref;
    always_comb begin
        case (sel)
            2'bx1: plain = 2'b01;
            2'bz1, 2'b11: plain = 2'b10;
            default: plain = 2'b00;
        endcase
        casez (sel)
            2'b01: w = 2'b00;
            2'b?1: w = 2'b01;
            2'bx0: w = 2'b10;
            default: w = 2'b11;
        endcase
        if (sel[0]) predicate = 1'b1;
        else predicate = 1'b0;
    end
    assign plain_ref = (sel === 2'bx1) ? 2'b01 :
        ((sel === 2'bz1) || (sel === 2'b11)) ? 2'b10 : 2'b00;
    assign wildcard_ref = ((sel[1] === 1'b0) || (sel[1] === 1'bz)) &&
        ((sel[0] === 1'b1) || (sel[0] === 1'bz)) ? 2'b00 :
        ((sel[0] === 1'b1) || (sel[0] === 1'bz)) ? 2'b01 :
        ((sel[1] === 1'bx) || (sel[1] === 1'bz)) && (sel[0] === 1'b0) ? 2'b10 : 2'b11;
    assign invariant = (plain === plain_ref) && (w === wildcard_ref) && (predicate === (sel[0] === 1'b1));
endmodule
'@ | Set-Content -LiteralPath "$root/case.sv" -Encoding utf8NoBOM
@'
module sampled_case(input logic clk, input logic [1:0] sel);
    logic [1:0] q, w;
    always_ff @(posedge clk) begin
        case (sel)
            2'bz1: q <= 2'bz0;
            2'bx1: q <= 2'bx0;
            2'b00: q <= 2'b10;
        endcase
        casez (sel)
            2'b01: w <= 2'b00;
            2'b?1: w <= 2'b01;
            2'bx0: w <= 2'b10;
            default: w <= 2'b11;
        endcase
    end
    p_hold: assert property (@(posedge clk) (sel === 2'b10) |=> (q === $past(q)));
    p_priority: assert property (@(posedge clk) (sel === 2'bz1) |=> (w === 2'b00));
    c_x: cover property (@(posedge clk) (sel === 2'bx1) |=> ((q === 2'bx0) && (w === 2'b01)));
    c_z: cover property (@(posedge clk) (sel === 2'bz1) |=> ((q === 2'bz0) && (w === 2'b00)));
endmodule
'@ | Set-Content -LiteralPath "$root/sampled.sv" -Encoding utf8NoBOM
foreach ($entry in @(@{id='case'; top='case_demo'},@{id='sampled'; top='sampled_case'})) {
    @('Q3AFORMAL_PROJECT 2',('top ' + $entry.top),('source systemverilog "{0}.sv"' -f $entry.id),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
        Set-Content -LiteralPath "$root/$($entry.id).q3a" -Encoding utf8NoBOM
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
    $lines = @(& $checker --check-drat "$Path/query.cnf" "$Path/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind $Kind)
    if ($LASTEXITCODE -ne 0 -or $lines -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $checked.proof_sha256 -cne $proved.proof_sha256 -or $checked.proof_sha256 -cne (Hash "$Path/proof.q3adrat")) {
        throw "Case certificate did not revalidate for $Name."
    }
    $lines | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

foreach ($high in '0','1','x','z') {
    foreach ($low in '0','1','x','z') {
        $inputBits = "$high$low"
        $plain = if ($inputBits -ceq 'x1') { '01' } elseif ($inputBits -cin 'z1','11') { '10' } else { '00' }
        $w = if ($low -cin '1','z') {
            if ($high -cin '0','z') { '00' } else { '01' }
        } elseif ($low -ceq '0' -and $high -cin 'x','z') { '10' } else { '11' }
        $p = if ($low -ceq '1') { '1' } else { '0' }
        $result = Run "eval-$inputBits" EVALUATED 0 @('dev-eval-four-state',"$root/case.q3a",'--input','sel',$inputBits)
        if ($result.signals.plain -cne $plain -or $result.signals.w -cne $w -or
            $result.signals.predicate -cne $p -or $result.signals.invariant -cne '1') {
            throw "The four-state priority or exact match was incorrect for $inputBits."
        }
    }
}

$path = "$root/comb-proof"
$proofs = [ordered]@{ combinational = Check-Proof combinational PROVEN four-state-exact @("$root/case.q3a",
    '--expect','invariant','1','--evidence-dir',$path) $path }
$base = @("$root/sampled.q3a",'--property')
foreach ($name in 'p_hold','p_priority') {
    $path = "$root/$name"
    $proofs[$name] = Check-Proof $name BOUNDED_PASS four-state-sampled-sva ($base + @(
        $name,'--evidence-dir',$path,'--steps','2')) $path
}
$hits = [ordered]@{}
foreach ($entry in @(@{name='c_x'; expected='x0'},@{name='c_z'; expected='z0'})) {
    $path = "$root/$($entry.name)"
    $options = $base + @($entry.name,'--evidence-dir',$path,'--steps','1')
    $hit = Run "hit-$($entry.name)" COVERED 0 (@('dev-prove-four-state') + $options)
    $reopened = Run "reopen-$($entry.name)" COVERED 0 (@('dev-verify-four-state') + $options)
    if ($reopened.trace[1].q -cne $entry.expected -or !$reopened.witness_revalidated -or
        $hit.witness_sha256 -cne $reopened.witness_sha256 -or $reopened.witness_sha256 -cne (Hash "$path/cover.q3awitness")) {
        throw "Four-state case witness did not revalidate for $($entry.name)."
    }
    $hits[$entry.name] = $reopened.witness_sha256
}
[ordered]@{
    status = 'FOUR_STATE_CASE_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    exhaustive_cases = 16
    proof_sha256 = $proofs
    witnesses_sha256 = $hits
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: 16 input states, exact case and casez priority, three independently checked certificates and two reopened witnesses.'
