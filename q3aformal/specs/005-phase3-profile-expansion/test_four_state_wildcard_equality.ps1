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
function Oracle($Left, $Right) {
    $unknown = $false
    for ($bit = 0; $bit -lt $Right.Length; $bit++) {
        if ($Right[$bit] -in 'x','z') { continue }
        if ($Left[$bit] -in 'x','z') { $unknown = $true }
        elseif ($Left[$bit] -cne $Right[$bit]) { return '01' }
    }
    if ($unknown) { return 'xx' }
    '10'
}
$rows = foreach ($a in $words) {
    foreach ($b in $words) { "4'b$a${b}: expected = 2'b$(Oracle $a $b);" }
}
@"
module wildcard_demo(input logic [1:0] a, b,
    output logic [1:0] comparison,
    output logic literal_match, signed_match, mixed_match, oracle);
    logic [1:0] expected;
    logic signed [1:0] sa;
    assign sa = a;
    assign comparison = {a ==? b, a !=? b};
    assign literal_match = a ==? 2'b1?;
    assign signed_match = sa ==? 4'sb11?1;
    assign mixed_match = sa ==? 4'b00?1;
    always_comb begin
        case ({a,b})
            $($rows -join "`n            ")
            default: expected = 2'bxx;
        endcase
    end
    assign oracle = comparison === expected;
endmodule
"@ | Set-Content -LiteralPath "$root/wildcards.sv" -Encoding utf8NoBOM
@'
module wildcard_properties(input logic clk, input logic [1:0] a);
    p_known: assert property (@(posedge clk) (a ==? 2'b1?) |-> (a[1] === 1'b1));
    c_mismatch: cover property (@(posedge clk) (a === 2'b1z) && (a !=? 2'b0x));
endmodule
'@ | Set-Content -LiteralPath "$root/properties.sv" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top wildcard_demo','source systemverilog "wildcards.sv"',$profile) |
    Set-Content -LiteralPath "$root/wildcards.q3a" -Encoding utf8NoBOM
@('Q3AFORMAL_PROJECT 2','top wildcard_properties','source systemverilog "properties.sv"',$profile) |
    Set-Content -LiteralPath "$root/properties.q3a" -Encoding utf8NoBOM

foreach ($case in @(
    @{ id='right-wildcards'; a='xz'; b='xz' },
    @{ id='left-unknown'; a='x1'; b='01' },
    @{ id='known-mismatch'; a='1z'; b='00' },
    @{ id='matching-binary'; a='11'; b='11' }
)) {
    $r = Run $case.id EVALUATED 0 @('dev-eval-four-state',"$root/wildcards.q3a",
        '--input','a',$case.a,'--input','b',$case.b)
    if ($r.signals.comparison -cne (Oracle $case.a $case.b) -or $r.signals.oracle -cne '1') {
        throw "Wildcard result differs from the oracle for $($case.id)."
    }
    if ($case.id -ceq 'matching-binary' -and
        ($r.signals.literal_match + $r.signals.signed_match + $r.signals.mixed_match) -cne '111') {
        throw 'Literal ?, signed extension, or mixed unsigned extension failed.'
    }
}

$proofs = [ordered]@{}
foreach ($case in @(
    @{ name='oracle'; status='PROVEN'; kind='four-state-exact';
        args=@("$root/wildcards.q3a",'--expect','oracle','1','--evidence-dir',"$root/oracle") },
    @{ name='sampled'; status='BOUNDED_PASS'; kind='four-state-sampled-sva';
        args=@("$root/properties.q3a",'--property','p_known','--evidence-dir',"$root/sampled",'--steps','0') }
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
$argsCover = @("$root/properties.q3a",'--property','c_mismatch','--evidence-dir',"$root/cover",'--steps','0')
$hit = Run cover COVERED 0 (@('dev-prove-four-state') + $argsCover)
$replay = Run cover-replay COVERED 0 (@('dev-verify-four-state') + $argsCover)
if (!$replay.witness_revalidated -or $hit.witness_sha256 -cne $replay.witness_sha256 -or
    $replay.trace[0].a -cne '1z') {
    throw 'Wildcard inequality witness did not revalidate from source.'
}
@('Q3AFORMAL_PROJECT 2','top wildcard_properties','source systemverilog "properties.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM
& $exe --parse-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 1 -or !(Get-Content "$root/baseline.stderr.txt" -Raw).Contains("operator '==?'")) {
    throw 'Baseline grammar did not reject wildcard equality.'
}

[ordered]@{
    status = 'FOUR_STATE_WILDCARD_EQUALITY_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/wildcards.sv"
    oracle_input_pairs = $rows.Count
    proof_sha256 = $proofs
    witness_sha256 = $replay.witness_sha256
    baseline_rejected = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: wildcard equality and inequality across 256 four-state pairs, signed and mixed sizing, two independent certificates, and witness replay.'
