#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$sampled = @'
module witness_demo(input logic clk, input logic d, req);
    logic q;
    always_ff @(posedge clk) begin q <= d; end
    p_bad: assert property (@(posedge clk) (d === 1'bz) |=> (q === 1'b0));
    p_good: assert property (@(posedge clk) (d === 1'bz) |=> (q === 1'bz));
    c_z: cover property (@(posedge clk) (d === 1'bz) |=> (q === 1'bz));
    ENVIRONMENT
endmodule
'@
function Fixture($Name, $Top, $Source) {
    $Source | Set-Content -LiteralPath "$root/$Name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2',('top ' + $Top),('source systemverilog "{0}.sv"' -f $Name),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') | Set-Content -LiteralPath "$root/$Name.q3a" -Encoding utf8NoBOM
}
Fixture comb exact_demo 'module exact_demo(input logic d, output logic q); assign q = d; endmodule'
Fixture sampled witness_demo ($sampled.Replace('ENVIRONMENT',''))
Fixture temporal witness_demo ($sampled.Replace('ENVIRONMENT',
    'a_turn: assume property (@(posedge clk) req |=> !req);'))
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
function Check-Saved($Name, $Status, [int]$Code, [string[]]$Arguments, $Directory) {
    $saved = Run "save-$Name" $Status $Code (@('dev-prove-four-state') + $Arguments + @('--save-witness'))
    $replay = Run "reopen-$Name" $Status $Code (@('dev-verify-four-state') + $Arguments)
    if ($saved.witness_revalidated -or !$replay.witness_revalidated -or !$replay.source_replayed -or
        $saved.witness_sha256 -cne $replay.witness_sha256 -or
        $saved.witness_sha256 -cne (Hash "$Directory/counterexample.q3awitness") -or
        (ConvertTo-Json -InputObject $saved.signals -Compress) -cne (ConvertTo-Json -InputObject $replay.signals -Compress)) {
        throw "Counterexample did not reopen independently for $Name."
    }
    $replay
}

$comb = @("$root/comb.q3a",'--expect','q','0','--evidence-dir')
$combDir = "$root/comb-witness"
$combResult = Check-Saved comb COUNTEREXAMPLE 0 ($comb + @($combDir)) $combDir
if ($combResult.signals.q -ceq '0') { throw 'Invalid exact output counterexample.' }

$seq = @("$root/sampled.q3a",'--property')
$seqDir = "$root/assertion-witness"
$options = $seq + @('p_bad','--evidence-dir',$seqDir,'--steps','1')
$original = Run save-assertion COUNTEREXAMPLE 0 (@('dev-prove-four-state') + $options + @(
    '--save-witness','--vcd',"$root/assertion.vcd"))
$reopened = Run reopen-assertion COUNTEREXAMPLE 0 (@('dev-verify-four-state') + $options + @('--vcd',"$root/reopened.vcd"))
if ($original.witness_revalidated -or !$reopened.witness_revalidated -or $reopened.attempt_sample -ne 0 -or
    $reopened.antecedent_end_sample -ne 0 -or $reopened.failure_sample -ne 1 -or $reopened.trace[0].d -cne 'z' -or
    $reopened.trace[1].q -cne 'z' -or $original.witness_sha256 -cne $reopened.witness_sha256 -or
    $reopened.witness_sha256 -cne (Hash "$seqDir/counterexample.q3awitness") -or
    $original.vcd_sha256 -cne $reopened.vcd_sha256 -or $reopened.vcd_sha256 -cne (Hash "$root/reopened.vcd")) {
    throw 'The sampled counterexample or its waveform could not be reproduced.'
}
$temporalDir = "$root/temporal-witness"
$temporalOptions = @("$root/temporal.q3a",'--property','p_bad','--evidence-dir',$temporalDir,'--steps','1')
$pending = Check-Saved temporal WITNESS_PENDING_ASSUMPTION 1 $temporalOptions $temporalDir
if (!$pending.assumption_boundary_open) { throw 'Provisional status was lost during replay.' }

