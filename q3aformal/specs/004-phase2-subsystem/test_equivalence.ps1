#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$checker="$repo/prototype/bin/q3aformal-proofcheck.exe"
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$ref="$root/ref.q3a"
$imp="$root/imp.q3a"
$rightRtl="$root/implementation.sv"
@('Q3AFORMAL_PROJECT 2','top reference','source systemverilog "reference.sv"') |
    Set-Content -LiteralPath $ref
@('Q3AFORMAL_PROJECT 2','top implementation','source systemverilog "implementation.sv"') |
    Set-Content -LiteralPath $imp
@'
module reference(input logic clk, input logic rst, input logic d, output logic y);
    always_ff @(posedge clk) begin
        if (rst) y <= 1'b0;
        else y <= d;
    end
endmodule
'@ | Set-Content -LiteralPath "$root/reference.sv"
$impl=@'
module implementation(input logic clock, input logic reset, input logic value, output logic result);
    logic encoded;
    always_ff @(posedge clock) begin
        if (reset) encoded <= 1'b1;
        else encoded <= !value;
    end
    assign result = !encoded;
endmodule
'@
$impl | Set-Content -LiteralPath $rightRtl
$plan="$root/reset.q3e"
$planLines=@('Q3AFORMAL_EQUIVALENCE 1','clock clk clock','input rst reset','input d value',
  'output y result','reset rst high')
$planLines | Set-Content -LiteralPath $plan
$proof="$root/proof with spaces"

function Invoke-Check([string]$Id,[int]$Code,[string]$Status,[string]$PlanPath=$plan,
    [string]$EvidencePath="$root/$Id", [switch]$Verify,[string[]]$Options=@()) {
    $command=if($Verify){'verify-equivalence'}else{'check-equivalence'}
    $directory=if($Verify){'--evidence-dir'}else{'--output-dir'}
    $lines=@(& $exe $command $ref $imp --plan $PlanPath $directory $EvidencePath @Options 2> "$root/$Id.stderr.txt")
    $actual=$LASTEXITCODE
    $lines | Set-Content -LiteralPath "$root/$Id.json"
    if($actual -ne $Code -or $lines.Count -ne 1){throw "Unexpected result for $Id $actual $lines $(Get-Content -Raw "$root/$Id.stderr.txt")"}
    $report=$lines[0] | ConvertFrom-Json
    if($report.status -cne $Status){throw "Unexpected status for $Id $lines"}
    return $report
}

$proved=Invoke-Check proved 0 EQUIVALENT $plan $proof
$checked=Invoke-Check rechecked 0 CERTIFICATE_REVALIDATED $plan $proof -Verify
if($proved.scope -cne 'AFTER_FIRST_RESET_EDGE' -or $checked.context_sha256 -cne $proved.context_sha256 -or
   $checked.certificate_model_sha256 -cne $proved.certificate_model_sha256){throw 'Certificate does not bind the exact product model.'}
