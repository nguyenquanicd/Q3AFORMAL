#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = Join-Path $root 'project.q3a'
$source = Join-Path $root 'signed_unary.sv'
$minimum = [bigint][long]::MinValue
$maximum = [bigint][long]::MaxValue
$wideValues = @($minimum, ($minimum + 1), -2, -1, 0, 1, ($maximum - 1), $maximum)

function ConvertTo-PackedHex([bigint]$Value, [int]$Width) {
    $modulus = [bigint]::One -shl $Width
    $bits = $Value % $modulus
    if ($bits.Sign -lt 0) { $bits += $modulus }
    $digits = [int][Math]::Ceiling($Width / 4)
    $hex = $bits.ToString('X').TrimStart('0')
    $hex.PadLeft($digits, '0')
}

$smallRows = @(foreach ($i in 0..15) {
    $value = if ($i -ge 8) { $i - 16 } else { $i }
    $plus = ConvertTo-PackedHex $value 8
    $minus = ConvertTo-PackedHex (-$value) 8
    $complement = ConvertTo-PackedHex (-1 - $value) 8
    $wrapped = ConvertTo-PackedHex (-$value) 4
    $logical = '{0}{1}' -f [int]($value -eq 0), [int](((2 * $value) -band 15) -eq 0)
    "    4'd${i}: begin expect_small = 28'h$plus$minus$complement$wrapped; expect_logic = 2'b$logical; end"
})
$largeRows = @(for ($i = 0; $i -lt $wideValues.Count; ++$i) {
    $value = [bigint]$wideValues[$i]
    $operand = ConvertTo-PackedHex $value 64
    $minus = ConvertTo-PackedHex (-$value) 64
    $complement = ConvertTo-PackedHex ([bigint](-1) - $value) 64
    $zero = [int]($value -eq 0)
    "    3'd${i}: begin value64 = 64'sh$operand; expect_minus64 = 64'h$minus; expect_not64 = 64'h$complement; expect_zero64 = 1'b$zero; end"
})
$prefix = @"
module signed_unary(input logic clk, input logic signed [3:0] value4,
                    input logic [2:0] choose64);
  logic [7:0] plus8, minus8, not8;
  logic [3:0] minus4;
  logic [27:0] expect_small;
  logic [1:0] expect_logic;
  logic signed [63:0] value64;
  logic [63:0] minus64, not64, expect_minus64, expect_not64;
  logic expect_zero64;
  assign plus8 = +value4;
  assign minus8 = -value4;
  assign not8 = ~value4;
  assign minus4 = -value4;
  assign minus64 = -value64;
  assign not64 = ~value64;
  always_comb begin
    case (value4)
"@
$between = @"
      default: begin expect_small = '0; expect_logic = '0; end
    endcase
  end
  always_comb begin
    case (choose64)
"@
$suffix = @"
      default: begin value64 = '0; expect_minus64 = '0; expect_not64 = '0; expect_zero64 = 1'b0; end
    endcase
  end
  p_unary: assert property (@(posedge clk)
    {plus8, minus8, not8, minus4} == expect_small &&
    {!value4, !(value4 + value4)} == expect_logic &&
    minus64 == expect_minus64 && not64 == expect_not64 && (!value64) == expect_zero64);
  p_width_mutant: assert property (@(posedge clk)
    (value4 != 4'sh8) || (plus8 == 8'h08));
endmodule
"@
@($prefix) + $smallRows + @($between) + $largeRows + @($suffix) |
    Set-Content -LiteralPath $source -Encoding utf8
@('Q3AFORMAL_PROJECT 2', 'top signed_unary', 'source systemverilog "signed_unary.sv"') |
    Set-Content -LiteralPath $manifest -Encoding utf8

function Run-Case([string]$Name, [int]$Code, [string]$Status, [string[]]$ProofOptions) {
    $stdout = @(& $exe prove $manifest @ProofOptions 2> (Join-Path $root "$Name.stderr.txt"))
    $actual = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Name.json") -Encoding utf8
    $result = $stdout | ConvertFrom-Json
    if ($actual -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Name expected $Status with exit $Code, got $actual and $stdout"
    }
    return $result
}
$proofPath = Join-Path $root 'certificate'
$bundle = Join-Path $root 'counterexample'
$null = Run-Case bmc 1 BOUNDED_PASS @('--engine','bmc','--property','p_unary','--frames','0')
$proof = Run-Case pdr 0 PROVEN @('--engine','pdr','--property','p_unary','--evidence-dir',$proofPath)
$rechecked = @(& $exe verify-pdr $manifest --property p_unary --evidence-dir $proofPath)
if ($LASTEXITCODE -ne 0 -or $rechecked -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
    throw 'Signed unary certificate failed source-backed revalidation.'
}
$rechecked | Set-Content -LiteralPath (Join-Path $root 'certificate-revalidation.txt') -Encoding utf8
$checked = @(foreach ($obligation in $proof.certificate.obligations) {
    $stem = $obligation.kind.Substring(4)
    $cnf = Join-Path $proofPath "$stem.cnf"
    $drat = Join-Path $proofPath "$stem.q3adrat"
    $output = @(& $checker --check-drat $cnf $drat --model-sha256 $proof.certificate.model_sha256 --query-kind $obligation.kind)
    if ($LASTEXITCODE -ne 0 -or $output -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone checker rejected $stem."
    }
    [pscustomobject]@{kind = $obligation.kind; verdict = $output}
})
if ($checked.Count -ne 3) { throw 'Expected initiation, consecution and safety proofs.' }

$unused = Join-Path $root 'no-mutant-proof'
$mutant = Run-Case mutant 0 FAIL @('--engine','pdr','--property','p_width_mutant',
    '--evidence-dir',$unused,'--bundle-dir',$bundle,'--trace-all')
$replay = @(& $exe --verify-bundle $bundle --require-source-model)
if ($LASTEXITCODE -ne 0 -or $replay -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
    $replay -cnotcontains 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=1 candidate_frame=0' -or
    $null -ne $mutant.certificate -or (Test-Path -LiteralPath $unused)) {
    throw 'Width mutant did not produce the expected replay-only result.'
}
$replay | Set-Content -LiteralPath (Join-Path $root 'counterexample-revalidation.txt') -Encoding utf8
$trace = Get-ChildItem -LiteralPath $bundle -Filter trace.json -Recurse
$sample = (Get-Content -LiteralPath $trace.FullName -Raw | ConvertFrom-Json).frames[0].signals
if ($sample.value4 -cne '0x8' -or $sample.plus8 -cne '0xf8' -or
    $sample.minus8 -cnotin '0x8','0x08' -or $sample.not8 -cnotin '0x7','0x07' -or $sample.minus4 -cne '0x8') {
    throw "Mutant waveform disagrees with the independent reference: $($sample | ConvertTo-Json -Compress)"
}

[ordered]@{
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256 = (Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    source_sha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    signed_4_bit_patterns = $smallRows.Count
    signed_64_bit_patterns = $largeRows.Count
    independent_drat = $checked
    replayed_mutation = $sample
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: all 16 signed 4-bit values, eight signed 64-bit boundaries, three independent DRAT checks, and source-backed mutation replay.'
