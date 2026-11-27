#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$fixtures=(Resolve-Path (Join-Path $PSScriptRoot 'fixtures/phase2')).Path
$project="$fixtures/p2_transport_subsystem.q3a"
$composition="$fixtures/p2_transport_subsystem.q3c"
$batch="$fixtures/p2_transport_subsystem.q3b"
$refinement="$fixtures/p2_transport_encoded.q3a"
$mapping="$fixtures/p2_transport_equivalence.q3e"
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$inputs=Get-ChildItem -LiteralPath $fixtures -File |
    Where-Object Name -in 'p2_transport_subsystem.q3a','p2_transport_subsystem.sv','p2_transport_subsystem.q3c',
        'p2_transport_subsystem.q3b','p2_transport_encoded.q3a','p2_transport_encoded.sv','p2_transport_equivalence.q3e' |
    Sort-Object Name
$identity=[ordered]@{}
foreach($item in $inputs){$identity[$item.Name]=(Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant()}
if($identity.Count -ne 7){throw 'Phase 2 fixture roster differs'}

function Invoke-Product([string]$Name,[string]$Status,[string[]]$Options) {
    $result=@(& $exe @Options 2> "$root/$Name.stderr.txt")
    $code=$LASTEXITCODE
    $result|Set-Content -LiteralPath "$root/$Name.json"
    if($code -ne 0 -or $result.Count -ne 1){throw "Unexpected result for $Name $code $result"}
    $report=$result[0]|ConvertFrom-Json
    if($report.status -cne $Status){throw "Expected $Status for $Name, got $($report.status)"}
    return $report
}

$whole=Invoke-Product monolithic PROVEN @('prove',$project,'--engine','induction','--property','p_subsystem',
    '--k','1','--output-prefix',"$root/monolithic",'--bundle-dir',"$root/monolithic-bundle")
$wholeVerification=@(& $exe --verify-bundle "$root/monolithic-bundle" --require-source-model)
if($LASTEXITCODE -ne 0 -or $wholeVerification -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED'){throw 'Monolithic evidence rejected'}
$wholeVerification|Set-Content -LiteralPath "$root/monolithic.verifier.txt"

$composed=Invoke-Product composed PROVEN @('prove-composition',$project,'--plan',$composition,'--output-dir',"$root/composed")
$reopened=Invoke-Product composed-reopened REVALIDATED @('verify-composition',$project,'--plan',$composition,
    '--evidence-dir',"$root/composed")
$wholeManifest=Get-Content -Raw "$root/monolithic-bundle/manifest.json"|ConvertFrom-Json
if($reopened.checked_obligations -ne 9 -or $reopened.model_sha256 -cne $wholeManifest.model.sha256 -or
    $composed.context_sha256 -cne $reopened.context_sha256){throw 'Composed and monolithic proofs disagree on source model or status'}

$batchRuns=foreach($workers in 1,2){
    $out="$root/batch-$workers"
    $args=@('prove-batch',$project,'--plan',$batch,'--output-dir',$out,'--workers',[string]$workers)
    $ran=Invoke-Product "batch-$workers" COMPLETED ($args+'--checkpoint')
    $resume=Invoke-Product "batch-$workers-reopened" COMPLETED ($args+'--resume')
    if($ran.jobs.Count -ne 4 -or ($ran.jobs.result.status -join ',') -cne 'PROVEN,PROVEN,PROVEN,PROVEN' -or
        @($resume.jobs|Where-Object reused).Count -ne 4 -or $resume.plan_sha256 -cne $ran.plan_sha256){
        throw "Batch $workers workers differs from the source job contract."
    }
    [ordered]@{workers=$workers; proved=$ran.jobs.Count; revalidated=4}
}

$equivalence=Invoke-Product equivalent EQUIVALENT @('check-equivalence',$project,$refinement,'--plan',$mapping,
    '--output-dir',"$root/equivalence")
$eqVerified=Invoke-Product equivalent-reopened CERTIFICATE_REVALIDATED @('verify-equivalence',$project,$refinement,
    '--plan',$mapping,'--evidence-dir',"$root/equivalence")
if($eqVerified.scope -cne 'MATCHED_INITIAL_STATES' -or
    $eqVerified.context_sha256 -cne $equivalence.context_sha256 -or !$eqVerified.state_certificate_model_sha256){
    throw 'Matched-state encoded proof was not revalidated.'
}
foreach($item in $inputs){
    if((Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant() -cne $identity[$item.Name]){
        throw "Workload input changed: $($item.Name)"
    }
}
[ordered]@{status='FUNCTIONAL_PREFLIGHT_PASSED';executable_sha256=(Get-FileHash $exe).Hash.ToLowerInvariant();
    workload_sha256=$identity;monolithic='REVALIDATED';composition_obligations=9;batch=@($batchRuns);
    equivalence_scope=$eqVerified.scope;measurement='FUNCTIONAL_CHECK_ONLY'
}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath "$root/qualification.json"
'PASS: shared subsystem RTL qualified for functional monolithic, composed, batch and equivalence workloads.'
