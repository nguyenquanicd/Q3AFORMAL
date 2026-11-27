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
module shift_demo(
    input logic signed [3:0] v,
    input logic [3:0] u,
    input logic signed [1:0] amount,
    input logic [63:0] wide_count,
    output logic [3:0] shl, shr, ashl, ashr, unsigned_right, high_distance,
    output logic signed [7:0] widened,
    output logic equivalent
);
    assign shl = v << amount;
    assign shr = v >> amount;
    assign ashl = v <<< amount;
    assign ashr = v >>> amount;
    assign unsigned_right = u >>> amount;
    assign widened = v >>> amount;
    assign high_distance = v >>> wide_count;
    assign equivalent = ((v << amount) === (v <<< amount)) && ((u >>> amount) === (u >> amount));
endmodule
'@ | Set-Content -LiteralPath "$root/shifts.sv" -Encoding utf8NoBOM
@'
module sampled_shift(input logic clk, input logic signed [3:0] d, input logic [1:0] amount);
    logic signed [3:0] q;
    always_ff @(posedge clk) begin q <= d >>> amount; end
    p_fill: assert property (@(posedge clk) ((d === 4'b1010) && (amount === 2'b01)) |=> (q === 4'b1101));
    c_z_fill: cover property (@(posedge clk) ((d === 4'bz1x0) && (amount === 2'b01)) |=> (q === 4'bzz1x));
    c_unknown_count: cover property (@(posedge clk) ((d === 4'b1111) && (amount === 2'bz1)) |=> (q === 4'bxxxx));
endmodule
'@ | Set-Content -LiteralPath "$root/sampled.sv" -Encoding utf8NoBOM
foreach ($entry in @(@{id='shifts'; top='shift_demo'},@{id='sampled'; top='sampled_shift'})) {
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
        throw "Shift certificate did not revalidate for $Name."
    }
    $lines | Set-Content -LiteralPath "$root/checker-$Name.txt" -Encoding utf8NoBOM
    $checked.proof_sha256
}

$large = '1' + ('0' * 63)
$zero = '0' * 64
$unknown = 'x' + ('0' * 63)
$cases = @(
    @{id='xz'; data='z1x0'; count='01'; wide=$large; shl='1x00'; shr='0z1x';
        ashr='zz1x'; widened='zzzzzz1x'; high_distance='zzzz'},
    @{id='unsigned-count'; data='1010'; count='11'; wide=$zero; shl='0000'; shr='0001';
        ashr='1111'; widened='11111111'; high_distance='1010'},
    @{id='unknown-count'; data='1111'; count='z1'; wide=$unknown; shl='xxxx'; shr='xxxx';
        ashr='xxxx'; widened='xxxxxxxx'; high_distance='xxxx'},
    @{id='identity'; data='x0z1'; count='00'; wide=$large; shl='x0z1'; shr='x0z1';
        ashr='x0z1'; widened='xxxxx0z1'; high_distance='xxxx'}
)
foreach ($case in $cases) {
    $result = Run "eval-$($case.id)" EVALUATED 0 @('dev-eval-four-state',"$root/shifts.q3a",
        '--input','v',$case.data,'--input','u',$case.data,'--input','amount',$case.count,'--input','wide_count',$case.wide)
    foreach ($output in 'shl','shr','ashr','widened','high_distance') {
        if ($result.signals.$output -cne $case[$output]) {
            throw "Incorrect $output in $($case.id). Got $($result.signals.$output), expected $($case[$output])."
        }
    }
    if ($result.signals.ashl -cne $case.shl -or $result.signals.unsigned_right -cne $case.shr -or
        $result.signals.equivalent -cne '1') { throw 'Shift operator equivalence was violated.' }
}
$proofs = [ordered]@{}
$path = "$root/equiv-proof"
$proofs.equivalent = Check-Proof equiv PROVEN four-state-exact @("$root/shifts.q3a",
    '--expect','equivalent','1','--evidence-dir',$path) $path
$base = @("$root/sampled.q3a",'--property')
$path = "$root/sign-proof"
$proofs.sign = Check-Proof sign BOUNDED_PASS four-state-sampled-sva ($base + @('p_fill','--evidence-dir',$path,'--steps','1')) $path
$hits = [ordered]@{}
foreach ($test in @(@{name='c_z_fill'; expected='zz1x'},@{name='c_unknown_count'; expected='xxxx'})) {
    $name = $test.name
    $path = "$root/$name"
    $options = $base + @($name,'--evidence-dir',$path,'--steps','1')
    $hit = Run "hit-$name" COVERED 0 (@('dev-prove-four-state') + $options)
    $reopened = Run "reopen-$name" COVERED 0 (@('dev-verify-four-state') + $options)
    if ($reopened.trace[1].q -cne $test.expected -or !$reopened.witness_revalidated -or
        $hit.witness_sha256 -cne $reopened.witness_sha256 -or $reopened.witness_sha256 -cne (Hash "$path/cover.q3awitness")) {
        throw "A sampled shift witness did not replay for $name."
    }
    $hits[$name] = $reopened.witness_sha256
}
'module baseline(input logic [1:0] a, output logic [1:0] y); assign y = a >>> 1; endmodule' |
    Set-Content -LiteralPath "$root/baseline.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top baseline','source systemverilog "baseline.sv"',
    'option profile Q3A-P0-R0.9.1') | Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
$null = & $exe --lower-project "$root/baseline.q3a" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or (Get-Content "$root/baseline.stderr.txt" -Raw) -notmatch 'outside the Phase 0 RTL expression subset') {
    throw 'The baseline profile did not reject arithmetic right shift at source parsing.'
}
[ordered]@{
    status = 'FOUR_STATE_SHIFTS_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    directed_cases = $cases.Count
    proof_sha256 = $proofs
    witnesses_sha256 = $hits
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: four shift operators, signed and unsigned widths, 64-bit distances, two independent certificates and two reopened witnesses.'
