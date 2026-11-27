param(
    [string]$Compiler = 'g++'
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $prototypeRoot
$buildScript = Join-Path $prototypeRoot 'checker\build.ps1'
$corpusRoot = Join-Path $repositoryRoot 'evidence\checker-corpus'
$tempExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-corpus-checker-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    & $buildScript -Compiler $Compiler -Output $tempExecutable
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempExecutable)) {
        throw 'Checker corpus runner could not build the standalone checker.'
    }
    $version = & $tempExecutable --version
    if ($LASTEXITCODE -ne 0 -or
        -not ($version -contains 'Q3A_PROOF_CHECKER_ID q3a-drat-checker-0.2') -or
        -not ($version -contains 'Q3A_PROOF_ARTIFACT_SCHEMA 2')) {
        throw "Unexpected checker identity/schema:`n$($version -join "`n")"
    }

    $modelIdentityPath = Join-Path $corpusRoot 'model.identity.txt'
    $modelHash = (Get-FileHash -LiteralPath $modelIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $cnfPath = Join-Path $corpusRoot 'valid-unsat.cnf'
    $validArtifactPath = Join-Path $corpusRoot 'valid-unsat.q3adrat'

    $valid = & $tempExecutable --check-drat $cnfPath $validArtifactPath `
        --model-sha256 $modelHash --query-kind checker-corpus
    if ($LASTEXITCODE -ne 0 -or
        -not ($valid -contains 'Q3A_PROOF_CHECK ACCEPTED')) {
        throw "Valid corpus artifact was rejected:`n$($valid -join "`n")"
    }

    $invalid = & $tempExecutable --check-drat $cnfPath `
        (Join-Path $corpusRoot 'one-literal-defect.q3adrat') `
        --model-sha256 $modelHash --query-kind checker-corpus 2>&1
    if ($LASTEXITCODE -eq 0 -or
        -not (($invalid -join "`n") -match 'outside the supported range|undeclared variable')) {
        throw "One-literal-defect artifact was not rejected for its invalid literal:`n$($invalid -join "`n")"
    }

    $malformed = & $tempExecutable --check-drat $cnfPath `
        (Join-Path $corpusRoot 'malformed-truncated.q3adrat') `
        --model-sha256 $modelHash --query-kind checker-corpus 2>&1
    if ($LASTEXITCODE -eq 0 -or
        -not (($malformed -join "`n") -match 'truncated proof artifact metadata')) {
        throw "Malformed corpus artifact was not rejected clearly:`n$($malformed -join "`n")"
    }

    $wrongChecker = & $tempExecutable --check-drat $cnfPath `
        (Join-Path $corpusRoot 'wrong-checker-id.q3adrat') `
        --model-sha256 $modelHash --query-kind checker-corpus 2>&1
    if ($LASTEXITCODE -eq 0 -or
        -not (($wrongChecker -join "`n") -match 'checker identity')) {
        throw "Artifact from a different checker identity was accepted:`n$($wrongChecker -join "`n")"
    }

    $verdictPath = Join-Path $corpusRoot 'verdicts.md'
    if (-not (Test-Path -LiteralPath $verdictPath)) {
        throw 'The reviewable checker-corpus verdict report is missing.'
    }
    $verdicts = Get-Content -LiteralPath $verdictPath -Raw
    foreach ($required in @(
        'q3a-drat-checker-0.2',
        'Q3A_PROOF_ARTIFACT_SCHEMA 2',
        'Q3A_PROOF_CHECK ACCEPTED',
        'one-literal-defect',
        'malformed-truncated',
        'wrong-checker-id',
        'SHA-256')) {
        if (-not $verdicts.Contains($required)) {
            throw "The checker-corpus verdict report is missing required evidence: $required"
        }
    }
    foreach ($fileName in @(
        'model.identity.txt',
        'valid-unsat.cnf',
        'valid-unsat.q3adrat',
        'one-literal-defect.q3adrat',
        'malformed-truncated.q3adrat',
        'wrong-checker-id.q3adrat')) {
        $artifactPath = Join-Path $corpusRoot $fileName
        $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $verdicts.Contains($artifactHash)) {
            throw "The checker-corpus verdict report is missing the SHA-256 fingerprint for $fileName."
        }
    }
} finally {
    if (Test-Path -LiteralPath $tempExecutable) {
        Remove-Item -LiteralPath $tempExecutable -Force
    }
}

'PASS: checker corpus accepts the valid artifact and rejects one-literal, malformed, and wrong-checker identity cases.'
