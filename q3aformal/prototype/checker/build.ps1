param(
    [string]$Compiler = 'g++',
    [string]$Output = ''
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($Output)) {
    $outputRoot = Join-Path $prototypeRoot 'bin'
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $Output = Join-Path $outputRoot 'q3aformal-proofcheck.exe'
}
$sourceRoot = Join-Path $prototypeRoot 'source'
& $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic -static -municode `
    (Join-Path $PSScriptRoot 'drat_checker.cpp') `
    (Join-Path $PSScriptRoot 'drat_prover.cpp') `
    (Join-Path $PSScriptRoot 'proof_artifact.cpp') `
    (Join-Path $PSScriptRoot 'proof_cli.cpp') `
    (Join-Path $sourceRoot 'source_manager\platform_support.cpp') `
    -I $PSScriptRoot -I (Join-Path $sourceRoot 'source_manager') `
    -lbcrypt -o $Output
if ($LASTEXITCODE -ne 0) {
    throw "Proof checker build failed with exit code $LASTEXITCODE"
}
Write-Output "Built $([System.IO.Path]::GetFullPath($Output))"