foreach($name in 'initiation','consecution','safety'){
    $args=@('--check-drat',"$proof/certificate/$name.cnf","$proof/certificate/$name.q3adrat",
        '--model-sha256',$proved.certificate_model_sha256,'--query-kind',"pdr-$name")
    $out=@(& $checker @args)
    if($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED'){throw "Standalone checker rejected $name"}
    $out|Set-Content -LiteralPath "$root/$name.verifier.txt"
}
$independent="$root/independent.q3e"
$planLines -creplace '^reset rst high$','initial independent' | Set-Content -LiteralPath $independent
$initial=Invoke-Check initial-pairs 0 NOT_EQUIVALENT $independent
if($initial.scope -cne 'INDEPENDENT_INITIAL_STATES' -or $initial.frame -ne 0){throw 'Independent initial states were silently matched.'}
$null=Invoke-Check initial-replay 0 WITNESS_REVALIDATED $independent "$root/initial-pairs" -Verify

$changedPlan="$root/changed-plan.q3e"
$planLines -creplace '^reset rst high$','reset rst low' | Set-Content -LiteralPath $changedPlan
$null=Invoke-Check changed-reset-scope 2 REJECTED $changedPlan $proof -Verify
$invalid="$root/incomplete.q3e"
$planLines | Where-Object {$_ -cne 'input d value'} | Set-Content -LiteralPath $invalid
$null=Invoke-Check incomplete-map 2 REJECTED $invalid
$planLines -creplace '^output y result$','output y value' | Set-Content -LiteralPath $invalid
$null=Invoke-Check wrong-direction 2 REJECTED $invalid

$body="$proof/certificate/safety.q3adrat"
$original=[IO.File]::ReadAllBytes($body)
Copy-Item -LiteralPath "$proof/certificate/consecution.q3adrat" -Destination $body -Force
try {$null=Invoke-Check changed-certificate 2 REJECTED $plan $proof -Verify}
finally {[IO.File]::WriteAllBytes($body,$original)}

$impl.Replace('else encoded <= !value;','else encoded <= value;') | Set-Content -LiteralPath $rightRtl
$null=Invoke-Check stale-proof 2 REJECTED $plan $proof -Verify
$witness=Invoke-Check wrong-update 0 NOT_EQUIVALENT
if($witness.frame -lt 2 -or $witness.mismatches.Count -ne 1 -or
   $witness.mismatches[0].reference_value -ceq $witness.mismatches[0].implementation_value){
    throw 'Mutation was not localized to a real sampled output difference.'
}
$null=Invoke-Check wrong-update-replay 0 WITNESS_REVALIDATED $plan "$root/wrong-update" -Verify
$trace="$root/wrong-update/paired-witness.txt"
$save=[IO.File]::ReadAllBytes($trace)
$sidecar="$trace.sha256"
$saveDigest=[IO.File]::ReadAllBytes($sidecar)
Add-Content -LiteralPath $trace -Value '0'
try {$null=Invoke-Check wrong-digest 2 REJECTED $plan "$root/wrong-update" -Verify}
finally {[IO.File]::WriteAllBytes($trace,$save)}

$rows=[Text.Encoding]::UTF8.GetString($save).Split([char]10)
$values=$rows[3].TrimEnd().Split()
if($values[1] -cne '1'){throw 'Expected first sampled reset input to be high.'}
$values[1]='0'
$rows[3]=($values -join ' ')+' '
[IO.File]::WriteAllText($trace,($rows -join [char]10))
$digest=(Get-FileHash -LiteralPath $trace).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($sidecar,$digest+[char]10)
try {$null=Invoke-Check invalid-reset-trace 2 REJECTED $plan "$root/wrong-update" -Verify}
finally {
    [IO.File]::WriteAllBytes($trace,$save)
    [IO.File]::WriteAllBytes($sidecar,$saveDigest)
}

$impl | Set-Content -LiteralPath $rightRtl
$null=Invoke-Check restored 0 CERTIFICATE_REVALIDATED $plan $proof -Verify
$delay=@'
module implementation(input logic clock, input logic reset, input logic value, output logic result);
    logic encoded, delayed;
    always_ff @(posedge clock) begin
        if (reset) begin
            encoded <= 1'b1;
            delayed <= 1'b1;
        end else begin
            encoded <= !value;
            delayed <= encoded;
        end
    end
    assign result = !delayed;
endmodule
'@
$delay | Set-Content -LiteralPath $rightRtl
$latency=Invoke-Check extra-cycle 0 NOT_EQUIVALENT
if($latency.frame -lt 2){throw 'The latency mismatch occurred before the justified observation.'}
$null=Invoke-Check extra-cycle-replay 0 WITNESS_REVALIDATED $plan "$root/extra-cycle" -Verify

$impl.Replace('input logic value','input logic signed value') | Set-Content -LiteralPath $rightRtl
$null=Invoke-Check signedness 2 REJECTED
if ((Get-Content -Raw "$root/signedness.stderr.txt") -notmatch 'invalid equivalence port binding') {
    throw 'Signedness was not rejected by the equivalence port map.'
}
$leftRtl="$root/reference.sv"
$leftSource=[IO.File]::ReadAllBytes($leftRtl)
@'
module reference(input logic clk, input logic rst, input logic d, output logic y);
    assign y = d;
endmodule
'@ | Set-Content -LiteralPath $leftRtl
@'
module implementation(input logic clock, input logic reset, input logic value, output logic result);
    assign result = (value & 1'b1);
endmodule
'@ | Set-Content -LiteralPath $rightRtl
try {
    $combinational=Invoke-Check independent-equivalent 0 EQUIVALENT $independent
    if ($combinational.scope -cne 'INDEPENDENT_INITIAL_STATES'){throw 'Wrong combinational proof scope.'}
    $null=Invoke-Check independent-equivalent-recheck 0 CERTIFICATE_REVALIDATED $independent "$root/independent-equivalent" -Verify
} finally {
    [IO.File]::WriteAllBytes($leftRtl,$leftSource)
    $impl | Set-Content -LiteralPath $rightRtl
}

$flag="$root/cancel"
New-Item -ItemType File -Path $flag | Out-Null
$null=Invoke-Check cancelled 1 CANCELLED -Options @('--cancel-file',$flag)
$null=Invoke-Check memory-limited 1 RESOURCE_LIMIT -Options @('--memory-mib','1')
[ordered]@{
    status='PASS'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    standalone_obligations=3
    proof_scope=$proved.scope
    independent_initial_counterexample=$initial.frame
    changed_update_counterexample=$witness.frame
    paired_trace_rechecked=$true
    extra_cycle_counterexample=$latency.frame
    independently_initialized_combinational_equivalence=$combinational.status
    rejected=@('changed reset scope','incomplete map','wrong direction','different signedness','changed certificate',
        'stale RTL proof','witness digest','refreshed digest with invalid reset','cancel','memory limit')
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$root/qualification.json"
'PASS: mapped sequential equivalence, independent initial states, replayed two-design mismatch and standalone proof.'
