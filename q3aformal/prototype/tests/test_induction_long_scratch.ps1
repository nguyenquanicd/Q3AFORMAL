#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Executable = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$exe = (Resolve-Path -LiteralPath $Executable).Path
$project = (Resolve-Path -LiteralPath (Join-Path $repo 'prototype/bmc-past.q3a')).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$short = (New-Item -ItemType Directory -Path (Join-Path $root 'scratch')).FullName
$deepName = 's' * [Math]::Max(20, 271 - $root.Length)
$long = (New-Item -ItemType Directory -Path (Join-Path $root $deepName)).FullName
if ($long.Length -le 260) { throw 'The long scratch parent did not exceed the legacy path limit.' }

$savedScratch = $env:Q3A_SCRATCH_DIR
try {
    $results = foreach ($case in @(
        @{ Name = 'normal'; Scratch = $short; Output = $root },
        @{ Name = 'extended'; Scratch = $long; Output = $long }
    )) {
        $name = $case.Name
        $env:Q3A_SCRATCH_DIR = $case.Scratch
        $bundle = Join-Path $case.Output "$name-bundle"
        $prefix = Join-Path $case.Output "$name-proof"
        $stdout = @(& $exe --prove-inductive $project --property p_past_a --output-prefix $prefix --bundle-dir $bundle 2> (Join-Path $root "$name.stderr"))
        $code = $LASTEXITCODE
        $stdout | Set-Content -LiteralPath (Join-Path $root "$name.stdout") -Encoding utf8
        if ($code -ne 0 -or $stdout -cnotcontains 'Q3A_INDUCTION_STATUS NOT_1_INDUCTIVE') {
            throw "Expected the replayed induction step counterexample for $name."
        }

        $verified = @(& $exe --verify-bundle $bundle --require-source-model)
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "The archived induction step witness did not revalidate for $name."
        }
        if (Get-ChildItem -LiteralPath $case.Scratch -Force -Filter '.q3ap-*') {
            throw "The induction scratch directory still has a staging folder after $name."
        }
        if (!(Test-Path -LiteralPath "$prefix.step.witness.txt" -PathType Leaf)) {
            throw "The published text witness is missing after $name."
        }
        if ($name -ceq 'extended') {
            $published = (Get-FileHash -LiteralPath "$prefix.step.witness.txt").Hash
            & $exe --prove-inductive $project --property p_past_a --output-prefix $prefix --bundle-dir $bundle 2> (Join-Path $root 'duplicate.stderr') | Out-Null
            if ($LASTEXITCODE -eq 0 -or
                (Get-Content -Raw (Join-Path $root 'duplicate.stderr')) -cnotmatch 'induction output already exists' -or
                (Get-FileHash -LiteralPath "$prefix.step.witness.txt").Hash -cne $published) {
                throw 'Existing long-path evidence was not preserved on retry.'
            }
            if (Get-ChildItem -LiteralPath $case.Scratch -Force -Filter '.q3ap-*') {
                throw 'The rejected retry left an induction staging folder.'
            }
        }
        $witness = @(Get-ChildItem -LiteralPath $bundle -Recurse -Filter '*.q3atrace' -File)
        if ($witness.Count -ne 1) { throw "Expected one indexed trace for $name." }
        [ordered]@{
            name = $name
            scratch_path_chars = $case.Scratch.Length
            witness_output_chars = "$prefix.step.witness.txt".Length
            trace_sha256 = (Get-FileHash -LiteralPath $witness[0].FullName).Hash.ToLowerInvariant()
            bundle_status = 'REVALIDATED'
        }
    }
} finally {
    $env:Q3A_SCRATCH_DIR = $savedScratch
}
if (@($results.trace_sha256 | Sort-Object -Unique).Count -ne 1) {
    throw 'The scratch path changed the bytes of the indexed witness.'
}
[ordered]@{
    status = 'PASS'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    cases = @($results)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: Induction reproduced identical indexed witnesses through both Windows scratch paths.'

