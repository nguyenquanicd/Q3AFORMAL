$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$previousLimit = [Environment]::GetEnvironmentVariable('Q3A_MEMORY_LIMIT_MIB')
$previousReserve = [Environment]::GetEnvironmentVariable('Q3A_MEMORY_RESERVE_MIB')
$previousScratch = [Environment]::GetEnvironmentVariable('Q3A_SCRATCH_DIR')
$previousNativePreference = $PSNativeCommandUseErrorActionPreference
$previousErrorPreference = $ErrorActionPreference
$proofPrefix = Join-Path (Join-Path $prototypeRoot 'bin') (
    'memory-budget-' + [guid]::NewGuid().ToString('N'))
$scratch = "$proofPrefix scratch"
$bmcManifest = Join-Path $prototypeRoot 'counter4-fail.q3a'
$inductionManifest = Join-Path $prototypeRoot 'known-pass-combinational.q3a'

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:Q3A_SCRATCH_DIR = $scratch
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $env:Q3A_MEMORY_LIMIT_MIB = '1'
    $bounded = @(& $sourcecheck --bmc $bmcManifest --property p_wraps_to_zero --frames 10000 2>&1)
    $boundedExit = $LASTEXITCODE
    $induction = @(& $sourcecheck --prove-inductive $inductionManifest --property p_y_implies_a --k 5000 --output-prefix $proofPrefix 2>&1)
    $inductionExit = $LASTEXITCODE
    foreach ($case in @(
        @{ Command = 'BMC'; Output = $bounded; Exit = $boundedExit },
        @{ Command = 'INDUCTION'; Output = $induction; Exit = $inductionExit }
    )) {
        $lines = @($case.Output | ForEach-Object { [string]$_ })
        $statuses = @($lines | Where-Object { $_ -match "^Q3A_$($case.Command)_STATUS " })
        if ($case.Exit -ne 3 -or $statuses.Count -ne 1 -or
            $statuses[0] -ne "Q3A_$($case.Command)_STATUS UNKNOWN" -or
            !($lines -match '^Q3A_RESOURCE_LIMIT MEMORY .*limit=1048576 bytes\)')) {
            throw "Expected a memory-limited $($case.Command) result:`n$($lines -join "`n")"
        }
    }
    $proofFiles = @('.base.cnf', '.step.cnf', '.base.q3adrat', '.step.q3adrat',
                    '.base.witness.txt', '.step.witness.txt')
    if (@($proofFiles | Where-Object { Test-Path -LiteralPath "$proofPrefix$_" }).Count -ne 0) {
        throw 'A stopped run published induction evidence.'
    }

    $env:Q3A_MEMORY_LIMIT_MIB = 'invalid'
    $invalid = @(& $sourcecheck --bmc $bmcManifest --property p_wraps_to_zero --frames 1 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        !(($invalid -join "`n") -match 'Q3A_MEMORY_LIMIT_MIB must be a positive integer')) {
        throw "Invalid memory configuration was not rejected:`n$($invalid -join "`n")"
    }

    Remove-Item Env:Q3A_MEMORY_LIMIT_MIB
    $env:Q3A_MEMORY_RESERVE_MIB = 'invalid'
    $invalidReserve = @(& $sourcecheck --bmc $bmcManifest --property p_wraps_to_zero --frames 1 2>&1)
    if ($LASTEXITCODE -ne 1 -or
        !(($invalidReserve -join "`n") -match 'Q3A_MEMORY_RESERVE_MIB must be a positive integer')) {
        throw "Invalid available-memory reserve was not rejected:`n$($invalidReserve -join "`n")"
    }

    $env:Q3A_MEMORY_RESERVE_MIB = '1048576'
    $reserved = @(& $sourcecheck --bmc $bmcManifest --property p_wraps_to_zero --frames 1 2>&1)
    if ($LASTEXITCODE -ne 3 -or
        $reserved -notcontains 'Q3A_BMC_STATUS UNKNOWN' -or
        !(($reserved -join "`n") -match 'available physical memory reserve reached')) {
        throw "A reserve above available memory did not stop safely:`n$($reserved -join "`n")"
    }

    Remove-Item Env:Q3A_MEMORY_LIMIT_MIB -ErrorAction SilentlyContinue
    Remove-Item Env:Q3A_MEMORY_RESERVE_MIB
    $normal = @(& $sourcecheck --bmc $bmcManifest --property p_wraps_to_zero --frames 1)
    if ($LASTEXITCODE -ne 0 -or $normal -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $normal -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Normal memory policy changed the bounded result:`n$($normal -join "`n")"
    }
    $normalProof = @(& $sourcecheck --prove-inductive $inductionManifest --property p_y_implies_a --output-prefix $proofPrefix)
    if ($LASTEXITCODE -ne 0 -or $normalProof -notcontains 'Q3A_INDUCTION_STATUS PROVEN' -or
        $normalProof -notcontains 'Q3A_INDUCTION_CERTIFICATE INDUCTIVE_PROOF_ACCEPTED') {
        throw "Normal memory policy changed the checked proof:`n$($normalProof -join "`n")"
    }
    foreach ($suffix in @('.base.cnf', '.step.cnf', '.base.q3adrat', '.step.q3adrat')) {
        if (!(Test-Path -LiteralPath "$proofPrefix$suffix" -PathType Leaf)) {
            throw "Missing induction evidence $suffix after scratch staging."
        }
    }
    if (@(Get-ChildItem -LiteralPath $scratch -Force).Count -ne 0) {
        throw 'The completed proof left temporary files in the scratch directory.'
    }
    $env:Q3A_SCRATCH_DIR = Join-Path $scratch 'missing'
    $badScratch = @(& $sourcecheck --prove-inductive $inductionManifest --property p_y_implies_a --output-prefix "$proofPrefix-invalid" 2>&1)
    if ($LASTEXITCODE -ne 1 -or !($badScratch -match 'missing')) {
        throw "A missing scratch directory did not fail clearly:`n$($badScratch -join "`n")"
    }
} finally {
    [Environment]::SetEnvironmentVariable('Q3A_SCRATCH_DIR', $previousScratch, 'Process')
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Force }
    if ($null -eq $previousLimit) {
        Remove-Item Env:Q3A_MEMORY_LIMIT_MIB -ErrorAction SilentlyContinue
    } else {
        $env:Q3A_MEMORY_LIMIT_MIB = $previousLimit
    }
    if ($null -eq $previousReserve) {
        Remove-Item Env:Q3A_MEMORY_RESERVE_MIB -ErrorAction SilentlyContinue
    } else {
        $env:Q3A_MEMORY_RESERVE_MIB = $previousReserve
    }
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    $ErrorActionPreference = $previousErrorPreference
    foreach ($suffix in @('.base.cnf', '.step.cnf', '.base.q3adrat', '.step.q3adrat',
                         '.base.witness.txt', '.step.witness.txt')) {
        $artifact = "$proofPrefix$suffix"
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Force }
    }
}

'PASS: BMC and induction stop at explicit memory and host-reserve limits with UNKNOWN and no published proof. Default policy preserves witness replay and a checked induction proof.'
