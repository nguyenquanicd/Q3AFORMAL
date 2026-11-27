#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$fixture="$repo/prototype/benchmark/fixtures/P1_elastic_pipeline.sv"
Copy-Item -LiteralPath $fixture -Destination "$root/pipeline.sv"
$project="$root/design.q3a"
@('Q3AFORMAL_PROJECT 2','top p1_elastic_pipeline','source systemverilog "pipeline.sv"','parameter DROP_STALL 1') |
    Set-Content -LiteralPath $project
$plan="$root/points.q3b"
$points=@('Q3AFORMAL_BATCH 3','memory_mib 768',
    'job inductive induction p_hold 2 30000 param DROP_STALL 0',
    'job pdr-zero pdr p_hold 12 30000 param DROP_STALL 0 max_queries 50000',
    'job pdr-one pdr p_hold 12 30000 max_queries 50000 param DROP_STALL 1',
    'job bounded bmc p_hold 8 30000 param DROP_STALL 1',
    'job inherited bmc p_hold 8 30000')
$points | Set-Content -LiteralPath $plan

function Invoke-Sweep([string]$Name,[int]$Code,[string]$Status,[string]$Target,
    [string[]]$Options,[string]$UsePlan=$plan) {
    $output=@(& $exe prove-batch $project --plan $UsePlan --output-dir $Target @Options 2> "$root/$Name.stderr.txt")
    $actual=$LASTEXITCODE
    $output|Set-Content -LiteralPath "$root/$Name.json"
    if($actual -ne $Code -or $output.Count -ne 1){
        throw "Unexpected sweep result $Name $actual $output $(Get-Content -Raw "$root/$Name.stderr.txt")"
    }
    $value=$output[0]|ConvertFrom-Json
    if($value.exit_code -ne $Code -or $value.status -cne $Status){throw "Unexpected sweep status $Name"}
    return $value
}

$sequence='PROVEN,PROVEN,FAIL,BOUNDED_FAIL,BOUNDED_FAIL'
foreach($workers in 1,2) {
    $directory="$root/run-$workers"
    $mode=@('--workers',[string]$workers)
    $report=Invoke-Sweep "run-$workers" 0 COMPLETED $directory ($mode+'--checkpoint')
    if($report.plan_schema_version -ne 3 -or $report.workers -ne $workers -or
       ($report.jobs.result.status -join ',') -cne $sequence){throw "Sweep order or proof differs with $workers workers"}
    $cfg=$report.jobs.result.run_configuration
    if((($cfg|ForEach-Object {$_.parameters.DROP_STALL}) -join ',') -cne '0,0,1,1,1' -or
       $cfg[0].source_set_sha256 -cne $cfg[1].source_set_sha256 -or
       $cfg[2].source_set_sha256 -cne $cfg[3].source_set_sha256 -or
       $cfg[3].source_set_sha256 -cne $cfg[4].source_set_sha256 -or
       $cfg[0].source_set_sha256 -ceq $cfg[2].source_set_sha256 -or
       @($cfg.project_manifest_sha256|Sort-Object -Unique).Count -ne 1 -or
       $report.jobs[1].parameter_overrides.DROP_STALL -cne '0' -or
       $report.jobs[4].parameter_overrides.PSObject.Properties.Name -contains 'DROP_STALL') {
        throw 'Declared values, effective parameters or source hashes disagree.'
    }
    $resume=Invoke-Sweep "resume-$workers" 0 COMPLETED $directory ($mode+'--resume')
    if(@($resume.jobs|Where-Object reused).Count -ne 5 -or ($resume.jobs.result.status -join ',') -cne $sequence -or
       ($workers -eq 2 -and $resume.peak_workers -ne 0)){throw 'A sweep point did not independently reopen'}
}

# Refresh the checkpoint digest for a result from the other point on the same PDR query.
$folder="$root/run-1/attempt-1/job-pdr-zero"
$marker="$folder/checkpoint.commit"
$record="$folder/result.json"
$original=[IO.File]::ReadAllBytes($record)
$originalCommit=[IO.File]::ReadAllBytes($marker)
$other=[IO.File]::ReadAllText("$root/run-1/attempt-1/job-pdr-one/result.json")
$sha=[Security.Cryptography.SHA256]
$encoding=[Text.Encoding]::UTF8
$identity=(Get-FileHash -LiteralPath "$root/run-1/checkpoint.identity").Hash.ToLowerInvariant()
$payload=[Convert]::ToHexString($sha::HashData($encoding.GetBytes($other.TrimEnd([char]10)))).ToLowerInvariant()
$binding=@($identity,'1','pdr-zero',$payload) -join [char]10
$commit=[Convert]::ToHexString($sha::HashData($encoding.GetBytes($binding))).ToLowerInvariant()
try {
    [IO.File]::WriteAllText($record,$other)
    [IO.File]::WriteAllText($marker,$commit+[char]10)
    $null=Invoke-Sweep wrong-point 3 ENGINE_ERROR "$root/run-1" @('--resume')
    if((Get-Content -Raw "$root/wrong-point.stderr.txt") -notmatch 'checkpoint result does not identify'){
        throw 'The swapped PDR result did not fail its effective configuration check.'
    }
} finally {
    [IO.File]::WriteAllBytes($record,$original)
    [IO.File]::WriteAllBytes($marker,$originalCommit)
}

