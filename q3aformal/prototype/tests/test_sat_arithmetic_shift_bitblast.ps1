$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$satRoot = Join-Path $projectRoot 'source\sat'
$testSource = Join-Path $PSScriptRoot 'sat_arithmetic_shift_bitblast_test.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-arithmetic-shift-bitblast-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    & g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic `
        (Join-Path $satRoot 'sat_solver.cpp') `
        (Join-Path $satRoot 'tir_bit_blaster.cpp') `
        $testSource -I $satRoot -I (Join-Path $projectRoot 'source\lowering') `
        -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile arithmetic/shift bit-blaster oracle (exit $LASTEXITCODE)"
    }

    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Arithmetic/shift bit-blaster oracle failed (exit $LASTEXITCODE)"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
