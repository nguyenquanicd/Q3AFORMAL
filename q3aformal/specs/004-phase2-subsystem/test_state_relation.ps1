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
$rtl="$root/implementation.sv"
@('Q3AFORMAL_PROJECT 2','top gold','source systemverilog "reference.sv"')|Set-Content -LiteralPath $ref
@('Q3AFORMAL_PROJECT 2','top gate_image','source systemverilog "implementation.sv"')|Set-Content -LiteralPath $imp
@'
module gold(input logic clk, input logic rst, input logic [1:0] d, output logic [1:0] y);
    always_ff @(posedge clk) begin
        if (rst) y <= 2'b00;
        else y <= d;
    end
endmodule
'@|Set-Content -LiteralPath "$root/reference.sv"
$source=@'
module gate_image(input logic ck, input logic reset, input logic [1:0] value, output logic [1:0] result);
    logic [1:0] encoded, shadow;
    always_ff @(posedge ck) begin
        if (reset) begin
            encoded <= 2'b11;
            shadow <= 2'b00;
        end else begin
            encoded <= ~value;
            shadow <= value;
        end
    end
    assign result = ~encoded;
endmodule
'@
$source|Set-Content -LiteralPath $rtl
$prefix=@('Q3AFORMAL_EQUIVALENCE 1','clock clk ck','input rst reset','input d value','output y result')
$plan="$root/invert.q3e"
($prefix+@('reset rst high','state y encoded invert'))|Set-Content -LiteralPath $plan
$equal="$root/equal.q3e"
($prefix+@('reset rst high','state y shadow equal'))|Set-Content -LiteralPath $equal
$badInitialization="$root/bad-initialization.q3e"
($prefix+@('reset rst high','state y encoded equal'))|Set-Content -LiteralPath $badInitialization
$allInitial="$root/all-initial.q3e"
($prefix+@('initial independent','state y encoded invert'))|Set-Content -LiteralPath $allInitial
$outputOnly="$root/output-only.q3e"
($prefix+'reset rst high')|Set-Content -LiteralPath $outputOnly
$badBinding="$root/non-state.q3e"
($prefix+@('reset rst high','state d encoded invert'))|Set-Content -LiteralPath $badBinding

function Invoke-Relation([string]$Name,[int]$ExpectedCode,[string]$ExpectedStatus,[string]$UsePlan=$plan,
    [string]$Evidence="$root/$Name",[switch]$Verify) {
    $command=if($Verify){'verify-equivalence'}else{'check-equivalence'}
    $option=if($Verify){'--evidence-dir'}else{'--output-dir'}
    $out=@(& $exe $command $ref $imp --plan $UsePlan $option $Evidence 2> "$root/$Name.stderr")
    $actual=$LASTEXITCODE
    $out|Set-Content -LiteralPath "$root/$Name.json"
    if($actual -ne $ExpectedCode -or $out.Count -ne 1){throw "Unexpected result $Name $actual $out $(Get-Content -Raw "$root/$Name.stderr")"}
    $report=$out[0]|ConvertFrom-Json
    if($report.status -cne $ExpectedStatus){throw "Unexpected status $Name $out"}
    return $report
}