$proof = "$root/good-proof"
$null = Run good BOUNDED_PASS 0 (@('dev-prove-four-state') + $seq + @(
    'p_good','--evidence-dir',$proof,'--steps','1','--save-witness'))
$null = Run good-reopen REVALIDATED 0 (@('dev-verify-four-state') + $seq + @(
    'p_good','--evidence-dir',$proof,'--steps','1'))
if ((Test-Path "$proof/counterexample.q3awitness") -or !(Test-Path "$proof/proof.q3adrat")) {
    throw 'A successful assertion did not emit the normal proof evidence.'
}
$unpublished = "$root/unsaved"
$null = Run unsaved COUNTEREXAMPLE 0 (@('dev-prove-four-state') + $comb + @($unpublished))
if (Test-Path $unpublished) { throw 'Default counterexample handling changed unexpectedly.' }

$null = Run wrong-bound REJECTED 2 (@('dev-verify-four-state') + $seq + @(
    'p_bad','--evidence-dir',$seqDir,'--steps','2'))
$null = Run wrong-property REJECTED 2 (@('dev-verify-four-state') + $seq + @(
    'p_good','--evidence-dir',$seqDir,'--steps','1'))
$null = Run wrong-kind REJECTED 2 (@('dev-verify-four-state') + $seq + @(
    'c_z','--evidence-dir',$seqDir,'--steps','1'))
$null = Run preserve-existing REJECTED 2 (@('dev-prove-four-state') + $options + @('--save-witness'))
$null = Run repeated-option REJECTED 2 (@('dev-prove-four-state') + $options + @('--save-witness','--save-witness'))
if ((Hash "$seqDir/counterexample.q3awitness") -cne $reopened.witness_sha256) { throw 'An existing witness was overwritten.' }

function ReviewModified($Name, $Content, [string[]]$Arguments, $ExpectedMessage) {
    $dir = (New-Item -ItemType Directory -Path "$root/$Name").FullName
    [IO.File]::WriteAllText("$dir/counterexample.q3awitness", $Content)
    $null = Run $Name REJECTED 2 (@('dev-verify-four-state') + $Arguments + @($dir))
    if ((Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw) -notlike "*$ExpectedMessage*") {
        throw "Incorrect rejection reason for $Name."
    }
}
$raw = [IO.File]::ReadAllText("$combDir/counterexample.q3awitness")
ReviewModified no-failure ($raw.Substring(0,$raw.Length - 2) + '0' + [char]10) $comb 'agrees with the claimed output'
ReviewModified trailing-data ($raw + 'bad') $comb 'unexpected data following'
ReviewModified wrong-schema ($raw.Replace('WITNESS_1','WITNESS_9')) $comb 'identity differs'
ReviewModified truncated ($raw.Substring(0,$raw.Length - 1)) $comb 'sample boundary'

$changed = (New-Item -ItemType Directory -Path "$root/assumption-mutation").FullName
$lines = [IO.File]::ReadAllLines("$temporalDir/counterexample.q3awitness")
$lines[3] = $lines[3].Substring(0,1) + '1'
$lines[4] = $lines[4].Substring(0,1) + '1'
[IO.File]::WriteAllText("$changed/counterexample.q3awitness", ($lines -join [char]10) + [char]10)
$null = Run assumption-mutation REJECTED 2 @('dev-verify-four-state',"$root/temporal.q3a",'--property','p_bad',
    '--evidence-dir',$changed,'--steps','1')
if ((Get-Content "$root/assumption-mutation.stderr.txt" -Raw) -notmatch 'violates an assumption') {
    throw 'Tampered witness should fail replay against the finite environment constraints.'
}

[ordered]@{
    status = 'FOUR_STATE_COUNTEREXAMPLE_ARTIFACTS_QUALIFIED'
    executable_sha256 = Hash $exe
    witnesses_sha256 = @($combResult.witness_sha256,$reopened.witness_sha256,$pending.witness_sha256)
    vcd_sha256 = $reopened.vcd_sha256
    rejected_cases = 10
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: three saved counterexamples, deterministic VCD replay, checked proof compatibility and ten targeted rejections.'
