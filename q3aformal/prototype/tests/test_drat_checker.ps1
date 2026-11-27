param(
    [string]$Compiler = 'g++'
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$checkerRoot = Join-Path $prototypeRoot 'checker'
$testSource = Join-Path $PSScriptRoot 'drat_checker_test.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-drat-checker-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & $Compiler -std=c++17 -O2 -pipe -Wall -Wextra -Wpedantic `
        $testSource (Join-Path $checkerRoot 'drat_checker.cpp') `
        (Join-Path $checkerRoot 'drat_prover.cpp') `
        (Join-Path $checkerRoot 'proof_artifact.cpp') `
        -I $checkerRoot -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "DRAT checker test compilation failed with exit code $LASTEXITCODE"
    }
    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "DRAT checker test failed with exit code $LASTEXITCODE"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
'PASS: independent DRAT checker validates RUP/RAT additions, deletions, and rejects invalid or incomplete evidence.'
