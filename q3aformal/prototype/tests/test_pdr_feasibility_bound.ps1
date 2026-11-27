#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = Join-Path $root 'project.q3a'
@('Q3AFORMAL_PROJECT 2','top finite_environment','source systemverilog "fixture.sv"') |
    Set-Content -LiteralPath $manifest -Encoding utf8
@'
module finite_environment(input logic clk, output logic [2:0] phase);
    always_ff @(posedge clk) begin
        if (phase < 3'd5) phase <= phase + 3'd1;
    end
    env_limit: assume property (@(posedge clk) phase < 3'd3);
    p_safe: assert property (@(posedge clk) phase < 3'd3);
    c_one: cover property (@(posedge clk) phase == 3'd1);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'fixture.sv') -Encoding utf8

$allowedCounts = foreach ($bound in 0..4) {
    $legal = 0
    foreach ($initial in 0..7) {
        $phase = $initial
        $valid = $true
        for ($sample = 0; $sample -le $bound; ++$sample) {
            if ($phase -ge 3) { $valid = $false; break }
            if ($phase -lt 5) { ++$phase }
        }
        if ($valid) { ++$legal }
    }
    $legal
}
if (($allowedCounts -join ',') -cne '3,2,1,0,0') { throw 'Unexpected independent state enumeration.' }

function Run-Command([string]$Id, [int]$Exit, [string[]]$Options) {
    $err = Join-Path $root "$Id.stderr.txt"
    $lines = @(& $exe @Options 2> $err)
    $actual = $LASTEXITCODE
    $lines | Set-Content -LiteralPath (Join-Path $root "$Id.stdout.json") -Encoding utf8
    if ($actual -ne $Exit -or $lines.Count -ne 1) {
        throw "$Id expected exit $Exit, got $actual. $lines $(Get-Content $err -Raw)"
    }
    $result = $lines[0] | ConvertFrom-Json
    if ($result.exit_code -ne $Exit) { throw "$Id returned a different JSON exit code." }
    return $result
}

function Assert-Scope($Result, [int]$Bound, [string]$Status, [int]$Minimum) {
    $environment = $Result.properties[0].environment_feasibility
    $expected = if ($allowedCounts[$Bound] -gt 0) { 'SAT' } else { 'UNSAT' }
    $scope = if ($Bound -eq 0) { 'INITIAL_SAMPLE' } else { 'FINITE_PREFIX' }
    if ($Result.status -cne $Status -or $environment.status -cne $expected -or
        $environment.bound -ne $Bound -or $environment.scope -cne $scope -or
        $Result.run_configuration.minimum_feasibility_bound -ne $Minimum) {
        throw "Expected $Status / $expected through $Bound. $($Result | ConvertTo-Json -Depth 8 -Compress)"
    }
    return $environment
}

$conflict = 'INCONSISTENT_MODEL_OR_ASSUMPTIONS'
$cases = foreach ($case in @(
    @{id='default';property='p_safe';bound=0;minimum=0;status='PROVEN';exit=0;flags=@()},
    @{id='prefix-two';property='p_safe';bound=2;minimum=2;status='PROVEN';exit=0;flags=@('--feasibility-frames','2')},
    @{id='conflict-three';property='p_safe';bound=3;minimum=3;status=$conflict;exit=1;flags=@('--feasibility-frames','3')},
    @{id='cover-prefix';property='c_one';bound=2;minimum=2;status='COVERED';exit=0;flags=@('--feasibility-frames','2')},
    @{id='cover-conflict';property='c_one';bound=4;minimum=4;status=$conflict;exit=1;flags=@('--feasibility-frames','4')},
    @{id='capped';property='p_safe';bound=0;minimum=3;status='RESOURCE_LIMIT';exit=1;
        flags=@('--feasibility-frames','3','--max-queries','1')}
)) {
    $proof = Join-Path $root "$($case.id)-proof"
    $record = Join-Path $root "$($case.id).json"
    $options = @('prove',$manifest,'--run-record',$record,'--engine','pdr','--property',$case.property,
        '--max-depth','1','--evidence-dir',$proof) + $case.flags
    $result = Run-Command $case.id $case.exit $options
    $environment = Assert-Scope $result $case.bound $case.status $case.minimum
    $written = (Get-Content -LiteralPath $record -Raw).TrimEnd()
    if ($written -cne (Get-Content -LiteralPath (Join-Path $root "$($case.id).stdout.json") -Raw).TrimEnd()) {
        throw 'Persisted run record differs from the emitted result.'
    }
    if ($case.exit -ne 0 -and ((Test-Path -LiteralPath $proof) -or $result.certificate -or $result.bundle_dir)) {
        throw 'An inconsistent or limited result published property evidence.'
    }
    if ($case.status -ceq 'PROVEN') {
        $check = @(& $exe verify-pdr $manifest --property $case.property --evidence-dir $proof)
        if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw 'The feasibility precheck changed certificate verification.'
        }
    }
    [ordered]@{id=$case.id;status=$result.status;environment=$environment}
}

$plan = Join-Path $root 'batch.q3b'
@('Q3AFORMAL_BATCH 2','memory_mib 512',
    'job dead pdr p_safe 1 30000 feasibility_frames 3 max_queries 30',
    'job capped pdr p_safe 1 30000 max_queries 1 feasibility_frames 3') |
    Set-Content -LiteralPath $plan -Encoding utf8
$batch = Run-Command batch 1 @('prove-batch',$manifest,'--plan',$plan,'--output-dir',(Join-Path $root 'batch'))
if ($batch.status -cne 'INCONCLUSIVE' -or $batch.jobs.Count -ne 2 -or
    @($batch.jobs | Where-Object feasibility_frames -ne 3).Count) { throw 'Unexpected batch scope.' }
$null = Assert-Scope $batch.jobs[0].result 3 $conflict 3
$null = Assert-Scope $batch.jobs[1].result 0 RESOURCE_LIMIT 3
$invalidBatch = foreach ($case in @(
    @{id='version-one';version=1;job='job bad pdr p_safe 1 30000 feasibility_frames 3'},
    @{id='wrong-engine';version=2;job='job bad bmc p_safe 1 30000 feasibility_frames 3'},
    @{id='duplicate-batch';version=2;job='job bad pdr p_safe 1 30000 feasibility_frames 0 feasibility_frames 2'}
)) {
    $invalidPlan = Join-Path $root "$($case.id).q3b"
    $destination = Join-Path $root "$($case.id)-output"
    @("Q3AFORMAL_BATCH $($case.version)",'memory_mib 512',$case.job) |
        Set-Content -LiteralPath $invalidPlan -Encoding utf8
    $result = Run-Command $case.id 2 @('prove-batch',$manifest,'--plan',$invalidPlan,'--output-dir',$destination)
    if ($result.status -cne 'SETUP_ERROR' -or (Test-Path -LiteralPath $destination)) {
        throw "Expected batch setup rejection for $($case.id)."
    }
    $case.id
}

$invalid = foreach ($case in @(
    @{id='negative';options=@('--feasibility-frames','-1')},
    @{id='too-deep';options=@('--feasibility-frames','129')},
    @{id='duplicate';options=@('--feasibility-frames','0','--feasibility-frames','2')},
    @{id='missing';options=@('--feasibility-frames')}
)) {
    $result = Run-Command $case.id 2 (@('prove',$manifest,'--engine','pdr','--property','p_safe',
        '--evidence-dir',(Join-Path $root 'unused')) + $case.options)
    if ($result.status -cne 'SETUP_ERROR') { throw "Expected PDR setup rejection for $($case.id)." }
    $case.id
}
[ordered]@{schema='Q3AFORMAL_STATEFUL_FEASIBILITY_PREFIX_1';executable_sha256=(Get-FileHash $exe).Hash.ToLowerInvariant();
    legal_initial_states_by_bound=$allowedCounts;single_runs=@($cases);batch_statuses=@($batch.jobs.result.status);
    rejected_options=@($invalid);rejected_batch_options=@($invalidBatch)} | ConvertTo-Json -Depth 7 |
    Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: stateful PDR prefix checks, boundary scopes, witness replay, batch options and invalid option rejection.'
