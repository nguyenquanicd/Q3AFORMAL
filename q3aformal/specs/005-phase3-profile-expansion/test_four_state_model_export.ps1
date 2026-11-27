#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$StandardExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$standard = (Resolve-Path -LiteralPath $StandardExecutable).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$profile = 'option profile Q3A-FOUR-STATE-DEVELOPMENT'
@'
module guarded(input logic clk, grant, req, ack);
    c_guard: cover property (@(posedge clk) grant throughout (req ##2 ack));
endmodule
'@ | Set-Content -LiteralPath "$root/guarded.sv" -Encoding utf8NoBOM
@'
module product(input logic [1:0] a, b, output logic [3:0] y);
    assign y = a * b;
endmodule
'@ | Set-Content -LiteralPath "$root/product.sv" -Encoding utf8NoBOM
foreach ($name in 'guarded','product') {
    @('Q3AFORMAL_PROJECT 2', "top $name", ('source systemverilog "{0}.sv"' -f $name), $profile) |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
}
@('Q3AFORMAL_PROJECT 2', 'top product', 'source systemverilog "product.sv"') |
    Set-Content -LiteralPath "$root/baseline.q3a" -Encoding utf8NoBOM

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Export-Model($Name) {
    $lines = @(& $exe dev-lower-four-state "$root/$Name.q3a" 2> "$root/$Name-lowering.stderr.txt")
    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { throw "Invalid model export for $Name." }
    $lines[0] | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM -NoNewline
    $model = $lines[0] | ConvertFrom-Json
    if ($model.semantic_profile -cne 'Q3A-FOUR-STATE-DEVELOPMENT' -or $model.top_module -cne $Name) {
        throw "Incorrect profile or module for $Name."
    }
    $model
}
$guarded = Export-Model guarded
$sequence = ($guarded.properties | Where-Object name -CEQ 'c_guard').antecedent
if (($sequence.terms.predicate.value -join ',') -cne 'grant,req,grant,grant,ack' -or
    ($sequence.terms.delay_from_previous -join ',') -cne '0,0,1,1,0' -or
    ($sequence.automaton.transitions.delay_cycles -join ',') -cne '0,0,1,1,0' -or
    @($sequence.terms.predicate.source | Where-Object { $_.file -cne 'guarded.sv' -or $_.line -ne 2 }).Count -ne 0) {
    throw 'The lowered sequence lost a guard sample, body predicate, or source location.'
}
$raw = & $exe dev-prove-four-state "$root/guarded.q3a" --property c_guard --evidence-dir "$root/cover" --steps 2
$exit = $LASTEXITCODE
$cover = $raw | ConvertFrom-Json
if ($exit -ne 0 -or $cover.status -cne 'COVERED' -or !$cover.source_replayed -or
    $cover.model_sha256 -cne (Hash "$root/guarded.json")) {
    throw 'The queried sampled model differs from the exported model.'
}
$product = Export-Model product
$raw = & $exe dev-eval-four-state "$root/product.q3a" --input a 11 --input b 11
$exit = $LASTEXITCODE
$evaluation = $raw | ConvertFrom-Json
if ($exit -ne 0 -or $evaluation.status -cne 'EVALUATED' -or $evaluation.signals.y -cne '1001' -or
    $evaluation.model_sha256 -cne (Hash "$root/product.json")) {
    throw 'The evaluated combinational model differs from the exported model.'
}
foreach ($case in @(
    @{ name='baseline'; args=@('dev-lower-four-state',"$root/baseline.q3a"); diagnostic='expected option profile' },
    @{ name='argument'; args=@('dev-lower-four-state',"$root/product.q3a",'--steps','0'); diagnostic='expected one four-state PROJECT' }
)) {
    $arguments = $case.args
    $out = @(& $exe @arguments 2> "$root/$($case.name).stderr.txt")
    if ($LASTEXITCODE -ne 2 -or $out.Count -ne 0 -or
        (Get-Content "$root/$($case.name).stderr.txt" -Raw) -notlike "*$($case.diagnostic)*") {
        throw "Invalid output or diagnostic for $($case.name)."
    }
}
$help = @(& $standard --help)
if ($LASTEXITCODE -ne 0 -or ($help -join "`n") -match 'dev-lower-four-state') {
    throw 'The standard executable exposed the opt-in command.'
}

[ordered]@{
    status = 'FOUR_STATE_MODEL_EXPORT_QUALIFIED'
    executable_sha256 = Hash $exe
    standard_sha256 = Hash $standard
    sampled_model_sha256 = $cover.model_sha256
    combinational_model_sha256 = $evaluation.model_sha256
    guard_relative_delays = $sequence.terms.delay_from_previous
    rejected_cases = 2
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: sampled and combinational model identities, throughout guard offsets and source locations, and profile isolation.'
