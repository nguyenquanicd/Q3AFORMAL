$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$satRoot = Join-Path $projectRoot 'source\sat'
$loweringRoot = Join-Path $projectRoot 'source\lowering'
$testSource = Join-Path $PSScriptRoot 'sequence_bmc_bitblast_test.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-sequence-bmc-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    & g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic `
        (Join-Path $satRoot 'sat_solver.cpp') `
        (Join-Path $satRoot 'tir_bit_blaster.cpp') `
        (Join-Path $satRoot 'transition_encoder.cpp') `
        (Join-Path $loweringRoot 'horizon.cpp') `
        $testSource -I $satRoot -I $loweringRoot `
        -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile sequence BMC oracle (exit $LASTEXITCODE)"
    }

    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Sequence BMC bit-blast oracle failed (exit $LASTEXITCODE)"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
