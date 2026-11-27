
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = @(
    'Q3AFORMAL_PROJECT 2',
    'top nested',
    'source systemverilog "nested.sv"',
    'option profile Q3A-SAMPLED-VALUE-DEVELOPMENT'
)
$rtl = @(
    'module nested(input logic clk, input logic [63:0] word);'
    '    p: assert property (@(posedge clk) $countones($countones($countones(word))) <= 32''sd7);'
    'endmodule'
)
$project = "$root/nested.q3a"
$source = "$root/nested.sv"
Set-Content -LiteralPath $project -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath $source -Value $rtl -Encoding utf8NoBOM

$stdout = @(& $exe --lower-project $project 2> "$root/lower.stderr.txt")
$exit = $LASTEXITCODE
$stdout | Set-Content -LiteralPath "$root/model.json" -Encoding utf8NoBOM
if ($exit -ne 0) { throw 'Triple-nested count failed to lower.' }
$model = $stdout -join [Environment]::NewLine | ConvertFrom-Json
$operand = $model.properties[0].antecedent.terms[0].predicate.operands[0]
for ($depth = 0; $depth -lt 3; ++$depth) {
    if ($operand.kind -cne 'bit_vector_function' -or $operand.value -cne '$countones' -or
        $operand.width -ne 32 -or !$operand.signed -or $operand.operands.Count -ne 1) {
        throw "Population count copied an operand or changed its type at nesting level $depth."
    }
    $operand = $operand.operands[0]
}
$bytes = (Get-Item -LiteralPath "$root/model.json").Length
if ($operand.kind -cne 'signal' -or $operand.width -ne 64 -or $operand.value -cne 'word' -or $bytes -gt 8192) {
    throw "Unexpected operand or non-compact serialized result of $bytes bytes."
}

# Use a second source to check both nested replay and a constant count in a shift.
$witnessRtl = $rtl[0..1] + @(
    '    c_shift: cover property (@(posedge clk) (word == 64''d4) && ((word >> $countones(4''b0011)) == 64''d1));'
    '    p_wrong: assert property (@(posedge clk) $countones($countones($countones(word))) == 32''sd0);'
    'endmodule'
)
Set-Content -LiteralPath "$root/witness.sv" -Value $witnessRtl -Encoding utf8NoBOM
$witnessProject = "$root/witness.q3a"
Set-Content -LiteralPath $witnessProject -Value ($manifest -replace 'nested\.sv', 'witness.sv') -Encoding utf8NoBOM
foreach ($case in @(@{name='c_shift'; status='COVERED'}, @{name='p_wrong'; status='BOUNDED_FAIL'})) {
    $bundle = "$root/$($case.name)"
    $output = @(& $exe prove $witnessProject --engine bmc --property $case.name --frames 0 --bundle-dir $bundle 2> "$bundle.stderr.txt")
    $code = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$bundle.json" -Encoding utf8NoBOM
    $report = $output | ConvertFrom-Json
    if ($report.status -cne $case.status -or $report.exit_code -ne $code) {
        throw "Unexpected result for $($case.name). $output $(Get-Content "$bundle.stderr.txt" -Raw)"
    }
    $replayed = @(& $exe --verify-bundle $bundle --require-source-model 2> "$bundle-replay.stderr.txt")
    $code = $LASTEXITCODE
    $replayed | Set-Content -LiteralPath "$bundle-replay.txt" -Encoding utf8NoBOM
    if ($code -ne 0 -or $replayed -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $replayed -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Source revalidation failed for $($case.name). $replayed"
    }
}
[ordered]@{
    status = 'COMPACT_BIT_VECTOR_QUALIFIED'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    source_sha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    serialized_bytes = $bytes
    nested_function_nodes = 3
    operand_width = 64
    source_replayed_witnesses = @('c_shift','p_wrong')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: triple-nested 64-bit count lowered to $bytes bytes and both witnesses revalidated from source."

