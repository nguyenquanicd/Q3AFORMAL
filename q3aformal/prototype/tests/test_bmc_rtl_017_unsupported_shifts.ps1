$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-rtl-017-unsupported-shifts.q3a'

$cases = @(
    @{ Property = 'p_dynamic_shift'; Diagnostic = 'compile-time constant shift distances' },
    @{ Property = 'p_negative_shift'; Diagnostic = 'negative constant shift distance|constant shift distance must be in the range' }
)

foreach ($case in $cases) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $sourcecheck --bmc $manifest --property $case.Property --frames 0 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $message = $output -join "`n"
    if ($exitCode -ne 1 -or $message -notmatch $case.Diagnostic -or
        $message -notmatch 'rtl-017-unsupported-shifts\.sv:[0-9]+:[0-9]+:' -or
        $message -match '(?m)^Q3A_(?:BMC|SAT|INDUCTION)_STATUS\b') {
        throw "Expected source-located rejection before a formal result for $($case.Property):`n$message"
    }
}

'PASS: dynamic and negative shift distances fail with source locations and no formal-query status.'
