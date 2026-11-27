$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$satRoot = Join-Path $projectRoot 'source\sat'
$checkerRoot = Join-Path $projectRoot 'checker'
$testSource = Join-Path $PSScriptRoot 'sat_solver_cdcl_test.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-cdcl-oracle-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    & g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic `
        (Join-Path $satRoot 'sat_solver.cpp') `
        (Join-Path $checkerRoot 'drat_checker.cpp') `
        $testSource -I $satRoot -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile CDCL differential oracle (exit $LASTEXITCODE)"
    }

    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "CDCL differential oracle failed (exit $LASTEXITCODE)"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
