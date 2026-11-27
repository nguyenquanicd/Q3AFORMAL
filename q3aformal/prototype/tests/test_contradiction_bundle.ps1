#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = Join-Path $root 'project.q3a'
@('Q3AFORMAL_PROJECT 2','top finite_environment','source systemverilog "fixture.sv"') |
    Set-Content -LiteralPath $project -Encoding utf8
@'
module finite_environment(input logic clk, output logic [2:0] phase);
    always_ff @(posedge clk) begin
        if (phase < 3'd5) begin
            phase <= phase + 3'd1;
        end
    end
    env_limit: assume property (@(posedge clk) phase < 3'd3);
    p_safe: assert property (@(posedge clk) phase < 3'd3);
    c_one: cover property (@(posedge clk) phase == 3'd1);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'fixture.sv') -Encoding utf8

function Run-Result([string]$Id, [int]$Code, [string[]]$Options) {
    $err = Join-Path $root "$Id.stderr.txt"
    $stdout = @(& $exe @Options 2> $err)
    $actual = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Id.stdout.json") -Encoding utf8
    if ($actual -ne $Code -or $stdout.Count -ne 1) { throw "$Id unexpected result: $stdout $(Get-Content $err -Raw)" }
    $result = $stdout[0] | ConvertFrom-Json
    if ($result.exit_code -ne $Code) { throw "$Id exit code disagrees with JSON." }
    return $result
}

$conflict = 'INCONSISTENT_MODEL_OR_ASSUMPTIONS'
function Test-Archive([string]$Id, $Result, [string]$Engine, [string]$Property, [string]$Path, [int]$Bound=3) {
    if ($Result.status -cne $conflict -or $Result.certificate -or
        $Result.run_configuration.engine -cne $Engine -or $Result.bundle_dir -cne $Path -or
        $Result.properties[0].environment_feasibility.status -cne 'UNSAT' -or
        $Result.properties[0].environment_feasibility.bound -ne $Bound) {
        throw "$Id lost scope, engine provenance or the archive path."
    }
    $record = Get-Content -LiteralPath (Join-Path $Path 'manifest.json') -Raw | ConvertFrom-Json
    if ($record.result.status -cne $conflict -or $record.result.property -cne $Property -or
        $record.command -cne 'bmc' -or $record.queries.Count -ne 1 -or
        $record.queries[0].kind -cne 'model-feasibility' -or $record.queries[0].status -cne 'UNSAT' -or
        @($record.artifacts | Where-Object { $_.role -match 'witness|proof' }).Count) {
        throw "$Id archive contains property evidence or an invalid feasibility record."
    }
    $check = @(& $exe --verify-bundle $Path --require-source-model)
    $check | Set-Content -LiteralPath (Join-Path $root "$Id.verify.txt") -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $check -cnotcontains "Q3A_BUNDLE_BMC_QUERY REVALIDATED status=$conflict bound=$Bound" -or
        $check -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "$Id contradiction was not source-verified."
    }
    return [ordered]@{id=$Id;engine=$Engine;property=$Property;bound=$Bound;model_sha256=$record.model.sha256;
        query_sha256=$record.queries[0].cnf_sha256}
}

$cases = foreach ($case in @(
    @{id='bmc';engine='bmc';property='p_safe';activation=$false},
    @{id='induction';engine='induction';property='p_safe';activation=$false},
    @{id='pdr';engine='pdr';property='p_safe';activation=$false},
    @{id='activation';engine='pdr';property='p_safe';activation=$true},
    @{id='cover';engine='pdr';property='c_one';activation=$false}
)) {
    $path = Join-Path $root "$($case.id)-bundle"
    $certificate = Join-Path $root "$($case.id)-proof"
    $flags = switch ($case.engine) {
        bmc { @('--frames','3') }
        induction { @('--k','3','--output-prefix',$certificate) }
        pdr { @('--max-depth','1','--feasibility-frames','3','--evidence-dir',$certificate) }
    }
    if ($case.activation) { $flags += '--check-activation' }
    $options = @('prove',$project,'--engine',$case.engine,'--property',$case.property) +
        $flags + @('--bundle-dir',$path)
    $result = Run-Result $case.id 1 $options
    if ($case.activation -and $result.run_configuration.goal -cne 'activation') {
        throw 'The contradiction archive dropped the activation request from the originating report.'
    }
    if (Test-Path -LiteralPath $certificate) { throw 'Published a certificate under contradictory assumptions.' }
    Test-Archive $case.id $result $case.engine $case.property $path
}
$plan = Join-Path $root 'batch.q3b'
$batchOutput = Join-Path $root 'batch'
@('Q3AFORMAL_BATCH 2','memory_mib 512','job pdr pdr p_safe 1 30000 feasibility_frames 3',
    'job induction induction p_safe 3 30000') | Set-Content -LiteralPath $plan -Encoding utf8
$batch = Run-Result 'batch' 1 @('prove-batch',$project,'--plan',$plan,'--output-dir',$batchOutput)
if ($batch.status -cne 'INCONCLUSIVE' -or $batch.jobs.Count -ne 2) { throw 'Unexpected batch result.' }
$batchCases = foreach ($job in $batch.jobs) {
    Test-Archive "batch-$($job.id)" $job.result $job.engine 'p_safe' (Join-Path $batchOutput "$($job.result_directory)/bundle")
}
$all = @($cases) + @($batchCases)
if (@($all | Where-Object property -CEQ 'p_safe' | ForEach-Object query_sha256 | Sort-Object -Unique).Count -ne 1 -or
    @($all | ForEach-Object model_sha256 | Sort-Object -Unique).Count -ne 1) {
    throw 'The same source contradiction lowered to different checks.'
}
$limitedBundle = Join-Path $root 'limited-bundle'
$limited = Run-Result limited 1 @('prove',$project,'--engine','pdr','--property','p_safe','--evidence-dir',
    (Join-Path $root 'limited-proof'),'--feasibility-frames','3','--max-queries','1','--bundle-dir',$limitedBundle)
if ($limited.status -cne 'RESOURCE_LIMIT' -or $limited.bundle_dir -or (Test-Path -LiteralPath $limitedBundle)) {
    throw 'An unresolved feasibility query published contradiction evidence.'
}
$sourcePath = Join-Path $root 'fixture.sv'
$sourceText = [IO.File]::ReadAllText($sourcePath)
$initialPath = Join-Path $root 'initial-bundle'
[IO.File]::WriteAllText($sourcePath, $sourceText.Replace(
    "env_limit: assume property (@(posedge clk) phase < 3'd3);",
    "env_limit: assume property (@(posedge clk) 1'b0);"))
$initial = Run-Result initial 1 @('prove',$project,'--engine','pdr','--property','c_one','--evidence-dir',
    (Join-Path $root 'initial-proof'),'--bundle-dir',$initialPath)
$initialCase = Test-Archive initial $initial 'pdr' 'c_one' $initialPath 0
[IO.File]::WriteAllText($sourcePath, $sourceText)
[ordered]@{schema='Q3AFORMAL_CONTRADICTION_BUNDLE_1';executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();
    source_verified_cases=($all + @($initialCase));limited_run_published_bundle=$false} |
 ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: eight initial and delayed contradiction bundles source-revalidate across engines and batch.'
