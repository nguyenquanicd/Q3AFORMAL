param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $prototypeRoot 'bin'
$sourcecheck = Join-Path $outputRoot 'q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$tempRoot = Join-Path $outputRoot ('q3a-proof-cache-test-' + [guid]::NewGuid().ToString('N'))
$cacheRoot = Join-Path $tempRoot 'cache'
$unitCacheRoot = Join-Path $tempRoot 'unit-cache'
$cacheTest = Join-Path $tempRoot 'proof-cache-test.exe'
$ErrorActionPreference = 'Stop'

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    & $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic `
        (Join-Path $PSScriptRoot 'proof_cache_test.cpp') `
        (Join-Path $prototypeRoot 'source\cache\proof_cache.cpp') `
        (Join-Path $prototypeRoot 'source\source_manager\platform_support.cpp') `
        (Join-Path $prototypeRoot 'checker\drat_checker.cpp') `
        (Join-Path $prototypeRoot 'checker\drat_prover.cpp') `
        (Join-Path $prototypeRoot 'checker\proof_artifact.cpp') `
        -I (Join-Path $prototypeRoot 'source\cache') `
        -I (Join-Path $prototypeRoot 'source\source_manager') `
        -I (Join-Path $prototypeRoot 'checker') `
        -lbcrypt -o $cacheTest
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cacheTest)) {
        throw 'Proof-cache identity/checker test build failed.'
    }
    $unitOutput = & $cacheTest $unitCacheRoot
    if ($LASTEXITCODE -ne 0 -or
        -not ($unitOutput -contains 'Q3A_PROOF_CACHE_KEYS_PASS identity_variants=13 exact_cnf_change=1') -or
        -not ($unitOutput -contains 'Q3A_PROOF_CACHE_CHECKER_PASS stored=1 hit=1 tamper_rejected=1 refreshed=1')) {
        throw "Proof-cache key binding or independent revalidation failed:`n$($unitOutput -join "`n")"
    }

    if (!$UseExistingBuild) {
        & $buildScript -Compiler $Compiler
        if ($LASTEXITCODE -ne 0) { throw 'Q3AFormal sourcecheck build failed.' }
    }
    if (-not (Test-Path -LiteralPath $sourcecheck)) {
        throw 'Q3AFormal sourcecheck build failed.'
    }
    $manifest = Join-Path $prototypeRoot 'known-pass-combinational.q3a'
    $firstPrefix = Join-Path $tempRoot 'first'
    $secondPrefix = Join-Path $tempRoot 'second'
    $first = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --output-prefix $firstPrefix --cache-dir $cacheRoot
    if ($LASTEXITCODE -ne 0 -or
        -not ($first -contains 'Q3A_INDUCTION_STATUS PROVEN') -or
        -not ($first | Where-Object { $_ -match '^Q3A_INDUCTION_CACHE base STORED ' }) -or
        -not ($first | Where-Object { $_ -match '^Q3A_INDUCTION_CACHE step STORED ' })) {
        throw "First induction run should check and store both proofs:`n$($first -join "`n")"
    }
    $second = & $sourcecheck --prove-inductive $manifest `
        --property p_y_implies_a --output-prefix $secondPrefix --cache-dir $cacheRoot
    if ($LASTEXITCODE -ne 0 -or
        -not ($second -contains 'Q3A_INDUCTION_STATUS PROVEN') -or
        -not ($second | Where-Object { $_ -match '^Q3A_INDUCTION_CACHE base HIT ' }) -or
        -not ($second | Where-Object { $_ -match '^Q3A_INDUCTION_CACHE step HIT ' })) {
        throw "Second induction run should use proofs rechecked by the current checker:`n$($second -join "`n")"
    }
    foreach ($obligation in @('base', 'step')) {
        foreach ($suffix in @('.cnf', '.q3adrat')) {
            $left = [System.IO.File]::ReadAllBytes("$firstPrefix.$obligation$suffix")
            $right = [System.IO.File]::ReadAllBytes("$secondPrefix.$obligation$suffix")
            if ([Convert]::ToBase64String($left) -ne [Convert]::ToBase64String($right)) {
                throw "Cached $obligation$suffix differs from the original proof-run output."
            }
        }
    }
    if (@(Get-ChildItem -LiteralPath $tempRoot -Force -Directory -Filter '.q3ap-*').Count -ne 0) {
        throw 'Completed induction left a temporary proof directory.'
    }
    'PASS: proof cache binds exact run identities, rechecks cached DRAT with the current checker, rejects tampering, and reuses valid induction proofs.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $tempFull = [System.IO.Path]::GetFullPath($tempRoot)
        $outputFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\') + '\'
        if (-not $tempFull.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($tempFull) -notmatch '^q3a-proof-cache-test-[0-9a-f]{32}$') {
            throw "Refusing to clean an unexpected test path: $tempFull"
        }
        Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}
