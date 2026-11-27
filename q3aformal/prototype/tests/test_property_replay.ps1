param(
    [string]$Compiler = 'g++'
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $prototypeRoot 'source'
$testSource = Join-Path $PSScriptRoot 'property_replay_test.cpp'
$replaySource = Join-Path $sourceRoot 'replay\property_replay.cpp'
$horizonSource = Join-Path $sourceRoot 'lowering\horizon.cpp'
$testExecutable = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-replay-test-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic $testSource $replaySource $horizonSource `
        -I (Join-Path $sourceRoot 'replay') -I (Join-Path $sourceRoot 'lowering') `
        -I (Join-Path $sourceRoot 'elaborator') -I (Join-Path $sourceRoot 'frontend') `
        -o $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Replay test compilation failed with exit code $LASTEXITCODE"
    }
    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Replay test failed with exit code $LASTEXITCODE"
    }
} finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
'PASS: replay validates bounded and induction witnesses and rejects equation, assumption, property, candidate-frame, and cover-goal mismatches.'
