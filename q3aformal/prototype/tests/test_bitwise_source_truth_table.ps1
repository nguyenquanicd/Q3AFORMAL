#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = Join-Path $root 'project.q3a'
$source = Join-Path $root 'bitwise_truth.sv'
$expectedRows = [ordered]@{}
$operators = @('&', '|', '^', '~^')
$signedness = @('ss', 'su', 'us', 'uu')

# Model the numeric operands without using the RTL implementation or its IR.
function Reference-Row([int]$A, [int]$B) {
    $nibbles = foreach ($combination in $signedness) {
        $signed = $combination -ceq 'ss'
        $left = if ($signed -and $A -ge 4) { $A - 8 } else { $A }
        $right = if ($signed -and $B -ge 2) { $B - 4 } else { $B }
        foreach ($value in ($left -band $right), ($left -bor $right),
            ($left -bxor $right), (-bnot ($left -bxor $right))) {
            ($value -band 15).ToString('X1')
        }
    }
    $logical = '{0}{1}' -f [int]($A -ne 0 -and $B -ne 0), [int]($A -ne 0 -or $B -ne 0)
    [pscustomobject]@{ bitwise = $nibbles -join ''; logical = $logical }
}

$declarations = @(
    'module bitwise_truth(input logic clk, input logic [2:0] a, input logic [1:0] b);'
    'logic signed [2:0] signed_a;'
    'logic signed [1:0] signed_b;'
    'logic [63:0] observed, expected;'
    'logic [1:0] observed_logic, expected_logic;'
    'assign signed_a = a;'
    'assign signed_b = b;'
    'assign observed_logic = {signed_a && signed_b, signed_a || signed_b};'
)
$names = [System.Collections.Generic.List[string]]::new()
$operatorAssignments = foreach ($combination in $signedness) {
    $left = if ($combination[0] -ceq 's') { 'signed_a' } else { 'a' }
    $right = if ($combination[1] -ceq 's') { 'signed_b' } else { 'b' }
    for ($index = 0; $index -lt $operators.Count; ++$index) {
        $name = "result_${combination}_$index"
        $names.Add($name)
        "logic [3:0] $name;"
        "assign $name = $left $($operators[$index]) $right;"
    }
}
$assembly = 'assign observed = {' + ($names -join ', ') + '};'
$rows = foreach ($a in 0..7) {
    foreach ($b in 0..3) {
        $selector = $a * 4 + $b
        $reference = Reference-Row $a $b
        $expectedRows[[string]$selector] = $reference
        "    5'd${selector}: begin expected = 64'h$($reference.bitwise); expected_logic = 2'b$($reference.logical); end"
    }
}
$checks = @"
default: begin expected = '0; expected_logic = '0; end
  endcase
end
p_truth: assert property (@(posedge clk) observed == expected && observed_logic == expected_logic);
p_canary: assert property (@(posedge clk) ({a,b} != 5'd27) || (observed == (expected ^ 64'h1)));
endmodule
"@
@($declarations) + @($operatorAssignments) + @($assembly, 'always_comb begin', '  case ({a,b})') +
    @($rows) + @($checks) | Set-Content -LiteralPath $source -Encoding utf8
@('Q3AFORMAL_PROJECT 2', 'top bitwise_truth', 'source systemverilog "bitwise_truth.sv"') |
    Set-Content -LiteralPath $manifest -Encoding utf8

function Invoke-Proof([string]$Id, [string]$Status, [int]$ExitCode, [string[]]$Arguments) {
    $output = @(& $exe prove $manifest @Arguments 2> (Join-Path $root "$Id.stderr.txt"))
    $actual = $LASTEXITCODE
    $output | Set-Content -LiteralPath (Join-Path $root "$Id.json") -Encoding utf8
    $result = $output | ConvertFrom-Json
    if ($actual -ne $ExitCode -or $result.exit_code -ne $ExitCode -or $result.status -cne $Status) {
        throw "$Id expected $Status ($ExitCode), got $actual and $output"
    }
}

Invoke-Proof bmc BOUNDED_PASS 1 @('--engine', 'bmc', '--property', 'p_truth', '--frames', '0')
$proof = Join-Path $root 'proof'
Invoke-Proof pdr PROVEN 0 @('--engine', 'pdr', '--property', 'p_truth', '--evidence-dir', $proof)
$reopened = @(& $exe verify-pdr $manifest --property p_truth --evidence-dir $proof)
if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
    throw 'Source-backed certificate regeneration failed.'
}
$reopened | Set-Content -LiteralPath (Join-Path $root 'proof-revalidation.txt') -Encoding utf8
$model = (Get-Content -LiteralPath (Join-Path $proof 'invariant.txt') -TotalCount 2)[1]
$standalone = foreach ($kind in 'initiation','consecution','safety') {
    $cnf = Join-Path $proof "$kind.cnf"
    $drat = Join-Path $proof "$kind.q3adrat"
    $output = @(& $checker --check-drat $cnf $drat --model-sha256 $model --query-kind "pdr-$kind")
    if ($LASTEXITCODE -ne 0 -or $output -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone checker rejected $kind."
    }
    [ordered]@{ kind = $kind; verdict = $output }
}

$bundle = Join-Path $root 'counterexample'
$unused = Join-Path $root 'no-canary-proof'
Invoke-Proof canary FAIL 0 @('--engine', 'pdr', '--property', 'p_canary', '--evidence-dir', $unused,
    '--bundle-dir', $bundle, '--trace-all')
$replay = @(& $exe --verify-bundle $bundle --require-source-model)
if ($LASTEXITCODE -ne 0 -or $replay -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
    $replay -cnotcontains 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=1 candidate_frame=0' -or
    (Test-Path -LiteralPath $unused)) {
    throw 'Canary did not produce exactly the expected replay-only result.'
}
$replay | Set-Content -LiteralPath (Join-Path $root 'counterexample-revalidation.txt') -Encoding utf8
$trace = Get-ChildItem -LiteralPath $bundle -Filter trace.json -Recurse
$sample = (Get-Content -LiteralPath $trace.FullName -Raw | ConvertFrom-Json).frames[0].signals
$canaryExpected = $expectedRows['27']
if ($sample.a -cne '0x6' -or $sample.b -cne '0x3' -or
    $sample.observed -cne ('0x' + $canaryExpected.bitwise.ToLowerInvariant()) -or
    $sample.observed_logic -cne ('0x' + [Convert]::ToInt32($canaryExpected.logical, 2).ToString('x'))) {
    throw "Counterexample disagrees with the independent bitwise model: $($sample | ConvertTo-Json -Compress)."
}

[ordered]@{
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256 = (Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    source_sha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    selector_rows = $expectedRows
    bitwise_outcomes = $expectedRows.Count * $operators.Count * $signedness.Count
    logical_outcomes = $expectedRows.Count * 2
    bmc = 'BOUNDED_PASS'
    pdr = 'PROVEN'
    independent_drat = @($standalone)
    replayed_canary = $sample
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: 32 input rows, 512 bitwise outputs, 64 logical outputs, three checked DRAT obligations and a replayed canary.'