$proof=Invoke-Relation invert 0 EQUIVALENT
$replay=Invoke-Relation invert-proof-reopen 0 CERTIFICATE_REVALIDATED $plan "$root/invert" -Verify
if($proof.state_certificate_model_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
   (Get-Content -LiteralPath "$root/invert/state-certificate/invariant.txt" -TotalCount 3)[2] -cne '__q3a_state_relation' -or
   (Get-Content -LiteralPath "$root/invert/certificate/invariant.txt" -TotalCount 3)[2] -cne '__q3a_equivalence' -or
   $replay.state_certificate_model_sha256 -cne $proof.state_certificate_model_sha256){
    throw 'State relation and output proofs lost their separate identities.'
}
$equalProof=Invoke-Relation equal 0 EQUIVALENT $equal
$null=Invoke-Relation equal-reopen 0 CERTIFICATE_REVALIDATED $equal "$root/equal" -Verify
foreach($case in @(
    @{directory='invert/state-certificate';digest=$proof.state_certificate_model_sha256;name='invert-state'},
    @{directory='invert/certificate';digest=$proof.certificate_model_sha256;name='invert-output'},
    @{directory='equal/state-certificate';digest=$equalProof.state_certificate_model_sha256;name='equal-state'}
)){
    foreach($kind in 'initiation','consecution','safety'){
        $file="$root/$($case.directory)/$kind"
        $out=@(& $checker --check-drat "$file.cnf" "$file.q3adrat" --model-sha256 $case.digest --query-kind "pdr-$kind")
        if($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED'){throw "Standalone proof failed for $file"}
        $out|Set-Content -LiteralPath "$root/$($case.name)-$kind.verifier"
    }
}

$init=Invoke-Relation bad-init 0 STATE_RELATION_VIOLATED $badInitialization
if($init.frame -ne 1 -or $init.failed_obligation -cne 'STATE_INITIALIZATION' -or
    $init.mismatches[0].relation -cne 'equal' -or (Test-Path -LiteralPath "$root/bad-init/certificate")){
    throw 'A reset initialization error was accepted or mislabeled.'
}
$null=Invoke-Relation bad-init-reopen 0 STATE_WITNESS_REVALIDATED $badInitialization "$root/bad-init" -Verify
$all=Invoke-Relation independent 0 STATE_RELATION_VIOLATED $allInitial
if($all.frame -ne 0 -or $all.failed_obligation -cne 'STATE_INITIALIZATION'){throw 'Matching states were inferred at startup.'}
$null=Invoke-Relation invalid-binding 2 REJECTED $badBinding

$stateProof="$root/invert/state-certificate/safety.q3adrat"
$original=[IO.File]::ReadAllBytes($stateProof)
Copy-Item -LiteralPath "$root/invert/certificate/safety.q3adrat" -Destination $stateProof -Force
try {$null=Invoke-Relation substituted-proof 2 REJECTED $plan "$root/invert" -Verify}
finally {[IO.File]::WriteAllBytes($stateProof,$original)}

$source.Replace('shadow <= value;','shadow <= ~value;')|Set-Content -LiteralPath $rtl
$preserve=Invoke-Relation bad-step 0 STATE_RELATION_VIOLATED $equal
if($preserve.frame -ne 2 -or $preserve.failed_obligation -cne 'STATE_PRESERVATION' -or
    $preserve.mismatches[0].implementation_signal -cne 'implementation.shadow' -or
    (Test-Path -LiteralPath "$root/bad-step/certificate")){throw 'A later relation violation was accepted or mislabeled.'}
$null=Invoke-Relation bad-step-reopened 0 STATE_WITNESS_REVALIDATED $equal "$root/bad-step" -Verify
$null=Invoke-Relation still-output-equivalent 0 EQUIVALENT $outputOnly
$null=Invoke-Relation stale-state-proof 2 REJECTED $plan "$root/invert" -Verify
$source.Replace('assign result = ~encoded;','assign result = encoded;')|Set-Content -LiteralPath $rtl
$outputFailure=Invoke-Relation output-fails-after-state-proof 0 NOT_EQUIVALENT
if($outputFailure.frame -ne 1 -or $outputFailure.state_certificate_model_sha256 -cnotmatch '^[0-9a-f]{64}$'){
    throw 'An independently valid relation hid an output mismatch.'
}
$failureRoot="$root/output-fails-after-state-proof"
$null=Invoke-Relation output-failure-reopened 0 WITNESS_REVALIDATED $plan $failureRoot -Verify
Rename-Item -LiteralPath "$failureRoot/state-certificate" -NewName 'state-certificate.saved'
try {$null=Invoke-Relation missing-state-proof 2 REJECTED $plan $failureRoot -Verify}
finally {Rename-Item -LiteralPath "$failureRoot/state-certificate.saved" -NewName 'state-certificate'}
$source|Set-Content -LiteralPath $rtl
$null=Invoke-Relation restored 0 CERTIFICATE_REVALIDATED $plan "$root/invert" -Verify
[ordered]@{
    status='PASS'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    independently_checked_obligations=9
    state_types=@('two-bit equality','two-bit inversion')
    failed_initial_samples=@($all.frame,$init.frame)
    failed_preservation_sample=$preserve.frame
    preserved_output_equivalence_after_state_mutation=$true
    independently_replayed_state_witnesses=2
    output_failure_after_valid_state_proof=$outputFailure.frame
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$root/qualification.json"
'PASS: explicit state correspondence, separate output and state proof, initialization, preservation and replay.'
