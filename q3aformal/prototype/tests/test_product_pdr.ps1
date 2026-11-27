param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$scratch = New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-pdr-' + [Guid]::NewGuid()))
$root = $scratch.FullName
$project = Join-Path $prototype 'pdr-pipeline.q3a'
$evidence = Join-Path $root 'certificate'
$witness = Join-Path $root 'witness'
$stderr = Join-Path $root 'stderr.txt'

function Check-Result($Code, $Status, $Arguments) {
    $output = & $exe prove @Arguments 2> $stderr
    $actual = $LASTEXITCODE
    $result = $output | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Code / $Status. Got $actual / $output. $(Get-Content $stderr -Raw)"
    }
    $certificate = $result.certificate
    if ($Status -cnotin 'PROVEN', 'UNREACHABLE') {
        if ($null -ne $certificate) { throw "$Status must not advertise checked evidence." }
        return
    }
    $expectedDirectory = $Arguments[[array]::IndexOf($Arguments, '--evidence-dir') + 1]
    if ($certificate.directory -cne $expectedDirectory -or
        $certificate.build_id -cnotmatch '^[a-f0-9]{64}$' -or
        $certificate.checker_id -cne 'q3a-drat-checker-0.2' -or
        ($certificate.obligations.kind -join ',') -cne 'pdr-initiation,pdr-consecution,pdr-safety') {
        throw 'Published PDR descriptor is missing or inconsistent.'
    }
    $invariant = @(Get-Content -LiteralPath (Join-Path $expectedDirectory 'invariant.txt') -TotalCount 2)
    if ($certificate.model_sha256 -cne $invariant[1]) { throw 'PDR descriptor has the wrong model identity.' }
    foreach ($obligation in $certificate.obligations) {
        $stem = $obligation.kind.Substring(4)
        $cnf = (Get-FileHash -LiteralPath (Join-Path $expectedDirectory "$stem.cnf")).Hash.ToLowerInvariant()
        $proof = (Get-FileHash -LiteralPath (Join-Path $expectedDirectory "$stem.q3adrat")).Hash.ToLowerInvariant()
        if ($obligation.query_sha256 -cne $cnf -or $obligation.proof_sha256 -cne $proof) {
            throw "PDR descriptor has the wrong file hashes for $stem."
        }
    }
}

function Check-Certificate($Code, $Property, $Message, $Manifest = $project, $Directory = $evidence) {
    $output = & $exe verify-pdr $Manifest --property $Property --evidence-dir $Directory 2>&1
    if ($LASTEXITCODE -ne $Code -or ($output -join [char]10) -notmatch $Message) {
        throw "Expected certificate result $Code / $Message. Got $LASTEXITCODE / $output"
    }
}

