param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-rtl-017-arithmetic-right-shift.q3a'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'Q3AFormal sourcecheck build failed before arithmetic-right-shift BMC.'
}

$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = @(& $executable --bmc $manifest --property p_signed_asr_1 --frames 0 2>&1)
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedPreference
}

$message = $output -join "`n"
if ($exitCode -ne 1 -or
    $message -notmatch "Q3A_PARSE_ERROR .*rtl-017-arithmetic-right-shift\.sv:\d+:\d+: operator '>>>' is outside the Phase 0 RTL expression subset" -or
    $message -match '(?m)^Q3A_(?:BMC|SAT|INDUCTION)_STATUS\b') {
    throw "Expected source-located rejection of arithmetic right shift:`n$message"
}

'PASS: Phase 0 rejects >>> at its source location before reporting a formal status.'