$changed="$root/changed.q3b"
$points -creplace '^job bounded (.*) DROP_STALL 1$','job bounded $1 DROP_STALL 0'|Set-Content -LiteralPath $changed
$null=Invoke-Sweep changed-plan 2 SETUP_ERROR "$root/run-1" @('--resume') $changed

$invalid="$root/invalid.q3b"
foreach($row in 'job dup bmc p_hold 8 30000 param DROP_STALL 0 param DROP_STALL 1','job missing bmc p_hold 8 30000 param DROP_STALL'){
    @('Q3AFORMAL_BATCH 3','memory_mib 384',$row)|Set-Content -LiteralPath $invalid
    $null=Invoke-Sweep malformed 2 SETUP_ERROR "$root/invalid-out" @('--checkpoint') $invalid
}
@('Q3AFORMAL_BATCH 2','memory_mib 384',$points[2])|Set-Content -LiteralPath $invalid
$null=Invoke-Sweep legacy-extension-rejected 2 SETUP_ERROR "$root/invalid-out" @('--checkpoint') $invalid
if(Test-Path -LiteralPath "$root/invalid-out"){throw 'A malformed parameter point wrote job evidence.'}

$unknown="$root/unknown.q3b"
@('Q3AFORMAL_BATCH 3','memory_mib 768',
  'job invalid induction p_hold 2 30000 param DOES_NOT_EXIST 5',$points[2])|Set-Content -LiteralPath $unknown
$proof=Invoke-Sweep unknown-parameter 2 SETUP_ERROR "$root/unknown-out" @() $unknown
if(($proof.jobs.result.status -join ',') -cne 'ELABORATION_ERROR,PROVEN'){
    throw 'A rejected parameter point disrupted the following valid point.'
}

$project="$root/two-parameters.q3a"
@('Q3AFORMAL_PROJECT 2','top sweep_pair','source systemverilog "two-parameters.sv"')|Set-Content -LiteralPath $project
@'
module sweep_pair #(parameter ENABLE=0, parameter MODE=0)
    (input logic clk, input logic d, output logic y);
    assign y = ((MODE == 0) && (ENABLE != 0)) ? d : 1'b0;
    p_safe: assert property (@(posedge clk) !y);
endmodule
'@|Set-Content -LiteralPath "$root/two-parameters.sv"
$two="$root/two-parameters.q3b"
@('Q3AFORMAL_BATCH 3','memory_mib 384',
    'job both-fail bmc p_safe 0 30000 param ENABLE 1 param MODE 0',
    'job both-prove induction p_safe 1 30000 param ENABLE 1 param MODE 1')|Set-Content -LiteralPath $two
$multi=Invoke-Sweep two-parameters 0 COMPLETED "$root/two-parameter-run" @('--checkpoint','--workers','2') $two
if(($multi.jobs.result.status -join ',') -cne 'BOUNDED_FAIL,PROVEN' -or
    $multi.jobs[1].result.run_configuration.parameters.ENABLE -cne '1' -or
    $multi.jobs[1].result.run_configuration.parameters.MODE -cne '1'){
    throw 'Multiple assignments were not applied together to the specified point.'
}
$multiReplay=Invoke-Sweep two-parameters-reopened 0 COMPLETED "$root/two-parameter-run" @('--resume','--workers','2') $two
if(@($multiReplay.jobs|Where-Object reused).Count -ne 2){throw 'Two-parameter points failed revalidation.'}

[ordered]@{
    status='PASS'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    points_per_mode=5
    serial_and_parallel_statuses=$sequence.Split(',')
    resumed_points=10
    checkpoint_rejected_wrong_configuration=$true
    manifest_default_and_point_override_verified=$true
    isolated_invalid_parameter=$true
    multi_parameter_points_revalidated=2
}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$root/qualification.json"
'PASS: version 3 sweep isolation, exact parameter bindings, process dispatch and source revalidation.'
