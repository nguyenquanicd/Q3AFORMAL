#requires -Version 7.0
param([string]$ExecutablePath, [string]$ReportPath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$counter = Join-Path $prototype 'counter4-fail.q3a'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-run-control-' + [Guid]::NewGuid()))).FullName

function Check-Record($Json, $Code, $Record, $Status, [int]$TimeoutMs=1) {
    $parsed = $Json | ConvertFrom-Json
    $loading = ($parsed.timeout_stage -ceq 'source_loading' -or $parsed.cancellation_stage -ceq 'source_loading')
    $expectedProperties = if ($loading -and !$parsed.engine) { 0 } else { 1 }
    if ($Code -ne 1 -or $parsed.exit_code -ne 1 -or $parsed.status -cne $Status -or
        $parsed.properties.Count -ne $expectedProperties -or
        ($expectedProperties -eq 1 -and $parsed.properties[0].status -cne $Status) -or
        $parsed.build_id -cnotmatch '^[0-9a-f]{64}$') {
        throw "Incorrect interrupted result. $Json"
    }
    if ($loading) {
        if ($parsed.PSObject.Properties.Name -ccontains 'source_set_sha256' -or
            $parsed.completed_work.Count -ne 0 -or $parsed.resolved_configuration) {
            throw 'A source-load interruption claimed work that did not finish.'
        }
    } elseif ($parsed.source_set_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $parsed.completed_work -cnotcontains 'project_loaded') {
        throw "A resolved interruption lost its source identity. $Json"
    }
    $saved = (Get-Content -LiteralPath $Record -Raw).TrimEnd()
    if ($saved -cne $Json.TrimEnd()) { throw 'The durable record differed from standard output.' }
    $digest = (Get-FileHash -LiteralPath $Record -Algorithm SHA256).Hash.ToLowerInvariant()
    $opened = @(& $exe --verify-bundle $Record)
    if ($LASTEXITCODE -ne 0 -or $opened -cnotcontains 'Q3A_RUN_RECORD_STATUS STRUCTURE_VALID' -or
        $opened -cnotcontains "Q3A_RUN_RECORDED_STATUS $Status" -or
        $opened -cnotcontains "Q3A_RUN_RECORD_SHA256 $digest" -or
        $opened -cnotcontains 'Q3A_RUN_EVIDENCE INTERRUPTION_METADATA_ONLY' -or
        ($opened -cmatch '^Q3A_BUNDLE_STATUS|PROVEN|REVALIDATED') -or
        (Get-FileHash -LiteralPath $Record -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
        throw "The unified reader did not reopen $Status as interruption metadata. $opened"
    }
    if ($Status -ceq 'CANCELLED' -and
        ($parsed.cancellation_cause -cne 'cancel_file' -or !$parsed.cancellation_stage)) {
        throw "Missing cancellation cause or stage. $Json"
    }
    if ($Status -ceq 'TIMEOUT' -and ($parsed.timeout_ms -ne $TimeoutMs -or $parsed.elapsed_ms -lt $TimeoutMs -or
        !$parsed.timeout_stage -or $parsed.PSObject.Properties.Name -contains 'cancellation_cause')) {
        throw "Incorrect deadline record. $Json"
    }
}

try {
    $stderr = Join-Path $root 'stderr.txt'
    $flag = Join-Path $root 'cancel request'
    $record = "$flag.result.json"
    $bundle = Join-Path $root 'witness'
    $bmc = @('--engine', 'bmc', '--property', 'p_wraps_to_zero')
    [IO.File]::WriteAllText($flag, '')
    $json = & $exe prove $counter --cancel-file $flag @bmc --frames 1 --bundle-dir $bundle 2> $stderr
    Check-Record $json $LASTEXITCODE $record 'CANCELLED'
    if (($json | ConvertFrom-Json).cancellation_stage -cne 'source_loading') {
        throw 'Pre-cancellation did not stop before project load.'
    }
    $defaultRecord = Join-Path $root 'manifest-selected-cancel.json'
    $defaultManifest = Join-Path $prototype 'pdr-pipeline.q3a'
    $json = & $exe prove $defaultManifest --cancel-file $flag --run-record $defaultRecord --evidence-dir $bundle 2> $stderr
    Check-Record $json $LASTEXITCODE $defaultRecord 'CANCELLED'
    $preflight = $json | ConvertFrom-Json
    if ($preflight.engine -or $preflight.properties.Count -ne 0 -or $preflight.cancellation_stage -cne 'source_loading') {
        throw 'An early interruption inferred a manifest-selected property before loading the manifest.'
    }
    if (Test-Path -LiteralPath $bundle) { throw 'Pre-cancellation published a witness bundle.' }
    $saved = Get-Content -LiteralPath $record -Raw
    $reused = & $exe prove $counter --cancel-file $flag @bmc --frames 1 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $reused.status -cne 'SETUP_ERROR' -or
        (Get-Content -LiteralPath $record -Raw) -cne $saved) {
        throw 'A preexisting record was not preserved.'
    }

    $alias = & $exe prove $counter --cancel-file $flag --run-record $flag @bmc --frames 1 2> $stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $alias.status -cne 'SETUP_ERROR' -or
        (Get-Item -LiteralPath $flag).Length -ne 0) { throw 'The cancellation marker was accepted as an output.' }

    $deadlineRecord = Join-Path $root 'deadline.json'
    $json = & $exe prove $counter --run-record $deadlineRecord --timeout-ms 1 @bmc --frames 10000 --bundle-dir $bundle 2> $stderr
    Check-Record $json $LASTEXITCODE $deadlineRecord 'TIMEOUT'
    if (Test-Path -LiteralPath $bundle) { throw 'A timed-out run published a witness bundle.' }

    $unusedFlag = Join-Path $root 'unused cancel'
    $json = & $exe prove $counter --cancel-file $unusedFlag @bmc --frames 1 2> $stderr
    $normalCode = $LASTEXITCODE
    $normal = $json | ConvertFrom-Json
    if ($normalCode -ne 0 -or $normal.status -cne 'BOUNDED_FAIL' -or
        $normal.completed_work -cnotcontains 'witness_replayed' -or
        (Get-Content -LiteralPath "$unusedFlag.result.json" -Raw).TrimEnd() -cne $json.TrimEnd() -or
        (Test-Path -LiteralPath $unusedFlag)) {
        throw "A cancellation-enabled run without a request did not finish normally. $json"
    }

    $liveFlag = Join-Path $root 'live cancel'
    $liveRecord = Join-Path $root 'live record.json'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $arguments = @('prove', $counter, '--cancel-file', $liveFlag, '--run-record', $liveRecord) +
        $bmc + @('--frames', '10000', '--bundle-dir', $bundle)
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if ($process.WaitForExit(50)) { throw "Run exited before the live cancellation. $($errors.Result)" }
        [IO.File]::WriteAllText($liveFlag, '')
        if (!$process.WaitForExit(15000)) { throw 'Run did not react to the live cancellation.' }
        Check-Record $output.Result $process.ExitCode $liveRecord 'CANCELLED'
        if (Test-Path -LiteralPath $bundle) { throw 'A live-cancelled run published a witness bundle.' }
    } finally {
        if (!$process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
    if (@(Get-ChildItem -LiteralPath $root -Force -Filter '.q3a-record-*').Count -ne 0) {
        throw 'A run record left a staging file.'
    }

    $historical = Join-Path (Split-Path -Parent $prototype) 'evidence/release'
    foreach ($prior in @(
        @{ File = 'run-control-cancelled-2026-11-24.json'; Status = 'CANCELLED' },
        @{ File = 'run-control-timeout-2026-11-24.json'; Status = 'TIMEOUT' }
    )) {
        $archive = Join-Path $historical $prior.File
        Check-Record (Get-Content -LiteralPath $archive -Raw) 1 $archive $prior.Status
    }
    $badRecord = Join-Path $root 'bad.json'
    $pdr = Join-Path $prototype 'benchmark/fixtures/P1_fifo_contract.q3a'
    $resolvedCases = foreach ($case in @(
        @{Engine='bmc'; Project=$counter; Property='p_wraps_to_zero'; Stage='bounded_query'
            Depth='transition_count'; Value=10000; EngineArgs=@('--frames','10000')},
        @{Engine='induction'; Project=$counter; Property='p_wraps_to_zero'; Stage='induction_obligations'
            Depth='induction_depth'; Value=9998; EngineArgs=@('--k','9998','--output-prefix',(Join-Path $root 'ind-proof'))},
        @{Engine='pdr'; Project=$pdr; Property='p_step'; Stage='pdr_search'; Depth='maximum_depth'; Value=12
            ProjectArgs=@('--parameter','DATA_WIDTH','32'); EngineArgs=@('--max-depth','12','--max-queries','50000',
                '--feasibility-frames','3','--evidence-dir',(Join-Path $root 'pdr-proof'))}
    )) {
        $path = Join-Path $root "$($case.Engine)-resolved.json"
        $argsForCase = @('prove',$case.Project) + @($case.ProjectArgs | Where-Object { $_ }) +
            @('--timeout-ms','100','--run-record',$path,'--engine',$case.Engine,'--property',$case.Property) + $case.EngineArgs
        $raw = & $exe @argsForCase 2> $stderr
        Check-Record $raw $LASTEXITCODE $path 'TIMEOUT' 100
        $parsed = $raw | ConvertFrom-Json
        $info = $parsed.resolved_configuration
        $manifestHash = (Get-FileHash -LiteralPath $case.Project).Hash.ToLowerInvariant()
        if ($parsed.timeout_stage -cne $case.Stage -or $parsed.completed_work -cnotcontains 'model_elaborated' -or
            $info.project_manifest_sha256 -cne $manifestHash -or $info.configuration_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $info.($case.Depth) -ne $case.Value -or $info.goal -cne 'safety') {
            throw "The stopped query lost its configuration: $raw"
        }
        if ($case.Engine -ceq 'pdr' -and ($info.maximum_search_queries -ne 50000 -or $info.minimum_feasibility_bound -ne 3)) {
            throw 'The stopped PDR query lost its options.'
        }
        $opened = @(& $exe --verify-bundle $path)
        if ($LASTEXITCODE -ne 0 -or $opened -cnotcontains "Q3A_RUN_RESOLVED_CONFIGURATION_SHA256 $($info.configuration_sha256)") {
            throw 'The reader did not report the saved configuration identity.'
        }
        $malformed = $raw.Replace($info.configuration_sha256, 'bad-digest')
        [IO.File]::WriteAllText($badRecord, $malformed)
        $reopen = @(& $exe --verify-bundle $badRecord 2> $stderr)
        if ($LASTEXITCODE -ne 1 -or $reopen.Count -ne 0) { throw 'The reader accepted malformed configuration metadata.' }
        $parsed
    }
    if ($ReportPath) {
        [ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant(); cases=$resolvedCases} |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    }
    $timed = (Get-Content -LiteralPath $deadlineRecord -Raw).Trim()
    $cancelled = $saved.Trim()
    $mutations = @(
        $timed.Replace('"schema_version":1', '"schema_version":2')
        $timed.Replace('"exit_code":1', '"exit_code":0')
        $timed.Replace('"timeout_ms":1', '"timeout_ms":0')
        ($timed -replace '"elapsed_ms":\d+', '"elapsed_ms":0')
        ($timed -replace '"timeout_stage":"[^"]+"', '"timeout_stage":"pdr_certificate"')
        ('{"source_set_sha256":"non_digest",' + $timed.Substring(1))
        $timed.Replace('"completed_work":[', '"completed_work":["witness_replayed",')
        $timed.Replace('"status":"TIMEOUT"}]}', '"status":"PROVEN"}]}')
        ('{"proof":"fake",' + $timed.Substring(1))
        ('{"status":"CANCELLED",' + $timed.Substring(1))
        $cancelled.Replace('"cancellation_cause":"cancel_file"', '"cancellation_cause":"unknown"')
        ($timed + (' ' * 65536))
    )
    foreach ($mutation in $mutations) {
        [IO.File]::WriteAllText($badRecord, $mutation)
        $result = @(& $exe --verify-bundle $badRecord 2> $stderr)
        if ($LASTEXITCODE -ne 1 -or $result.Count -ne 0) {
            throw "The unified reader accepted invalid interruption metadata. $result"
        }
    }
    'PASS: cancellation and deadline records, current and historical reopen, malformed-record rejection, and staging cleanup.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-run-control-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
