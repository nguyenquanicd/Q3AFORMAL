#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$checker="$repo/prototype/bin/q3aformal-proofcheck.exe"
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project="$root/design.q3a"
$rtl="$root/design.sv"
@('Q3AFORMAL_PROJECT 2','top subsystem','source systemverilog "design.sv"') | Set-Content -LiteralPath $project
$source=@'
module producer(input logic i, output logic request);
    assign request = 1'b0;
endmodule
module consumer(input logic request, output logic response);
    assign response = request;
endmodule
module subsystem(input logic clk, input logic i, output logic done);
    logic request, response;
    producer p(i, request);
    consumer c(request, response);
    assign done = response;
    p_produce: assert property (@(posedge clk) !request);
    p_consume: assert property (@(posedge clk) !response);
    p_top: assert property (@(posedge clk) !done);
endmodule
'@
$source | Set-Content -LiteralPath $rtl
$plan="$root/plan.q3c"
@('Q3AFORMAL_COMPOSITION 1','prove p_produce','prove p_consume p_produce',
  'cut p_consume request','target p_top p_consume') | Set-Content -LiteralPath $plan
$proof="$root/checked composition"

function Invoke-Composition([string]$Id,[int]$Code,[string]$Status,[string]$PlanPath=$plan,
    [string]$EvidencePath="$root/$Id", [switch]$Verify,[string[]]$Options=@()) {
    $command=if($Verify){'verify-composition'}else{'prove-composition'}
    $directory=if($Verify){'--evidence-dir'}else{'--output-dir'}
    $lines=@(& $exe $command $project --plan $PlanPath $directory $EvidencePath @Options 2> "$root/$Id.stderr.txt")
    $actual=$LASTEXITCODE
    $lines | Set-Content -LiteralPath "$root/$Id.json"
    if($actual -ne $Code -or $lines.Count -ne 1){throw "Unexpected result for $Id $actual $lines $(Get-Content -Raw "$root/$Id.stderr.txt")"}
    $report=$lines[0] | ConvertFrom-Json
    if($report.status -cne $Status){throw "Unexpected status for $Id $lines"}
    return $report
}

$created=Invoke-Composition created 0 PROVEN $plan $proof
$reopened=Invoke-Composition reopened 0 REVALIDATED $plan $proof -Verify
if($created.checked_obligations -ne 5 -or $reopened.checked_obligations -ne 5 -or
   $created.context_sha256 -cne $reopened.context_sha256 -or $created.environment_feasibility -cne 'INITIAL_SAT'){
    throw 'Composition did not retain every checked obligation.'
}
$names=@('node-1-initial','node-1-step','node-2-initial','node-2-step','target')
foreach($name in $names){
    $check=@('--check-drat',"$proof/$name.cnf","$proof/$name.q3adrat",
        '--model-sha256',$created.context_sha256,'--query-kind',"composition-$name")
    $standalone=@(& $checker @check)
    if($LASTEXITCODE -ne 0 -or $standalone -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED'){
        throw "Standalone checker rejected $name"
    }
    $standalone | Set-Content -LiteralPath "$root/$name.verifier.txt"
}
$whole=& $exe prove $project --engine pdr --property p_top --max-depth 8 --evidence-dir "$root/whole-proof" 2> "$root/whole.stderr.txt"
if($LASTEXITCODE -ne 0 -or ($whole|ConvertFrom-Json).status -cne 'PROVEN'){throw "Whole-model proof disagreed $whole"}
$whole | Set-Content -LiteralPath "$root/whole.json"

$noImport="$root/no-import.q3c"
(Get-Content -LiteralPath $plan) -creplace '^prove p_consume p_produce$','prove p_consume' | Set-Content -LiteralPath $noImport
$gap=Invoke-Composition missing-import 1 UNPROVEN $noImport
if($gap.obligation -cne 'node-2-initial' -or (Test-Path -LiteralPath "$root/missing-import/composition.complete")){
    throw 'An undischarged cut published a completion marker.'
}
$cycle="$root/cycle.q3c"
@('Q3AFORMAL_COMPOSITION 1','prove p_produce p_consume','prove p_consume p_produce','target p_top p_consume') |
    Set-Content -LiteralPath $cycle
