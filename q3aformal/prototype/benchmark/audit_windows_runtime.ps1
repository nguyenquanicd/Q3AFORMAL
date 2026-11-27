param(
    [string]$Objdump = 'objdump',
    [string]$Output,
    [string]$PrototypeDirectory = (Split-Path -Parent $PSScriptRoot),
    [switch]$PackageProfile,
    [switch]$BatchProfile,
    [switch]$CurrentProductProfile
)

$ErrorActionPreference = 'Stop'
if (($BatchProfile -or $CurrentProductProfile) -and !$PackageProfile) {
    throw 'BatchProfile and CurrentProductProfile require PackageProfile.'
}
$prototypeRoot = (Resolve-Path -LiteralPath $PrototypeDirectory).ProviderPath
$windowsPath = [Environment]::GetFolderPath('Windows')
$systemPath = [Environment]::SystemDirectory
$objdumpPath = (Get-Command $Objdump -CommandType Application).Source
$allowedImports = @(
    'bcrypt.dll', 'kernel32.dll', 'ucrtbase.dll',
    'api-ms-win-crt-convert-l1-1-0.dll', 'api-ms-win-crt-filesystem-l1-1-0.dll',
    'api-ms-win-crt-environment-l1-1-0.dll', 'api-ms-win-crt-heap-l1-1-0.dll',
    'api-ms-win-crt-locale-l1-1-0.dll', 'api-ms-win-crt-math-l1-1-0.dll',
    'api-ms-win-crt-private-l1-1-0.dll', 'api-ms-win-crt-runtime-l1-1-0.dll',
    'api-ms-win-crt-stdio-l1-1-0.dll', 'api-ms-win-crt-string-l1-1-0.dll',
    'api-ms-win-crt-time-l1-1-0.dll', 'api-ms-win-crt-utility-l1-1-0.dll'
)

$nativeGuiImports = @('comdlg32.dll', 'gdi32.dll', 'user32.dll')