try {
    Check-Result 1 'NOT_1_INDUCTIVE' @($project, '--engine', 'induction', '--property', 'p_safe',
        '--k', '1', '--output-prefix', (Join-Path $root 'plain-induction'))
    Check-Result 0 'PROVEN' @($project, '--evidence-dir', $evidence)
    $invariant = @(Get-Content -LiteralPath (Join-Path $evidence 'invariant.txt'))
    if ($invariant.Count -le 3) { throw 'Expected a nonempty learned inductive invariant.' }
    foreach ($obligation in 'initiation', 'consecution', 'safety') {
        foreach ($extension in 'cnf', 'q3adrat') {
            if (-not (Test-Path -LiteralPath (Join-Path $evidence "$obligation.$extension"))) {
                throw "Missing $obligation.$extension."
            }
        }
    }
    Check-Certificate 0 'p_safe' 'Q3A_PDR_CERTIFICATE VERIFIED'
    Check-Certificate 3 'p_bad' 'model or property identity does not match'
    Check-Result 3 'ENGINE_ERROR' @($project, '--evidence-dir', $evidence)
    Check-Certificate 0 'p_safe' 'Q3A_PDR_CERTIFICATE VERIFIED'

    $limited = Join-Path $root 'query-cap-no-certificate'
    $capped = & $exe prove $project --evidence-dir $limited --max-queries 1 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $capped.status -cne 'RESOURCE_LIMIT' -or
        $capped.resource_limit -cne 'search' -or $capped.pdr_configuration.maximum_search_queries -ne 1 -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_PDR_SEARCH_STATS queries=1 cnf_builds=' -or
        $null -ne $capped.certificate -or (Test-Path -LiteralPath $limited)) {
        throw 'Query budget must stop immediately at the configured count and publish no certificate.'
    }
    foreach ($value in '0', '-1', 'invalid', '18446744073709551616') {
        Check-Result 2 'SETUP_ERROR' @($project, '--evidence-dir', $limited, '--max-queries', $value)
        if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'PDR search query limit must be a positive integer') {
            throw "Invalid query cap received the wrong diagnostic: $value."
        }
    }
    Check-Result 2 'SETUP_ERROR' @($project, '--evidence-dir', $limited, '--max-queries', '7', '--max-queries', '8')
    $explicitProof = Join-Path $root 'explicit-query-budget-proof'
    Check-Result 0 'PROVEN' @($project, '--evidence-dir', $explicitProof, '--max-queries', '50000')
    Check-Certificate 0 'p_safe' 'Q3A_PDR_CERTIFICATE VERIFIED' $project $explicitProof
    foreach ($file in (Get-ChildItem -LiteralPath $evidence -File |
        Where-Object Name -CNE 'run-configuration.json')) {
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $explicitProof $file.Name)).Hash) {
            throw "A larger search budget altered a successful certificate: $($file.Name)."
        }
    }
    'PASS: default and explicit PDR search budgets, exact cap, invalid options, and byte-identical checked certificates.'

    $occupied = New-Item -ItemType Directory -Path (Join-Path $root 'occupied')
    Check-Result 3 'ENGINE_ERROR' @($project, '--evidence-dir', $occupied.FullName)
    if (!(Test-Path -LiteralPath $occupied.FullName -PathType Container) -or
        @(Get-ChildItem -LiteralPath $occupied.FullName -Force).Count -ne 0) {
        throw 'PDR altered a pre-existing empty destination.'
    }

    $raced = Join-Path $root 'raced-certificate'
    $writers = @()
    try {
        foreach ($writer in 1, 2) {
            $writers += Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -ArgumentList @(
                'prove', ('"' + $project + '"'), '--evidence-dir', ('"' + $raced + '"')) `
                -RedirectStandardOutput (Join-Path $root "writer-$writer.json") `
                -RedirectStandardError (Join-Path $root "writer-$writer.log")
        }
        foreach ($process in $writers) {
            if (!$process.WaitForExit(30000)) { throw 'A concurrent PDR writer timed out.' }
        }
        $statuses = @(foreach ($writer in 1, 2) {
            (Get-Content -LiteralPath (Join-Path $root "writer-$writer.json") -Raw |
                ConvertFrom-Json).status
        })
        if ((($statuses | Sort-Object) -join ',') -cne 'ENGINE_ERROR,PROVEN') {
            throw "Expected exactly one published PDR certificate: $statuses"
        }
    } finally {
        foreach ($process in $writers) {
            if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
            $process.Dispose()
        }
    }
    Check-Certificate 0 'p_safe' 'Q3A_PDR_CERTIFICATE VERIFIED' $project $raced
    foreach ($certificate in $evidence, $raced) {
        if (@(Get-ChildItem -LiteralPath $certificate -Force).Count -ne 8 -or
            !(Test-Path -LiteralPath (Join-Path $certificate 'run-configuration.json') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $certificate 'proof-body.tmp'))) {
            throw 'Expected the invariant, three queries, three checked proofs and one run configuration.'
        }
    }
    if (@(Get-ChildItem -LiteralPath $root -Filter '.q3apdr-*' -Force).Count -ne 0) {
        throw 'Certificate publication left a temporary directory behind.'
    }
    Write-Output 'PASS: checked certificate publication, concurrent writers and no staging files left behind.'

    foreach ($extension in 'cnf', 'q3adrat') {
        $file = Join-Path $evidence "safety.$extension"
        $original = [IO.File]::ReadAllBytes($file)
        try {
            $mutation = [Text.Encoding]::ASCII.GetBytes('invalid' + [char]10)
            [IO.File]::WriteAllBytes($file, $mutation)
            Check-Certificate 3 'p_safe' 'Q3A_PDR_CERTIFICATE REJECTED'
        } finally {
            [IO.File]::WriteAllBytes($file, $original)
        }
    }
    Check-Certificate 0 'p_safe' 'Q3A_PDR_CERTIFICATE VERIFIED'

    $unused = Join-Path $root 'unused-certificate'
    Check-Result 1 'UNKNOWN' @($project, '--engine', 'pdr', '--property', 'p_bad',
        '--evidence-dir', $unused, '--max-depth', '1')
    Check-Result 0 'FAIL' @($project, '--engine', 'pdr', '--property', 'p_bad',
        '--evidence-dir', $unused, '--bundle-dir', $witness)
    if (Test-Path -LiteralPath $unused) { throw 'A non-proof created certificate files.' }
    if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_PDR_DEPTH 2' -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Expected a replayed failure at depth 2.'
    }
    $reopened = & $exe --verify-bundle $witness
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'PDR witness bundle could not be revalidated.'
    }
    Check-Result 0 'FAIL' @($project, '--engine', 'pdr', '--property', 'p_temporal',
        '--evidence-dir', $unused)
    Check-Result 1 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' @(
        (Join-Path $prototype 'bmc-conflict.q3a'), '--engine', 'pdr', '--property', 'p_assert_a',
        '--evidence-dir', $unused)
    Check-Result 0 'FAIL' @((Join-Path $prototype 'bmc-scalar.q3a'), '--engine', 'pdr',
        '--property', 'p_can_fail', '--evidence-dir', $unused)
    if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_PDR_DEPTH 0') {
        throw 'Expected a depth-zero PDR counterexample.'
    }
    Write-Output 'PASS: nonempty inductive invariant, three DRAT obligations, certificate reopening, corruption rejection, depth limit, replay and assumption contradiction.'

    $coverProject = Join-Path $prototype 'pdr-cover.q3a'
    $coverEvidence = Join-Path $root 'cover-certificate'
    $coverWitness = Join-Path $root 'cover-witness'
    $unusedCover = Join-Path $root 'unused-cover-certificate'
    Check-Result 1 'BOUNDED_COVER_MISS' @($coverProject, '--engine', 'bmc', '--property', 'p_never', '--frames', '8')
    Check-Result 0 'UNREACHABLE' @($coverProject, '--evidence-dir', $coverEvidence)
    Check-Certificate 0 'p_never' 'Q3A_PDR_RESULT UNREACHABLE' $coverProject $coverEvidence
    Check-Certificate 3 'p_hit' 'model or property identity does not match' $coverProject $coverEvidence
    $coverSafety = Join-Path $coverEvidence 'safety.q3adrat'
    $originalCoverSafety = [IO.File]::ReadAllBytes($coverSafety)
    try {
        [IO.File]::Copy((Join-Path $evidence 'safety.q3adrat'), $coverSafety, $true)
        Check-Certificate 3 'p_never' 'Q3A_PDR_CERTIFICATE REJECTED' $coverProject $coverEvidence
    } finally {
        [IO.File]::WriteAllBytes($coverSafety, $originalCoverSafety)
    }
    Check-Certificate 0 'p_never' 'Q3A_PDR_RESULT UNREACHABLE' $coverProject $coverEvidence

    Check-Result 1 'UNKNOWN' @($coverProject, '--engine', 'pdr', '--property', 'p_hit',
        '--evidence-dir', $unusedCover, '--max-depth', '1')
    Check-Result 0 'COVERED' @($coverProject, '--engine', 'pdr', '--property', 'p_hit',
        '--evidence-dir', $unusedCover, '--bundle-dir', $coverWitness, '--trace-signal', 'q2')
    $coverLog = Get-Content -LiteralPath $stderr -Raw
    if ($coverLog -notmatch 'Q3A_PDR_DEPTH 2' -or
        $coverLog -notmatch 'Q3A_BMC_COVER_WITNESS frame=2' -or
        $coverLog -notmatch 'Q3A_BMC_REPLAY VALIDATED') {
        throw "The guarded equality cover must first match at frame 2. $coverLog"
    }
    $reopened = @(& $exe --verify-bundle $coverWitness)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'PDR cover witness bundle did not pass replay verification.'
    }
    Check-Result 0 'COVERED' @($coverProject, '--engine', 'pdr', '--property', 'p_immediate',
        '--evidence-dir', $unusedCover)
    if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_BMC_COVER_WITNESS frame=0') {
        throw 'The overlapped implication should cover at sample zero.'
    }
    Check-Result 0 'COVERED' @($coverProject, '--engine', 'pdr', '--property', 'p_delayed',
        '--evidence-dir', $unusedCover)
    if (Test-Path -LiteralPath $unusedCover) { throw 'A non-proof created cover certificate files.' }

    $checkedProofs = @($evidence, $coverEvidence)
    foreach ($name in 'p_no_vacuity', 'p_same_sample') {
        $path = Join-Path $root $name
        Check-Result 0 'UNREACHABLE' @($coverProject, '--engine', 'pdr', '--property', $name, '--evidence-dir', $path)
        Check-Certificate 0 $name 'Q3A_PDR_RESULT UNREACHABLE' $coverProject $path
        $checkedProofs += $path
    }
    & (Join-Path $PSScriptRoot 'test_drat_independent_full_scan.ps1') -PdrEvidence $checkedProofs
    Write-Output 'PASS: cover hit depth, guarded history, same-sample conjunction, nonvacuous implication, proof binding, and bounded miss distinction.'

    $pipeline = Join-Path $prototype 'benchmark/fixtures/P1_pdr_pipeline6.q3a'
    $pipelineProof = Join-Path $root 'pipeline-proof'
    Check-Result 0 'PROVEN' @($pipeline, '--evidence-dir', $pipelineProof)
    $stats = [regex]::Match((Get-Content -LiteralPath $stderr -Raw),
        'Q3A_PDR_SEARCH_STATS queries=(\d+) cnf_builds=(\d+) state_bits=18 full_state_bits=34 signal_bits=20 full_signal_bits=44')
    if (!$stats.Success -or [int]$stats.Groups[2].Value -ge [int]$stats.Groups[1].Value) {
        throw 'PDR did not reuse its encoding across the pipeline search.'
    }
    Check-Certificate 0 'p_latency' 'Q3A_PDR_CERTIFICATE VERIFIED' $pipeline $pipelineProof
    $fullQuery = Get-Content -LiteralPath (Join-Path $pipelineProof 'consecution.cnf') -TotalCount 1
    $dimensions = [regex]::Match($fullQuery, '^p cnf (\d+) \d+$')
    if (!$dimensions.Success -or [int]$dimensions.Groups[1].Value -lt 88) {
        throw 'The consecution certificate must encode both frames of the complete design.'
    }
    $pipelineWitness = Join-Path $root 'pipeline-witness'
    Check-Result 1 'UNKNOWN' @($pipeline, '--engine', 'pdr', '--property', 'p_mutation',
        '--max-depth', '5', '--evidence-dir', $unused)
    Check-Result 0 'FAIL' @($pipeline, '--engine', 'pdr', '--property', 'p_mutation',
        '--max-depth', '6', '--evidence-dir', $unused, '--bundle-dir', $pipelineWitness)
    $pipelineLog = Get-Content -LiteralPath $stderr -Raw
    if ($pipelineLog -notmatch 'Q3A_PDR_DEPTH 6\b' -or $pipelineLog -notmatch 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Expected a replayed pipeline failure at its first eligible depth.'
    }
    $reopened = @(& $exe --verify-bundle $pipelineWitness)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'The pipeline witness did not reopen.'
    }
    'PASS: reused query encodings, certified six-stage pipeline, and replayed the mutation at depth six.'

    $environment = Join-Path $prototype 'benchmark/fixtures/P1_pdr_cone_environment.q3a'
    $environmentProof = Join-Path $root 'environment-proof'
    Check-Result 0 'PROVEN' @($environment, '--evidence-dir', $environmentProof)
    if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'state_bits=6 full_state_bits=22 signal_bits=9 full_signal_bits=41') {
        throw 'PDR lost the transitive assumption dependency or retained unrelated state.'
    }
    Check-Certificate 0 'p_quiet' 'Q3A_PDR_CERTIFICATE VERIFIED' $environment $environmentProof
    foreach ($test in @(
        @{ Property = 'p_mutation'; Status = 'FAIL' },
        @{ Property = 'c_late'; Status = 'COVERED' }
    )) {
        $environmentWitness = Join-Path $root "$($test.Property)-environment-witness"
        Check-Result 0 $test.Status @($environment, '--engine', 'pdr', '--property', $test.Property,
            '--max-depth', '2', '--evidence-dir', $unused, '--bundle-dir', $environmentWitness)
        $environmentLog = Get-Content -LiteralPath $stderr -Raw
        if ($environmentLog -notmatch 'Q3A_PDR_DEPTH 2\b' -or $environmentLog -notmatch 'Q3A_BMC_REPLAY VALIDATED') {
            throw "Expected an environment-constrained witness at depth two for $($test.Property)."
        }
        $reopened = @(& $exe --verify-bundle $environmentWitness)
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "The environment-constrained witness did not reopen for $($test.Property)."
        }
    }
    & (Join-Path $PSScriptRoot 'test_drat_independent_full_scan.ps1') -PdrEvidence @($pipelineProof, $environmentProof)
    'PASS: reduced search CNF preserved the assumption cone, full DRAT obligations, and replayed witnesses.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), $scratch.Name)
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
