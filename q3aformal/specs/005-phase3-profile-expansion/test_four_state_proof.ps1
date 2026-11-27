param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CheckerPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = "$root/case.q3a"
$source = "$root/top.sv"
$rtl = @"
module four_proof(input logic [3:0] a, input logic sel,
    output logic [3:0] zero, alias_zero, merged, mux,
    output logic exact, self_difference, all_z, all_x, relation, expanded);
    assign alias_zero = zero;
    assign zero = a & 4'b0000;
    assign merged = 1'bx ? 4'bz1x0 : 4'bz1z0;
    assign mux = sel ? a : 4'bzzzz;
    assign exact = {a[3:1], a[0]} === a;
    assign self_difference = a != a;
    assign all_z = a === 'z;
    assign all_x = a === 'x;
    assign relation = (a ^ 4'b0000) === (a | 4'b0000);
    assign expanded = !((a ^ 4'b0000) !== (a | 4'b0000)) && (exact || self_difference);
endmodule
"@
Set-Content -LiteralPath $source -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath $project -Encoding utf8NoBOM -Value @(
    'Q3AFORMAL_PROJECT 2','top four_proof','source systemverilog "top.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT'
)
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, [string[]]$ArgsList) {
    $text = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $text | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $result = $text | ConvertFrom-Json
    if ($result.status -cne $Status -or $actual -ne $Code -or $result.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code. $text $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $result
}
$proof = @('dev-prove-four-state',$project,'--expect')
$verify = @('dev-verify-four-state',$project,'--expect')
$claims = [ordered]@{zero='0000'; merged='x1x0'; exact='1'; relation='1'; expanded='1'}
$evidence = [ordered]@{}
foreach ($signal in $claims.Keys) {
    $directory = "$root/proof-$signal"
    $argsTail = @($signal,$claims[$signal],'--evidence-dir',$directory)
    $result = Run "proved-$signal" PROVEN 0 ($proof + $argsTail)
    $checked = Run "reopened-$signal" REVALIDATED 0 ($verify + $argsTail)
    if ($result.query_sha256 -cne (Hash "$directory/query.cnf") -or
        $result.proof_sha256 -cne (Hash "$directory/proof.q3adrat") -or
        $checked.proof_sha256 -cne $result.proof_sha256 -or
        $checked.proof_model_sha256 -cne $result.proof_model_sha256) {
        throw 'Four-state proof identity or bytes changed.'
    }
    $independent = @(& $checker --check-drat "$directory/query.cnf" "$directory/proof.q3adrat" --model-sha256 $result.proof_model_sha256 --query-kind four-state-exact)
    if ($LASTEXITCODE -ne 0 -or $independent -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone checker did not accept $signal."
    }
    $independent | Set-Content -LiteralPath "$root/checker-$signal.txt" -Encoding utf8NoBOM
    $evidence[$signal] = $result.proof_sha256
}
$cases = [ordered]@{all_z='zzzz'; all_x='xxxx'}
foreach ($signal in $cases.Keys) {
    $destination = "$root/counterexample-$signal"
    $result = Run "failed-$signal" COUNTEREXAMPLE 0 ($proof + @($signal,'0','--evidence-dir',$destination))
    if (!$result.source_replayed -or $result.signals.a -cne $cases[$signal] -or $result.signals.($signal) -cne '1' -or
        (Test-Path -LiteralPath $destination)) {
        throw "Expected a replayed $($cases[$signal]) counterexample with no proof directory."
    }
}
$prefix = "$root/proof-zero"
$null = Run wrong-claim REJECTED 2 ($verify + @('alias_zero','0000','--evidence-dir',$prefix))
$null = Run wrong-width REJECTED 2 ($proof + @('zero','0','--evidence-dir',"$root/wrong"))
$null = Run overwrite REJECTED 2 ($proof + @('zero','0000','--evidence-dir',$prefix))
if ((Hash "$prefix/proof.q3adrat") -cne $evidence.zero) { throw 'Previous evidence was overwritten.' }
$changed = "$root/changed.q3a"
Copy-Item -LiteralPath $project -Destination $changed
Add-Content -LiteralPath $changed -Value '' -Encoding utf8NoBOM
$null = Run changed-manifest REJECTED 2 @('dev-verify-four-state',$changed,'--expect','zero','0000','--evidence-dir',$prefix)
foreach ($file in 'query.cnf','proof.q3adrat') {
    $tampered = "$root/$file-altered"
    Copy-Item -LiteralPath $prefix -Destination $tampered -Recurse
    Add-Content -LiteralPath "$tampered/$file" -Value 'not a proof record' -Encoding utf8NoBOM
    $null = Run "tampered-$file" REJECTED 2 ($verify + @('zero','0000','--evidence-dir',$tampered))
}
$cancel = "$root/cancel"
Set-Content -LiteralPath $cancel -Value 'cancel' -Encoding ascii
$null = Run cancelled CANCELLED 1 ($proof + @('zero','0000','--evidence-dir',"$root/cancelled",'--cancel-file',$cancel))
if ((Test-Path -LiteralPath "$root/cancelled") -or @(Get-ChildItem $root -Directory -Filter '.q3a-four-*').Count) {
    throw 'A rejected or cancelled check published or staged unexpected proof evidence.'
}
[ordered]@{
    status = 'FOUR_STATE_SOURCE_SAT_AND_DRAT_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $evidence
    replayed_counterexamples = 2
    rejected_claims_or_artifacts = 6
    cancelled_cases = 1
    source_sha256 = Hash $source
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: five SAT proofs, source regeneration and standalone checking, two replayed X/Z counterexamples, and seven controls.'