function Invoke-Isolated([string]$Name, [string]$Arguments, [int]$ExpectedExit = 0) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($PackageProfile) { Join-Path $prototypeRoot "bin/$Name" } else { Join-Path $scratch $Name }
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $scratch
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PATH'] = "$systemPath;$windowsPath"
    foreach ($policy in 'Q3A_MEMORY_LIMIT_MIB', 'Q3A_MEMORY_RESERVE_MIB', 'Q3A_SCRATCH_DIR') {
        [void]$start.EnvironmentVariables.Remove($policy)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "$Name $Arguments exceeded 30 seconds."
        }
        if ($process.ExitCode -ne $ExpectedExit) {
            throw "$Name $Arguments exited $($process.ExitCode). $($stderr.Result) $($stdout.Result)"
        }
        return $stdout.Result
    } finally {
        $process.Dispose()
    }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('q3a-runtime-audit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $inventory = foreach ($name in @('q3aformal-sourcecheck.exe', 'q3aformal-proofcheck.exe')) {
        $copy = Join-Path $scratch $name
        Copy-Item -LiteralPath (Join-Path $prototypeRoot "bin/$name") -Destination $copy
        $dump = (& $objdumpPath -p $copy) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -or $dump -notmatch 'file format pei-x86-64' -or
            $dump -notmatch '(?im)^Entry d 0000000000000000 00000000 Delay Import Directory\s*$') {
            throw "Expected a Windows x64 executable with an empty delay-import directory for $name."
        }
        $imports = @([regex]::Matches($dump, '(?im)^\s*DLL Name:\s*(\S+)') |
            ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
        $allowedForExecutable = $allowedImports
        if ($name -ceq 'q3aformal-sourcecheck.exe') {
            $allowedForExecutable += $nativeGuiImports
            $guiImports = @($imports | Where-Object { $_ -cin $nativeGuiImports })
            if ($guiImports.Count -gt 0 -and $guiImports.Count -ne $nativeGuiImports.Count) {
                throw 'The native debug client has an incomplete Windows interface dependency set.'
            }
        }
        $unexpected = @($imports | Where-Object { $_ -notin $allowedForExecutable })
        if ($imports.Count -eq 0 -or $unexpected.Count -gt 0) {
            throw "Invalid or unexpected DLL imports for $name. Imports: $($imports -join ', ')."
        }
        [ordered]@{
            name = $name
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $copy).Hash.ToLowerInvariant()
            format = 'PE x64'
            delay_imports = $false
            direct_imports = $imports
        }
    }

    $vector = 'corpus/source-model-vectors/pdr_pipeline.sv'
    New-Item -ItemType Directory -Path (Join-Path $scratch (Split-Path -Parent $vector)) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $prototypeRoot $vector) -Destination (Join-Path $scratch $vector)
    Copy-Item -LiteralPath (Join-Path $prototypeRoot 'pdr-pipeline.q3a') -Destination $scratch
    $assertionArguments = 'prove pdr-pipeline.q3a'
    if ($PackageProfile) { $assertionArguments += ' --run-record assertion-proof.json' }
    $assertionArguments += ' --evidence-dir certificate'
    $proof = Invoke-Isolated 'q3aformal-sourcecheck.exe' $assertionArguments
    $assertionResult = $proof | ConvertFrom-Json
    if ($assertionResult.status -cne 'PROVEN') {
        throw "Isolated PDR run did not report PROVEN. $proof"
    }
    $recheck = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'verify-pdr pdr-pipeline.q3a --property p_safe --evidence-dir certificate'
    if ($recheck -notmatch '(?m)^Q3A_PDR_CERTIFICATE VERIFIED\s*$') {
        throw "Isolated PDR verification did not report acceptance. $recheck"
    }

    if ($PackageProfile) {
        $coverVector = 'corpus/source-model-vectors/pdr_cover.sv'
        Copy-Item -LiteralPath (Join-Path $prototypeRoot $coverVector) -Destination (Join-Path $scratch $coverVector)
        Copy-Item -LiteralPath (Join-Path $prototypeRoot 'pdr-cover.q3a') -Destination $scratch
        $cover = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'prove pdr-cover.q3a --evidence-dir cover-proof'
        $coverCheck = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'verify-pdr pdr-cover.q3a --property p_never --evidence-dir cover-proof'
        if (($cover | ConvertFrom-Json).status -cne 'UNREACHABLE' -or
            $coverCheck -notmatch '(?m)^Q3A_PDR_RESULT UNREACHABLE\s*$') {
            throw 'Isolated cover unreachability proof or verification failed.'
        }
        $hit = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'prove pdr-cover.q3a --engine pdr --property p_hit --evidence-dir unused --bundle-dir hit'
        $hitCheck = Invoke-Isolated 'q3aformal-sourcecheck.exe' '--verify-bundle hit'
        if (($hit | ConvertFrom-Json).status -cne 'COVERED' -or
            $hitCheck -notmatch '(?m)^Q3A_BUNDLE_STATUS REVALIDATED\s*$') {
            throw 'Isolated cover witness or revalidation failed.'
        }
    }

    if ($BatchProfile) {
        $plan = Join-Path $scratch 'batch-pipeline.q3b'
        Copy-Item -LiteralPath (Join-Path $prototypeRoot 'batch-pipeline.q3b') -Destination $plan
        $batch = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'prove-batch pdr-pipeline.q3a --plan batch-pipeline.q3b --output-dir batch' 1
        $batchResult = $batch | ConvertFrom-Json
        if ($batchResult.status -cne 'INCONCLUSIVE' -or $batchResult.exit_code -ne 1 -or
            ($batchResult.jobs.id -join ',') -cne 'prove-safety,find-failure,bounded-safety' -or
            ($batchResult.jobs.result.status -join ',') -cne 'PROVEN,FAIL,BOUNDED_PASS' -or
            $batchResult.build_id -cne $assertionResult.build_id -or
            $batchResult.source_set_sha256 -cne $assertionResult.source_set_sha256 -or
            $batchResult.plan_sha256 -cne (Get-FileHash -LiteralPath $plan).Hash.ToLowerInvariant() -or
            $batch.TrimEnd() -cne (Get-Content -LiteralPath (Join-Path $scratch 'batch/batch.json') -Raw).TrimEnd()) {
            throw 'Isolated batch result, identities, or persisted report failed verification.'
        }
        $batchProof = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'verify-pdr pdr-pipeline.q3a --property p_safe --evidence-dir batch/job-prove-safety/certificate'
        $batchWitness = Invoke-Isolated 'q3aformal-sourcecheck.exe' '--verify-bundle batch/job-find-failure/bundle'
        $batchBound = Invoke-Isolated 'q3aformal-sourcecheck.exe' '--verify-bundle batch/job-bounded-safety/bundle'
        if ($batchProof -notmatch '(?m)^Q3A_PDR_CERTIFICATE VERIFIED\s*$' -or
            $batchWitness -notmatch '(?m)^Q3A_BUNDLE_STATUS REVALIDATED\s*$' -or
            $batchBound -notmatch '(?m)^Q3A_BUNDLE_STATUS REVALIDATED\s*$') {
            throw 'Isolated batch evidence failed verification.'
        }
    }

    if ($CurrentProductProfile) {
        $certificate = $assertionResult.certificate
        $configuration = $assertionResult.pdr_configuration
        if ($certificate.build_id -cne $assertionResult.build_id -or
            $configuration.build_id -cne $assertionResult.build_id -or
            $configuration.source_set_sha256 -cne $assertionResult.source_set_sha256 -or
            $configuration.goal -cne 'safety' -or
            ($certificate.obligations.kind -join ',') -cne 'pdr-initiation,pdr-consecution,pdr-safety') {
            throw 'Packaged PDR result lacks its resolved configuration or checked certificate.'
        }
        foreach ($obligation in $certificate.obligations) {
            $stem = $obligation.kind.Substring(4)
            $cnf = Join-Path $scratch "certificate/$stem.cnf"
            $proofPath = Join-Path $scratch "certificate/$stem.q3adrat"
            if ((Get-FileHash -LiteralPath $cnf).Hash.ToLowerInvariant() -cne $obligation.query_sha256 -or
                (Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -cne $obligation.proof_sha256) {
                throw "Packaged PDR descriptor digest disagreed for $stem."
            }
            $options = "--check-drat certificate/$stem.cnf certificate/$stem.q3adrat" +
                " --model-sha256 $($certificate.model_sha256) --query-kind $($obligation.kind)"
            $standalone = Invoke-Isolated 'q3aformal-proofcheck.exe' $options
            if ($standalone -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED\s*$') {
                throw "Standalone packaged checker rejected $stem."
            }
        }

        $viewInput = @'
$timescale 10ps $end
$scope module top $end
$var wire 4 A channel [3:0] $end
$var wire 4 A channel_alias [0:3] $end
$upscope $end
$enddefinitions $end
#0
bX1 A
#9007199254740993
bZ A
'@
        $viewPath = Join-Path $scratch 'external.vcd'
        Set-Content -LiteralPath $viewPath -Value $viewInput -Encoding ascii
        $html = Invoke-Isolated 'q3aformal-sourcecheck.exe' 'trace view-vcd external.vcd'
        $payload = [regex]::Match($html, '(?s)<script type="application/json" id="trace-data">(?<data>.*?)</script>')
        if (!$payload.Success -or $html -cnotmatch 'id="pin"' -or $html -cnotmatch 'id="comparison"') {
            throw 'Packaged executable could not generate the external viewer.'
        }
        $wave = $payload.Groups['data'].Value | ConvertFrom-Json
        if ($wave.formal_evidence -or !$wave.four_state -or $wave.provenance -cne 'external-non-formal' -or
            ($wave.signals.name -join ',') -cne 'channel,channel_alias' -or
            $wave.samples[1].timestamp -cne '9007199254740993' -or
            $wave.samples[0].changes.Count -ne 2 -or $wave.samples[1].changes.Count -ne 2 -or
            $wave.samples[0].changes[0][1] -cne 'xxx1' -or $wave.samples[0].changes[1][1] -cne 'xxx1' -or
            $wave.samples[1].changes[0][1] -cne 'zzzz' -or $wave.samples[1].changes[1][1] -cne 'zzzz') {
            throw 'Packaged external waveform did not preserve the expected sample values.'
        }
    }

    $hash = 'a' * 64
    [IO.File]::WriteAllLines((Join-Path $scratch 'contradiction.cnf'), @('p cnf 1 2', '1 0', '-1 0'))
    $proofArgs = "contradiction.cnf contradiction.q3adrat --model-sha256 $hash --query-kind bounded-query"
    $created = Invoke-Isolated 'q3aformal-proofcheck.exe' "--create-drat $proofArgs"
    $checked = Invoke-Isolated 'q3aformal-proofcheck.exe' "--check-drat $proofArgs"
    if ($created -notmatch '(?m)^Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED\s*$' -or
        $checked -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED\s*$') {
        throw "Standalone DRAT smoke test did not report creation and acceptance. $created $checked"
    }

    $nativeGui = @($inventory[0].direct_imports | Where-Object { $_ -cin $nativeGuiImports }).Count -eq $nativeGuiImports.Count
    if ($nativeGui -and $BatchProfile) {
        [void](Invoke-Isolated 'q3aformal-sourcecheck.exe' '--qualify-native-gui batch/job-find-failure/bundle gui-session.json')
        if (!(Test-Path -LiteralPath (Join-Path $scratch 'gui-session.json') -PathType Leaf)) {
            throw 'The packaged native GUI did not produce its saved session.'
        }
    }

    $result = [ordered]@{
        schema = 'Q3AFORMAL-WINDOWS-RUNTIME-AUDIT-1'
        fresh_working_directory = $true
        process_path = @('Windows system directory', 'Windows directory')
        executables = @($inventory)
        pdr = 'PROVEN'
        pdr_certificate = 'ACCEPTED'
        standalone_drat_roundtrip = 'ACCEPTED'
    }
    if ($PackageProfile) {
        if ($assertionResult.build_id -cnotmatch '^[0-9a-f]{64}$') {
            throw 'The packaged source executable did not identify its build.'
        }
        $result['source_build_id'] = $assertionResult.build_id
        $result['pdr_cover'] = 'UNREACHABLE'
        $result['pdr_cover_witness'] = 'REVALIDATED'
    }
    if ($BatchProfile) {
        $result['batch_plan_sha256'] = $batchResult.plan_sha256
        $result['batch_exit_code'] = $batchResult.exit_code
        $result['batch_job_statuses'] = @($batchResult.jobs.result.status)
        $result['batch_evidence'] = 'REVALIDATED'
    }
    if ($CurrentProductProfile) {
        $result['pdr_configuration'] = 'RECORDED'
        $result['pdr_artifact_digests'] = 'MATCHED'
        $result['pdr_standalone_drat_obligations'] = $certificate.obligations.Count
        $result['external_vcd_viewer'] = 'GENERATED_AND_PAYLOAD_CHECKED'
        $result['external_vcd_input_sha256'] = (Get-FileHash -LiteralPath $viewPath).Hash.ToLowerInvariant()
    }
    if ($nativeGui -and $BatchProfile) {
        $result['native_debug_gui'] = 'VERIFIED_WINDOW_EVENTS_WITH_SESSION_ROUNDTRIP'
        $result['native_debug_system_imports'] = $nativeGuiImports
    }
    $result = $result | ConvertTo-Json -Depth 5
    if ($Output) {
        Set-Content -LiteralPath $Output -Value $result -Encoding ascii
    }
    $result
} finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ($resolvedScratch -eq $scratch -and (Split-Path -Leaf $scratch) -like 'q3a-runtime-audit-*') {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
