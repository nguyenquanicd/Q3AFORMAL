#requires -Version 7.0
param([string]$Compiler='g++', [string]$ReportPath)
$ErrorActionPreference='Stop'
$src=Join-Path (Split-Path -Parent $PSScriptRoot) 'source/frontend'
$output=Join-Path ([IO.Path]::GetTempPath()) ('q3a-frontend-contract-'+[Guid]::NewGuid().ToString('n')+'.exe')
try {
    & $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic -static (Join-Path $PSScriptRoot 'frontend_contract.cpp') (Join-Path $src 'lexer.cpp') (Join-Path $src 'parser.cpp') -I $src -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the typed frontend contract probe.' }
    $verdict=@(& $output)
    if ($LASTEXITCODE -ne 0 -or $verdict -cnotcontains 'PASS parser rejects embedded end marker') {
        throw "Typed frontend contract regression failed: $verdict"
    }
    if ($ReportPath) {
        [ordered]@{verdict=$verdict;parser_sha256=(Get-FileHash -LiteralPath (Join-Path $src 'parser.cpp')).Hash.ToLowerInvariant()} |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    }
    $verdict
} finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
}
