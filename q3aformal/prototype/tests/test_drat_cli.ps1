param(
    [string]$Compiler = 'g++'
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildScript = Join-Path $prototypeRoot 'checker\build.ps1'
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-proof-cli-' + [guid]::NewGuid().ToString('N'))
$executable = "$tempBase.exe"
$cnfPath = "$tempBase.cnf"
$artifactPath = "$tempBase.q3adrat"
$badArtifactPath = "$tempBase.bad.q3adrat"
$wrongCheckerArtifactPath = "$tempBase.wrong-checker.q3adrat"
$satCnfPath = "$tempBase.sat.cnf"
$satArtifactPath = "$tempBase.sat.q3adrat"
$resourceCnfPath = "$tempBase.resource.cnf"
$resourceArtifactPath = "$tempBase.resource.q3adrat"
$resourceCreateArtifactPath = "$tempBase.resource-created.q3adrat"
$crlfArtifactPath = "$tempBase.crlf.q3adrat"
$largeCnfPath = "$tempBase.large.cnf"
$largeArtifactPath = "$tempBase.large.q3adrat"
$largeCreatedPath = "$tempBase.large-created.q3adrat"
$searchBudgetCnfPath = "$tempBase.search-budget.cnf"
$searchBudgetArtifactPath = "$tempBase.search-budget.q3adrat"
$replaceArtifactPath = "$tempBase.replace.q3adrat"
$modelHash = 'a' * 64
$ErrorActionPreference = 'Stop'

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Program,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $capturedOutput = @(& $Program @Arguments 2>&1)
        $capturedExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ Output = $capturedOutput; ExitCode = $capturedExitCode }
}

