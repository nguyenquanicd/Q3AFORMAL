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

$rtl = @'
module reduction_demo(
    input logic [1:0] a,
    input logic [63:0] wide,
    output logic [6:0] gates,
    output logic [2:0] wide_gates,
    output logic mismatch
);
    assign gates = {&a, ~&a, |a, ~|a, ^a, ~^a, ^~a};
    assign wide_gates = {&wide, |wide, ^wide};
    assign mismatch = gates !== {
        a[1] & a[0], ~(a[1] & a[0]), a[1] | a[0], ~(a[1] | a[0]),
        a[1] ^ a[0], ~(a[1] ^ a[0]), ~(a[1] ^ a[0])
    };
endmodule
'@
$rtl | Set-Content -LiteralPath "$root/reduction.sv" -Encoding utf8NoBOM
$manifest = @('Q3AFORMAL_PROJECT 2','top reduction_demo','source systemverilog "reduction.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT')
$manifest | Set-Content -LiteralPath "$root/reduction.q3a" -Encoding utf8NoBOM
'module reduction_demo(input logic [1:0] a, output logic y); assign y = &a; endmodule' |
    Set-Content -LiteralPath "$root/baseline.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top reduction_demo','source systemverilog "baseline.sv"',
    'option profile Q3A-P0-R0.9.1') | Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM

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
function Negate([string]$State) { @{ '0'='1'; '1'='0'; 'x'='x' }[$State] }

$eval = @('dev-eval-four-state',"$root/reduction.q3a",'--input','a')
foreach ($high in '0','1','x','z') {
    foreach ($low in '0','1','x','z') {
        $bits = "$high$low"
        $and = if ($bits.Contains('0')) { '0' } elseif ($bits -ceq '11') { '1' } else { 'x' }
        $or = if ($bits.Contains('1')) { '1' } elseif ($bits -ceq '00') { '0' } else { 'x' }
        $xor = if ($bits -cmatch '[xz]') { 'x' } elseif ($high -ceq $low) { '0' } else { '1' }
        $expected = $and + (Negate $and) + $or + (Negate $or) + $xor + (Negate $xor) + (Negate $xor)
        $parsed = Run "gates-$bits" EVALUATED 0 ($eval + @($bits,'--input','wide',('0' * 64)))
        if ($parsed.signals.gates -cne $expected -or $parsed.signals.wide_gates -cne '000') {
            throw "Wrong reduction truth table for $bits."
        }
    }
}
foreach ($case in @(
    @{id='ones'; bits=('1' * 64); expected='110'},
    @{id='even'; bits=('11' + ('0' * 62)); expected='010'},
    @{id='odd'; bits=('1' + ('0' * 63)); expected='011'},
    @{id='masked'; bits=('z1' + ('0' * 61) + 'x'); expected='01x'},
    @{id='unknown'; bits=('z' * 64); expected='xxx'}
)) {
    $parsed = Run "wide-$($case.id)" EVALUATED 0 ($eval + @('01','--input','wide',$case.bits))
    if ($parsed.signals.wide_gates -cne $case.expected) { throw "Wrong 64-bit result for $($case.id)." }
}

$evidence = "$root/proof"
$common = @("$root/reduction.q3a",'--expect','mismatch','0','--evidence-dir',$evidence)
$proved = Run proved PROVEN 0 (@('dev-prove-four-state') + $common)
$checked = Run checked REVALIDATED 0 (@('dev-verify-four-state') + $common)
$records = @(& $checker --check-drat "$evidence/query.cnf" "$evidence/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind four-state-exact)
if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
    $proved.proof_sha256 -cne $checked.proof_sha256 -or $checked.proof_sha256 -cne (Hash "$evidence/proof.q3adrat")) {
    throw 'Reduction equivalence certificate did not revalidate.'
}
$records | Set-Content -LiteralPath "$root/checker.txt" -Encoding utf8NoBOM

@"
module reduction_property(input logic clk, input logic [1:0] d);
    p_reduce: assert property (@(posedge clk) (d === 2'b1z) |-> ((|d) === 1'b1));
    c_parity: cover property (@(posedge clk) (d === 2'bzz) |=> ((^d) === 1'bx));
endmodule
"@ | Set-Content -LiteralPath "$root/property.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top reduction_property','source systemverilog "property.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath "$root/property.q3a" -Encoding utf8NoBOM
$property = "$root/property.q3a"
$pOptions = @($property,'--property','p_reduce','--evidence-dir',"$root/property-proof",'--steps','1')
$null = Run proved-property BOUNDED_PASS 0 (@('dev-prove-four-state') + $pOptions)
$null = Run checked-property REVALIDATED 0 (@('dev-verify-four-state') + $pOptions)
$cOptions = @($property,'--property','c_parity','--evidence-dir',"$root/property-witness",'--steps','1')
$hit = Run hit-property COVERED 0 (@('dev-prove-four-state') + $cOptions)
$hitReplay = Run reopened-property COVERED 0 (@('dev-verify-four-state') + $cOptions)
if ($hit.trace[0].d -cne 'zz' -or $hit.trace[1].d -cnotmatch '[xz]' -or !$hitReplay.witness_revalidated -or
    $hit.witness_sha256 -cne $hitReplay.witness_sha256) {
    throw 'The sampled reduction parity witness did not replay.'
}

$null = & $exe --lower-project "$root/baseline.q3a" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notmatch "expected an expression operand, found '&'") { throw 'The baseline two-state profile unexpectedly admitted reduction syntax.' }
[ordered]@{
    status = 'FOUR_STATE_REDUCTIONS_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    two_bit_input_cases = 16
    sixty_four_bit_cases = 5
    proof_sha256 = $checked.proof_sha256
    sampled_properties = 2
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: 16 reduction truth-table inputs, five 64-bit cases, a source-checked standalone certificate, and baseline rejection.'
