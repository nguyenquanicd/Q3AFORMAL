param(
    [string]$Compiler = 'g++',
    [string]$Output,
    [switch]$EnableDevelopmentMemory,
    [switch]$EnableDevelopmentEventMask,
    [switch]$EnableDevelopmentSampledValues,
    [switch]$EnableDevelopmentLiveness,
    [switch]$EnableDevelopmentFourState
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$sourceRoot = Join-Path $prototypeRoot 'prototype\source\source_manager'
$releasedOutput = Join-Path $prototypeRoot 'prototype\bin\q3aformal-sourcecheck.exe'
$outputPath = if ($Output) { [IO.Path]::GetFullPath($Output) } else { $releasedOutput }
if (($EnableDevelopmentMemory -or $EnableDevelopmentEventMask -or $EnableDevelopmentSampledValues -or $EnableDevelopmentLiveness -or $EnableDevelopmentFourState) -and (!$Output -or
        [string]::Equals($outputPath, $releasedOutput, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'The development profile build requires a separate output executable.'
}
$outputRoot = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$frontendRoot = Join-Path $prototypeRoot 'prototype\source\frontend'
$elaboratorRoot = Join-Path $prototypeRoot 'prototype\source\elaborator'
$loweringRoot = Join-Path $prototypeRoot 'prototype\source\lowering'
$satRoot = Join-Path $prototypeRoot 'prototype\source\sat'
$cacheRoot = Join-Path $prototypeRoot 'prototype\source\cache'
$replayRoot = Join-Path $prototypeRoot 'prototype\source\replay'
$checkerRoot = Join-Path $prototypeRoot 'prototype\checker'
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
$componentDefinitions = @(
    @{ Id = 'source_manager'; Files = @((Join-Path $sourceRoot 'source_manager.cpp'), (Join-Path $sourceRoot 'source_manager.hpp'), (Join-Path $sourceRoot 'platform_support.cpp'), (Join-Path $sourceRoot 'platform_support.hpp'), (Join-Path $sourceRoot 'batch_worker.cpp'), (Join-Path $sourceRoot 'batch_worker.hpp'), (Join-Path $sourceRoot 'proof_composition.cpp'), (Join-Path $sourceRoot 'memory_proof.cpp'), (Join-Path $sourceRoot 'proof_composition.hpp'), (Join-Path $sourceRoot 'memory_proof.hpp'), (Join-Path $sourceRoot 'equivalence.cpp'), (Join-Path $sourceRoot 'equivalence.hpp'), (Join-Path $sourceRoot 'main.cpp'), (Join-Path $sourceRoot 'induction_feasibility.hpp'), (Join-Path $sourceRoot 'write_locked_input.hpp'), (Join-Path $sourceRoot 'vcd_import.cpp'), (Join-Path $sourceRoot 'vcd_import.hpp')) },
    @{ Id = 'frontend'; Root = $frontendRoot },
    @{ Id = 'elaborator'; Root = $elaboratorRoot },
    @{ Id = 'lowering_sva'; Root = $loweringRoot },
    @{ Id = 'sat_bit_blaster'; Root = $satRoot },
    @{ Id = 'witness_replay'; Root = $replayRoot },
    @{ Id = 'proof_checker'; Root = $checkerRoot },
    @{ Id = 'result_bundle'; Root = (Join-Path $prototypeRoot 'prototype\source\bundle') },
    @{ Id = 'proof_cache'; Root = $cacheRoot }
)
$componentFingerprints = [ordered]@{}
foreach ($component in $componentDefinitions) {
    $componentFiles = if ($component.Files) {
        @($component.Files | ForEach-Object { Get-Item -LiteralPath $_ })
    } else {
        @(Get-ChildItem -LiteralPath $component.Root -Recurse -File |
            Where-Object { $_.Extension -in @('.cpp', '.hpp', '.inc') })
    }
    $canonicalParts = foreach ($file in ($componentFiles | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($prototypeRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        "$relative`t$fileHash`n"
    }
    $canonicalText = $canonicalParts -join ''
    $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalText)
    $componentHash = Get-Sha256Hex $canonicalBytes
    $componentFingerprints[$component.Id] = $componentHash
}
$compilerVersion = ((& $Compiler --version 2>&1 | Select-Object -First 1) -join '').Trim()
$buildFlags = @('-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-static','-municode')
if ($EnableDevelopmentMemory) { $buildFlags += '-DQ3A_ENABLE_DEVELOPMENT_MEMORY' }
if ($EnableDevelopmentEventMask) { $buildFlags += '-DQ3A_ENABLE_DEVELOPMENT_EVENT_MASK' }
if ($EnableDevelopmentSampledValues) { $buildFlags += '-DQ3A_ENABLE_DEVELOPMENT_SAMPLED_VALUES' }
$livenessSources = @()
if ($EnableDevelopmentLiveness) {
    $buildFlags += '-DQ3A_ENABLE_DEVELOPMENT_LIVENESS'
    $livenessRoot = Join-Path $prototypeRoot 'prototype/source/liveness'
    $livenessSources = @((Join-Path $livenessRoot 'fair_cycle.cpp'), (Join-Path $livenessRoot 'source_graph.cpp'), (Join-Path $livenessRoot 'evidence.cpp'))
    $fingerprints = Get-ChildItem -LiteralPath $livenessRoot -File | Where-Object Extension -in '.cpp','.hpp' |
        Sort-Object Name | ForEach-Object { "$($_.Name)`t$(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName | Select-Object -ExpandProperty Hash)`n" }
    $componentFingerprints['explicit_liveness'] = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes(($fingerprints -join '')))
}
$fourStateSources = @()
if ($EnableDevelopmentFourState) {
    $buildFlags += '-DQ3A_ENABLE_DEVELOPMENT_FOUR_STATE'
    $fourStateRoot = Join-Path $prototypeRoot 'prototype/source/four_state'
    $fourStateSources = @((Join-Path $fourStateRoot 'word.cpp'), (Join-Path $fourStateRoot 'source.cpp'), (Join-Path $fourStateRoot 'encode.cpp'), (Join-Path $fourStateRoot 'proof.cpp'), (Join-Path $fourStateRoot 'sequence.cpp'))
    $fingerprints = Get-ChildItem -LiteralPath $fourStateRoot -File | Where-Object Extension -in '.cpp','.hpp' |
        Sort-Object Name | ForEach-Object { "$($_.Name)`t$(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName | Select-Object -ExpandProperty Hash)`n" }
    $componentFingerprints['four_state'] = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes(($fingerprints -join '')))
}
$buildConfiguration = $buildFlags -join ' '
$buildDescription = "$buildConfiguration|$compilerVersion`n" +
    (($componentFingerprints.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)`n" }) -join '')
$buildId = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($buildDescription))
$compilerCpp = $compilerVersion.Replace('\', '\\').Replace('"', '\"')
$header = @"
#pragma once
namespace q3a::build_info {
inline constexpr char kBuildId[] = "$buildId";
inline constexpr char kCompiler[] = "$compilerCpp";
inline constexpr char kBuildConfiguration[] = "$buildConfiguration";
$(($componentFingerprints.GetEnumerator() | ForEach-Object { "inline constexpr char kComponentHash_$($_.Key)[] = `"$($_.Value)`";" }) -join "`n")
}
"@
$buildInfoPath = Join-Path $outputRoot 'q3a_build_info.hpp'
Set-Content -LiteralPath $buildInfoPath -Value $header -NoNewline -Encoding ascii
& $Compiler @buildFlags @livenessSources @fourStateSources (Join-Path $sourceRoot 'equivalence.cpp') (Join-Path $sourceRoot 'proof_composition.cpp') (Join-Path $sourceRoot 'memory_proof.cpp') (Join-Path $sourceRoot 'batch_worker.cpp') (Join-Path $sourceRoot 'platform_support.cpp') (Join-Path $sourceRoot 'source_manager.cpp') (Join-Path $frontendRoot 'lexer.cpp') (Join-Path $frontendRoot 'parser.cpp') (Join-Path $frontendRoot 'preprocessor.cpp') (Join-Path $elaboratorRoot 'elaborator.cpp') (Join-Path $loweringRoot 'lowering.cpp') (Join-Path $loweringRoot 'horizon.cpp') (Join-Path $loweringRoot 'state_transition.cpp') (Join-Path $loweringRoot 'exact_memory_source.cpp') (Join-Path $loweringRoot 'event_mask_source.cpp') (Join-Path $loweringRoot 'sequence_monitor.cpp') (Join-Path $satRoot 'sat_solver.cpp') (Join-Path $satRoot 'dimacs.cpp') (Join-Path $satRoot 'tir_bit_blaster.cpp') (Join-Path $satRoot 'transition_encoder.cpp') (Join-Path $satRoot 'event_window.cpp') (Join-Path $satRoot 'pdr.cpp') (Join-Path $replayRoot 'property_replay.cpp') (Join-Path $checkerRoot 'drat_checker.cpp') (Join-Path $checkerRoot 'drat_prover.cpp') (Join-Path $checkerRoot 'proof_artifact.cpp') (Join-Path $cacheRoot 'proof_cache.cpp') (Join-Path $sourceRoot 'main.cpp') (Join-Path $sourceRoot 'vcd_import.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\run_bundle.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\verify_bundle.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\indexed_trace.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\event_witness.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\event_debug.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\memory_debug.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\trace_capture.cpp') (Join-Path $prototypeRoot 'prototype\source\bundle\debug_view.cpp') -I $sourceRoot -I $frontendRoot -I $elaboratorRoot -I $loweringRoot -I $satRoot -I $cacheRoot -I $replayRoot -I $checkerRoot -I (Join-Path $prototypeRoot 'prototype\source\bundle') -I $outputRoot (Join-Path $prototypeRoot 'prototype/source/bundle/waveform_win32.cpp') (Join-Path $prototypeRoot 'prototype/source/bundle/native_debug_win32.cpp') -lbcrypt -luser32 -lgdi32 -lcomdlg32 -o $outputPath
if ($LASTEXITCODE -ne 0) {
    throw "C++ compiler failed with exit code $LASTEXITCODE"
}

Write-Output "Built $outputPath"