$null=Invoke-Composition cycle 2 REJECTED $cycle
if(Test-Path -LiteralPath "$root/cycle"){throw 'A cyclic graph wrote evidence.'}
$changedPlan="$root/changed.q3c"
Copy-Item -LiteralPath $plan -Destination $changedPlan
Add-Content -LiteralPath $changedPlan -Value ''
$null=Invoke-Composition changed-plan 2 REJECTED $changedPlan $proof -Verify

foreach($suffix in 'cnf','q3adrat'){
    $path="$proof/target.$suffix"
    $original=[IO.File]::ReadAllBytes($path)
    Copy-Item -LiteralPath "$proof/node-1-step.$suffix" -Destination $path -Force
    try {$null=Invoke-Composition "swapped-$suffix" 2 REJECTED $plan $proof -Verify}
    finally {[IO.File]::WriteAllBytes($path,$original)}
}

$source.Replace("assign request = 1'b0;",'assign request = i;') | Set-Content -LiteralPath $rtl
$null=Invoke-Composition changed-rtl 2 REJECTED $plan $proof -Verify
$negative=Invoke-Composition changed-producer 1 UNPROVEN
if($negative.obligation -cne 'node-1-initial'){throw 'Unexpected failing producer obligation.'}
$source.Replace('assign done = response;','assign done = !response;') | Set-Content -LiteralPath $rtl
$negative=Invoke-Composition changed-wiring 1 UNPROVEN
if($negative.obligation -cne 'target'){throw 'Incorrect target discharge accepted.'}
$counterexample=& $exe prove $project --engine bmc --property p_top --frames 2 --bundle-dir "$root/concrete-witness" 2> "$root/concrete-witness.stderr.txt"
if ($LASTEXITCODE -ne 0 -or ($counterexample|ConvertFrom-Json).status -cne 'BOUNDED_FAIL') {
    throw 'The concrete wrong wiring did not yield a top-level counterexample.'
}
$counterexample | Set-Content -LiteralPath "$root/concrete-witness.json"
$verification=@(& $exe --verify-bundle "$root/concrete-witness" --require-source-model)
if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
    throw 'The concrete top-level counterexample failed source-required replay.'
}
$verification | Set-Content -LiteralPath "$root/concrete-witness-verifier.txt"

$assumptions=@'
    env_a: assume property (@(posedge clk) i);
    env_b: assume property (@(posedge clk) !i);
    p_produce: assert property
'@
$source.Replace('    p_produce: assert property',$assumptions.TrimEnd()) | Set-Content -LiteralPath $rtl
$null=Invoke-Composition contradictory-environment 1 INCONSISTENT_ENVIRONMENT

$history=@'
module subsystem(input logic clk, input logic i, output logic captured);
    always_ff @(posedge clk) begin
        captured <= i;
    end
    p_copy: assert property (@(posedge clk) captured == $past(i));
    p_top: assert property (@(posedge clk) captured == $past(i));
endmodule
'@
$history | Set-Content -LiteralPath $rtl
$historyPlan="$root/history.q3c"
@('Q3AFORMAL_COMPOSITION 1','prove p_copy','target p_top p_copy') | Set-Content -LiteralPath $historyPlan
$historyResult=Invoke-Composition history 0 PROVEN $historyPlan
$null=Invoke-Composition history-reopen 0 REVALIDATED $historyPlan "$root/history" -Verify
$history.Replace('captured <= i','captured <= !i') | Set-Content -LiteralPath $rtl
$negative=Invoke-Composition changed-next-state 1 UNPROVEN $historyPlan
if($negative.obligation -cne 'node-1-step'){throw 'Incorrect next-state update did not fail the inductive step.'}

$source | Set-Content -LiteralPath $rtl
$null=Invoke-Composition restored 0 REVALIDATED $plan $proof -Verify
$flag="$root/cancel"
New-Item -ItemType File -Path $flag | Out-Null
$null=Invoke-Composition cancelled 1 CANCELLED -Options @('--cancel-file',$flag)
$null=Invoke-Composition memory 1 RESOURCE_LIMIT -Options @('--memory-mib','1')
[ordered]@{
    status='PASS'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    subsystem_obligations=$created.checked_obligations
    independently_verified=$names.Count
    history_obligations=$historyResult.checked_obligations
    concrete_witness_replayed=$true
    rejected=@('missing import','cycle','changed plan','swapped CNF','swapped proof','changed RTL',
        'changed producer','changed wiring','contradictory environment','incorrect next state','cancel','memory limit')
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$root/qualification.json"
'PASS: source-derived proof composition, guarded sequential step and independent DRAT checks.'
