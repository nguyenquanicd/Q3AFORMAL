param(
    [string]$ExecutablePath,
    [string]$CheckerExecutablePath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
if (!$ExecutablePath) { $ExecutablePath = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
if (!$CheckerExecutablePath) { $CheckerExecutablePath = Join-Path $prototype 'bin/q3aformal-proofcheck.exe' }
$product = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerExecutablePath).Path
$leaf = 'q3a-unicode-' + [Guid]::NewGuid()
$root = Join-Path ([IO.Path]::GetTempPath()) $leaf
New-Item -ItemType Directory -Path $root | Out-Null
try {
    # Vietnamese letters outside Windows-1252 make the test independent of console encoding.
    $suffix = ' ' + [char]0x0110 + [char]0x1ED3 + 'ng'
    $install = Join-Path $root ('Portable install' + $suffix)
    $workspace = Join-Path $root ('Verification outputs' + $suffix)
    $modelDirectory = Join-Path $install 'corpus/source-model-vectors'
    New-Item -ItemType Directory -Path $modelDirectory, $workspace -Force | Out-Null
    $project = Join-Path $install 'pdr-pipeline.q3a'
    Copy-Item -LiteralPath (Join-Path $prototype 'pdr-pipeline.q3a') -Destination $project
    Copy-Item -LiteralPath (Join-Path $prototype 'corpus/source-model-vectors/pdr_pipeline.sv') -Destination $modelDirectory

    $portableProduct = Join-Path $install 'q3aformal-sourcecheck.exe'
    $portableChecker = Join-Path $install 'q3aformal-proofcheck.exe'
    Copy-Item -LiteralPath $product -Destination $portableProduct
    Copy-Item -LiteralPath $checker -Destination $portableChecker
    $evidence = Join-Path $workspace ('Certificate' + $suffix)

    $oldEncoding = [Console]::OutputEncoding
    Push-Location -LiteralPath $workspace
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $proved = & $portableProduct prove $project --evidence-dir $evidence |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $proved.status -cne 'PROVEN' -or
            $proved.certificate.directory -cne $evidence) {
            throw "Expected a proof in the original Unicode destination. Result $($proved.status)."
        }
        $verified = & $portableProduct verify-pdr $project --property p_safe --evidence-dir $evidence
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw 'Could not reopen the source-bound evidence from its Unicode path.'
        }
        $proof = Join-Path $evidence 'safety.q3adrat'
        $query = Join-Path $evidence 'safety.cnf'
        $model = @(Get-Content -LiteralPath (Join-Path $evidence 'invariant.txt') -TotalCount 2)[1]
        $checked = & $portableChecker --check-drat $query $proof --model-sha256 $model --query-kind pdr-safety
        if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
            throw 'Standalone checker did not accept the certificate from its Unicode path.'
        }
    } finally {
        [Console]::OutputEncoding = $oldEncoding
        Pop-Location
    }
    'PASS: both Windows executables accept Unicode paths with spaces from an independent working directory.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq [IO.Path]::GetFullPath($root) -and (Split-Path -Leaf $resolved) -ceq $leaf) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
