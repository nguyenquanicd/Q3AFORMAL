$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$satRoot = Join-Path $projectRoot 'source\sat'
$testSource = Join-Path $PSScriptRoot 'sat_relational_bitblast_test.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-relational-bitblast-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    & g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic `
        (Join-Path $satRoot 'sat_solver.cpp') `
        (Join-Path $satRoot 'tir_bit_blaster.cpp') `
        $testSource -I $satRoot -I (Join-Path $projectRoot 'source\lowering') `
        -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile relational bit-blaster oracle (exit $LASTEXITCODE)"
    }

    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Relational bit-blaster oracle failed (exit $LASTEXITCODE)"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
