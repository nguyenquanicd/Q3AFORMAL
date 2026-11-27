#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Compiler = 'g++',
    [string]$CheckerPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$checker = if ($CheckerPath) { (Resolve-Path -LiteralPath $CheckerPath).ProviderPath }
    else { Join-Path $repo 'prototype/bin/q3aformal-proofcheck.exe' }
$checkerHash = (Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
$exe = Join-Path $root 'state-transition-test.exe'
$files = @(
    'specs/004-phase2-subsystem/state_transition_test.cpp'
    'prototype/source/lowering/state_transition.cpp'
    'prototype/source/lowering/exact_memory_source.cpp'
    'prototype/source/lowering/event_mask_source.cpp'
    'prototype/source/lowering/sequence_monitor.cpp'
    'prototype/source/lowering/lowering.cpp'
    'prototype/source/lowering/horizon.cpp'
    'prototype/source/sat/tir_bit_blaster.cpp'
    'prototype/source/sat/transition_encoder.cpp'
    'prototype/source/sat/event_window.cpp'
    'prototype/source/sat/sat_solver.cpp'
    'prototype/source/sat/pdr.cpp'
    'prototype/source/source_manager/platform_support.cpp'
    'prototype/source/source_manager/memory_proof.cpp'
    'prototype/checker/proof_artifact.cpp'
    'prototype/checker/drat_checker.cpp'
    'prototype/checker/drat_prover.cpp'
    'prototype/source/replay/property_replay.cpp'
    'prototype/source/bundle/indexed_trace.cpp'
    'prototype/source/bundle/event_witness.cpp'
    'prototype/source/frontend/lexer.cpp'
    'prototype/source/elaborator/elaborator.cpp'
    'prototype/source/frontend/parser.cpp'
)
$inputs = [ordered]@{}
foreach ($file in $files + @('prototype/source/lowering/state_transition.hpp', 'prototype/source/lowering/event_mask_source.hpp', 'prototype/source/lowering/sequence_monitor.hpp', 'prototype/source/bundle/event_witness.hpp', 'prototype/source/sat/event_window.hpp', 'prototype/source/source_manager/memory_proof.hpp')) {
    $inputs[$file] = (Get-FileHash -LiteralPath (Join-Path $repo $file)).Hash.ToLowerInvariant()
}
$paths = @($files | ForEach-Object { Join-Path $repo $_ })
$includes = @('lowering', 'sat', 'bundle', 'source_manager') | ForEach-Object {
    '-I' + (Join-Path $repo "prototype/source/$_")
}
$includes += '-I' + (Join-Path $repo 'prototype/checker')
& $Compiler -std=c++17 -O2 -Wall -Wextra -Wpedantic -static @includes @paths -lbcrypt -o $exe
$result = & $exe $root
$certificates = @(foreach ($line in $result) {
    $base = $root
    if ($line -cmatch '^MEMORY_GROUP_CERTIFICATE (read-range|write-range|property) ([a-f0-9]{64})$') {
        $base = Join-Path $root 'source-proof-group'
    } elseif ($line -cnotmatch '^(?:MEMORY_RANGE_CERTIFICATE (read_range|write_range)|EVENT_SVA_CERTIFICATE (p_a|p_b|p_delay|p_overlap)) ([a-f0-9]{64})$') {
        continue
    } else {
        $propertyName = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $Matches[1] = $propertyName
        $Matches[2] = $Matches[3]
    }
    $name, $model = $Matches[1], $Matches[2]
    foreach ($kind in 'initiation', 'consecution', 'safety') {
        $stem = Join-Path $base "$name/$kind"
        $output = @(& $checker --check-drat "$stem.cnf" "$stem.q3adrat" --model-sha256 $model --query-kind "pdr-$kind")
        if ($output -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Standalone checker refused $name/$kind." }
        [ordered]@{
            property = $name
            kind = "pdr-$kind"
            query_sha256 = (Get-FileHash -LiteralPath "$stem.cnf").Hash.ToLowerInvariant()
            proof_sha256 = (Get-FileHash -LiteralPath "$stem.q3adrat").Hash.ToLowerInvariant()
        }
    }
})
if ($certificates.Count -ne 27 -or (Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant() -cne $checkerHash) {
    throw 'Expected twenty-seven independently accepted proof obligations and an unchanged checker.'
}
foreach ($file in $inputs.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $repo $file)).Hash.ToLowerInvariant() -cne $inputs[$file]) {
        throw "Test input changed during execution: $file"
    }
}
if ($result -cnotcontains 'PASS: memory proof-group interruption and publication conflict left no partial evidence.') {
    throw 'The interruption and conflicting-publication checks did not run.'
}
[ordered]@{
    status = 'PASS'
    memory_group_publication = 'ATOMIC_PUBLICATION_AND_CLEANUP_VERIFIED'
    scope = 'INTERNAL_TRANSITION_BUILDER'
    result = $result
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    inputs = $inputs
    standalone_checker_sha256 = $checkerHash
    memory_range_obligations = @($certificates | Where-Object property -in 'read_range','write_range')
    source_memory_group_obligations = @($certificates | Where-Object property -in 'read-range','write-range','property')
    event_domain_sva_obligations = @($certificates | Where-Object property -in 'p_a','p_b','p_delay','p_overlap')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8NoBOM
$result