try {
    & $buildScript -Compiler $Compiler -Output $executable
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable)) {
        throw 'Proof checker CLI did not build.'
    }

    $version = & $executable --version
    if ($LASTEXITCODE -ne 0 -or
        -not ($version -contains 'Q3A_PROOF_CHECKER_ID q3a-drat-checker-0.2') -or
        -not ($version -contains 'Q3A_PROOF_ARTIFACT_SCHEMA 2')) {
        throw "Proof checker identity/schema is not reported:`n$($version -join "`n")"
    }

    @'
p cnf 2 4
1 2 0
1 -2 0
-1 2 0
-1 -2 0
'@ | Set-Content -LiteralPath $cnfPath -Encoding Ascii

    $created = & $executable --create-drat $cnfPath $artifactPath `
        --model-sha256 $modelHash --query-kind bounded-query
    if ($LASTEXITCODE -ne 0 -or
        -not ($created -contains 'Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED') -or
        -not (Test-Path -LiteralPath $artifactPath)) {
        throw "Proof creation did not produce a checked artifact:`n$($created -join "`n")"
    }

    $checked = & $executable --check-drat $cnfPath $artifactPath `
        --model-sha256 $modelHash --query-kind bounded-query
    if ($LASTEXITCODE -ne 0 -or
        -not ($checked -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
        throw "Checker rejected the generated artifact:`n$($checked -join "`n")"
    }

    [IO.File]::WriteAllText($replaceArtifactPath, 'original artifact')
    $replaceArguments = @('--create-drat', $cnfPath, $replaceArtifactPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $reader = [IO.File]::Open($replaceArtifactPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $blockedReplace = Invoke-NativeCapture $executable $replaceArguments
    } finally {
        $reader.Dispose()
    }
    if ($blockedReplace.ExitCode -ne 1 -or
        $blockedReplace.Output -contains 'Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED' -or
        [IO.File]::ReadAllText($replaceArtifactPath) -cne 'original artifact') {
        throw "A denied publication must preserve the existing output:`n$($blockedReplace.Output -join "`n")"
    }
    $replaced = Invoke-NativeCapture $executable $replaceArguments
    if ($replaced.ExitCode -ne 0 -or
        $replaced.Output -notcontains 'Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED' -or
        (Get-FileHash -LiteralPath $replaceArtifactPath).Hash -ne
        (Get-FileHash -LiteralPath $artifactPath).Hash) {
        throw "Replacing a writable destination failed:`n$($replaced.Output -join "`n")"
    }
    $stageParent = [IO.Path]::GetDirectoryName($replaceArtifactPath)
    $stagePattern = [IO.Path]::GetFileName($replaceArtifactPath) + '.stage-*'
    $remainingStage = @(Get-ChildItem -LiteralPath $stageParent -Directory -Filter $stagePattern)
    if ($remainingStage.Count -ne 0) { throw 'Temporary proof staging remains after publication.' }

    $comment = "c " + ('x' * 1021) + "`n"
    $block = [Text.Encoding]::ASCII.GetBytes($comment * 1024)
    $file = [IO.File]::OpenWrite($largeCnfPath)
    try {
        for ($blockIndex = 0; $blockIndex -lt 24; $blockIndex++) {
            $file.Write($block, 0, $block.Length)
        }
        $formula = [Text.Encoding]::ASCII.GetBytes("p cnf 1 2`n1 0`n-1 0`n")
        $file.Write($formula, 0, $formula.Length)
    } finally {
        $file.Dispose()
    }
    $largeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $largeCnfPath).Hash.ToLowerInvariant()
    [IO.File]::WriteAllLines($largeArtifactPath, [string[]]@(
        'Q3A_DRAT_ARTIFACT 2', 'query_kind bounded-query', 'checker_id q3a-drat-checker-0.2',
        "model_sha256 $modelHash", "query_sha256 $largeHash",
        'proof_records 1', 'proof_begin', '0', 'proof_end'))
    $largeArguments = @('--check-drat', $largeCnfPath, $largeArtifactPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $savedMemoryLimit = $env:Q3A_MEMORY_LIMIT_MIB
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '16'
        $proofWriter = [IO.File]::Open($largeArtifactPath, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $lockedProofCheck = Invoke-NativeCapture $executable $largeArguments
            if ($lockedProofCheck.ExitCode -ne 1 -or
                ($lockedProofCheck.Output -join "`n") -notmatch 'with writes denied' -or
                $lockedProofCheck.Output -contains 'Q3A_PROOF_CHECK ACCEPTED') {
                throw "The checker proceeded despite an open writable proof handle:`n$($lockedProofCheck.Output -join "`n")"
            }
        } finally {
            $proofWriter.Dispose()
        }
        $largeCheck = Invoke-NativeCapture $executable $largeArguments
        if ($largeCheck.ExitCode -ne 0 -or
            $largeCheck.Output -notcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
            $largeCheck.Output -notcontains "Q3A_PROOF_QUERY_SHA256 $largeHash") {
            throw "The 24 MiB CNF did not check under a 16 MiB budget:`n$($largeCheck.Output -join "`n")"
        }
        $largeCreate = Invoke-NativeCapture $executable @(
            '--create-drat', $largeCnfPath, $largeCreatedPath,
            '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
        if ($largeCreate.ExitCode -ne 0 -or
            $largeCreate.Output -notcontains 'Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED' -or
            $largeCreate.Output -notcontains "Q3A_PROOF_QUERY_SHA256 $largeHash") {
            throw "The 24 MiB CNF did not generate a checked proof under 16 MiB:`n$($largeCreate.Output -join "`n")"
        }
        if ((Get-FileHash -LiteralPath $largeCreatedPath).Hash -ne
            (Get-FileHash -LiteralPath $largeArtifactPath).Hash) {
            $createdText = [IO.File]::ReadAllText($largeCreatedPath).Replace("`r`n", "`n")
            $expectedText = [IO.File]::ReadAllText($largeArtifactPath).Replace("`r`n", "`n")
            if ($createdText -cne $expectedText) { throw 'Generated certificate content changed.' }
        }

        $writer = [IO.File]::Open($largeCnfPath, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $lockedCheck = Invoke-NativeCapture $executable $largeArguments
            if ($lockedCheck.ExitCode -ne 1 -or
                ($lockedCheck.Output -join "`n") -notmatch 'with writes denied') {
                throw "The checker proceeded despite an open writable CNF handle:`n$($lockedCheck.Output -join "`n")"
            }
            $writer.Position = 2
            $writer.WriteByte([byte][char]'z')
        } finally {
            $writer.Dispose()
        }
        $changedCheck = Invoke-NativeCapture $executable $largeArguments
        if ($changedCheck.ExitCode -ne 1 -or
            ($changedCheck.Output -join "`n") -notmatch 'proof query hash does not match') {
            throw "Changing one comment byte did not invalidate the exact CNF hash:`n$($changedCheck.Output -join "`n")"
        }

        [IO.File]::WriteAllText($searchBudgetCnfPath, "p cnf 1000000 0`n")
        $searchLimit = Invoke-NativeCapture $executable @(
            '--create-drat', $searchBudgetCnfPath, $searchBudgetArtifactPath,
            '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
        if ($searchLimit.ExitCode -ne 3 -or
            $searchLimit.Output -notcontains 'Q3A_PROOF_STATUS UNKNOWN' -or
            ($searchLimit.Output -join "`n") -notmatch 'process private memory budget reached' -or
            (Test-Path -LiteralPath $searchBudgetArtifactPath)) {
            throw "A budget-limited proof search must stop without an artifact:`n$($searchLimit.Output -join "`n")"
        }
    } finally {
        $env:Q3A_MEMORY_LIMIT_MIB = $savedMemoryLimit
    }

    $artifactText = Get-Content -LiteralPath $artifactPath -Raw
    Set-Content -LiteralPath $crlfArtifactPath -Value $artifactText -Encoding Ascii
    $crlfChecked = & $executable --check-drat $cnfPath $crlfArtifactPath `
        --model-sha256 $modelHash --query-kind bounded-query
    if ($LASTEXITCODE -ne 0 -or
        -not ($crlfChecked -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
        throw "Checker rejected a CRLF-encoded Windows proof artifact:`n$($crlfChecked -join "`n")"
    }

    $wrongModel = 'c' * 64
    $mismatchResult = Invoke-NativeCapture $executable @(
        '--check-drat', $cnfPath, $artifactPath,
        '--model-sha256', $wrongModel, '--query-kind', 'bounded-query')
    $mismatch = $mismatchResult.Output
    if ($mismatchResult.ExitCode -eq 0 -or
        -not (($mismatch -join "`n") -match 'model hash does not match')) {
        throw "Checker accepted a proof bound to a different model hash:`n$($mismatch -join "`n")"
    }

    $artifactText = Get-Content -LiteralPath $artifactPath -Raw
    $wrongCheckerText = $artifactText.Replace(
        'checker_id q3a-drat-checker-0.2', 'checker_id q3a-drat-checker-0.1')
    Set-Content -LiteralPath $wrongCheckerArtifactPath -Value $wrongCheckerText -Encoding Ascii
    $checkerMismatchResult = Invoke-NativeCapture $executable @(
        '--check-drat', $cnfPath, $wrongCheckerArtifactPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $checkerMismatch = $checkerMismatchResult.Output
    if ($checkerMismatchResult.ExitCode -eq 0 -or
        -not (($checkerMismatch -join "`n") -match 'checker identity')) {
        throw "Checker accepted an artifact produced for another checker identity:`n$($checkerMismatch -join "`n")"
    }

    'p cnf 1000001 0' | Set-Content -LiteralPath $resourceCnfPath -Encoding Ascii
    $resourceQueryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resourceCnfPath).Hash.ToLowerInvariant()
    @"
Q3A_DRAT_ARTIFACT 2
query_kind bounded-query
checker_id q3a-drat-checker-0.2
model_sha256 $modelHash
query_sha256 $resourceQueryHash
proof_records 1
proof_begin
0
proof_end
"@ | Set-Content -LiteralPath $resourceArtifactPath -Encoding Ascii
    $resourceCheckResult = Invoke-NativeCapture $executable @(
        '--check-drat', $resourceCnfPath, $resourceArtifactPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $resourceCheck = $resourceCheckResult.Output
    if ($resourceCheckResult.ExitCode -ne 3 -or
        -not (($resourceCheck -join "`n") -match 'Q3A_PROOF_CHECK RESOURCE_LIMIT') -or
        -not (($resourceCheck -join "`n") -match 'DRAT checker variable limit exceeded')) {
        throw "Checker did not report an explicit, inconclusive resource limit:`n$($resourceCheck -join "`n")"
    }

    $resourceCreate = & $executable --create-drat $resourceCnfPath $resourceCreateArtifactPath `
        --model-sha256 $modelHash --query-kind bounded-query
    if ($LASTEXITCODE -ne 3 -or
        -not ($resourceCreate -contains 'Q3A_PROOF_STATUS UNKNOWN') -or
        (Test-Path -LiteralPath $resourceCreateArtifactPath)) {
        throw "Proof creation did not return UNKNOWN for an over-limit CNF:`n$($resourceCreate -join "`n")"
    }

    Set-Content -LiteralPath $resourceCnfPath -Value @('p cnf 1000000 2','1 0','-1 0') -Encoding ascii
    $largeQueryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resourceCnfPath).Hash.ToLowerInvariant()
    $memoryArtifact = (Get-Content -LiteralPath $resourceArtifactPath -Raw).Replace($resourceQueryHash, $largeQueryHash)
    Set-Content -LiteralPath $resourceArtifactPath -Value $memoryArtifact -NoNewline -Encoding ascii
    $savedMemoryLimit = $env:Q3A_MEMORY_LIMIT_MIB
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '8'
        $memoryCheck = Invoke-NativeCapture $executable @(
            '--check-drat', $resourceCnfPath, $resourceArtifactPath,
            '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
        if ($memoryCheck.ExitCode -ne 3 -or
            $memoryCheck.Output -notcontains 'Q3A_PROOF_CHECK RESOURCE_LIMIT' -or
            ($memoryCheck.Output -join "`n") -notmatch 'DRAT checker memory budget:.*pending=[1-9][0-9]+ limit=8388608' -or
            $memoryCheck.Output -contains 'Q3A_PROOF_CHECK ACCEPTED') {
            throw "Checker did not stop at its estimated allocation budget:`n$($memoryCheck.Output -join "`n")"
        }
    } finally {
        if ($null -eq $savedMemoryLimit) {
            Remove-Item Env:Q3A_MEMORY_LIMIT_MIB -ErrorAction SilentlyContinue
        } else {
            $env:Q3A_MEMORY_LIMIT_MIB = $savedMemoryLimit
        }
    }

    $badArtifactText = $artifactText.Replace('Q3A_DRAT_ARTIFACT 2', 'Q3A_DRAT_ARTIFACT 3')
    Set-Content -LiteralPath $badArtifactPath -Value $badArtifactText -Encoding Ascii
    $badSchemaResult = Invoke-NativeCapture $executable @(
        '--check-drat', $cnfPath, $badArtifactPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $badSchema = $badSchemaResult.Output
    if ($badSchemaResult.ExitCode -eq 0 -or
        -not (($badSchema -join "`n") -match 'unsupported or missing')) {
        throw "Checker accepted an unsupported artifact schema:`n$($badSchema -join "`n")"
    }

    @'
p cnf 1 1
1 0
'@ | Set-Content -LiteralPath $satCnfPath -Encoding Ascii
    $satResult = & $executable --create-drat $satCnfPath $satArtifactPath `
        --model-sha256 $modelHash --query-kind bounded-query
    if ($LASTEXITCODE -ne 0 -or
        -not ($satResult -contains 'Q3A_PROOF_STATUS SAT_NO_REFUTATION') -or
        (Test-Path -LiteralPath $satArtifactPath)) {
        throw "Proof writer must not create an UNSAT certificate for SAT input:`n$($satResult -join "`n")"
    }

    $overwriteResult = Invoke-NativeCapture $executable @(
        '--create-drat', $cnfPath, $cnfPath,
        '--model-sha256', $modelHash, '--query-kind', 'bounded-query')
    $overwriteAttempt = $overwriteResult.Output
    if ($overwriteResult.ExitCode -eq 0 -or
        -not (($overwriteAttempt -join "`n") -match 'must not overwrite the CNF input') -or
        -not (Test-Path -LiteralPath $cnfPath)) {
        throw "Proof writer did not guard its CNF input path:`n$($overwriteAttempt -join "`n")"
    }
} finally {
    foreach ($path in @($executable, $cnfPath, $artifactPath,
                        $badArtifactPath, $wrongCheckerArtifactPath,
                        $satCnfPath, $satArtifactPath,
                        $resourceCnfPath, $resourceArtifactPath,
                        $resourceCreateArtifactPath,
                        $crlfArtifactPath, $largeCnfPath, $largeArtifactPath,
                        $largeCreatedPath, $searchBudgetCnfPath, $searchBudgetArtifactPath,
                        $replaceArtifactPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
'PASS: proof CLI creates hashed DRAT artifacts, accepts LF/CRLF, rejects identity/schema mismatches, reports RESOURCE_LIMIT/UNKNOWN for over-limit inputs, and never certifies SAT input.'
