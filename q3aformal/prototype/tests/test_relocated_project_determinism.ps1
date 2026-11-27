#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$left = (New-Item -ItemType Directory -Path (Join-Path $root 'first root')).FullName
$right = (New-Item -ItemType Directory -Path (Join-Path $root 'second root')).FullName
$log = Join-Path $root 'commands.stderr.txt'

function Run-Q3A([string]$Name, [int]$Code, [string[]]$CommandArguments) {
    $output = @(& $exe @CommandArguments 2> $log)
    if ($LASTEXITCODE -ne $Code) { throw "$Name failed. $output $(Get-Content -LiteralPath $log -Raw)" }
    $output | Set-Content -LiteralPath (Join-Path $root "$Name.txt") -Encoding utf8
    return $output -join [char]10
}

@(
    'Q3AFORMAL_PROJECT 2'
    'top top'
    'include_dir "config"'
    'source systemverilog "design.sv"'
    'property_source systemverilog "monitor.sv"'
    'property_source systemverilog "bind.sv"'
    'property_source systemverilog "checks.sv"'
) | Set-Content -LiteralPath (Join-Path $left 'project.q3a') -Encoding utf8
@'
%include "gate.svh"
module leaf(input logic clk, input logic a, output logic q);
    assign q = a & %GATE;
endmodule
module top(input logic clk, input logic a, output logic q);
    leaf u_leaf(.clk(clk), .a(a), .q(q));
endmodule
'@.Replace('%', [string][char]96) | Set-Content -LiteralPath (Join-Path $left 'design.sv') -Encoding utf8
@'
module monitor(input logic sample_clk, input logic a, input logic q);
    p_bound: assert property (@(posedge sample_clk) q == a);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $left 'monitor.sv') -Encoding utf8
'bind leaf monitor checker_inst (clk, a, q);' |
    Set-Content -LiteralPath (Join-Path $left 'bind.sv') -Encoding utf8
@'
env_high: assume property (@(posedge clk) a);
p_external: assert property (@(posedge clk) u_leaf.q == a);
'@ | Set-Content -LiteralPath (Join-Path $left 'checks.sv') -Encoding utf8
New-Item -ItemType Directory -Path (Join-Path $left 'config') | Out-Null
('%define GATE 1''b1'.Replace('%', [string][char]96)) |
    Set-Content -LiteralPath (Join-Path $left 'config/gate.svh') -Encoding utf8
foreach ($item in Get-ChildItem -LiteralPath $left) {
    Copy-Item -LiteralPath $item.FullName -Destination $right -Recurse
}

$projects = @((Join-Path $left 'project.q3a'), (Join-Path $right 'project.q3a'))
$models = for ($i = 0; $i -lt $projects.Count; ++$i) {
    Run-Q3A "model-$i" 0 @('--lower-project', $projects[$i])
}
$inventories = for ($i = 0; $i -lt $projects.Count; ++$i) {
    Run-Q3A "inventory-$i" 0 @('properties', $projects[$i])
}
if ($models[0] -cne $models[1] -or $inventories[0] -cne $inventories[1]) {
    throw 'Relocation changed the transition model or source-mapped property inventory.'
}
$inventory = $inventories[0] | ConvertFrom-Json
$bound = $inventory.properties | Where-Object name -CEQ 'u_leaf.checker_inst.p_bound'
$standalone = $inventory.properties | Where-Object name -CEQ 'p_external'
if ($bound.source.file -cne 'monitor.sv' -or $standalone.source.file -cne 'checks.sv' -or
    $standalone.clock -cne 'clk') {
    throw 'The compound fixture lost bound or standalone source mapping.'
}

$configurations = for ($i = 0; $i -lt $projects.Count; ++$i) {
    $result = Run-Q3A "bounded-$i" 1 @('prove', $projects[$i], '--engine', 'bmc', '--property',
        'p_external', '--frames', '1') | ConvertFrom-Json
    $resolved = $result.run_configuration
    $headerHash = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $projects[$i]) 'config/gate.svh')).Hash.ToLowerInvariant()
    if ($result.status -cne 'BOUNDED_PASS' -or $result.bundle_dir -or
        $resolved.headers.Count -ne 1 -or $resolved.headers[0].path -cne 'config/gate.svh' -or
        $resolved.headers[0].sha256 -cne $headerHash -or ($resolved.assumptions -join ',') -cne 'env_high') {
        throw 'Bounded report lost the active header or assumption on a run without a bundle.'
    }
    # Both effective limits can change with the host's available memory.
    foreach ($limit in 'search_private_limit_bytes','search_physical_reserve_bytes') {
        if ($null -eq $resolved.$limit -or $resolved.$limit -lt 0) {
            throw "Bounded report lost its effective host limit $limit."
        }
        $resolved.PSObject.Properties.Remove($limit)
    }
    $resolved | ConvertTo-Json -Depth 8 -Compress
}
if ($configurations[0] -cne $configurations[1]) { throw 'Relocation changed resolved BMC configuration.' }

$proofs = @((Join-Path $left 'proof'), (Join-Path $right 'proof'))
$rechecks = for ($i = 0; $i -lt $projects.Count; ++$i) {
    $result = Run-Q3A "prove-$i" 0 @('prove', $projects[$i], '--engine', 'pdr', '--property',
        'p_external', '--evidence-dir', $proofs[$i]) | ConvertFrom-Json
    if ($result.status -cne 'PROVEN' -or ($result.pdr_configuration.assumptions -join ',') -cne 'env_high') {
        throw 'Relocated project failed to prove the standalone property under its assumption.'
    }
    $other = 1 - $i
    $check = Run-Q3A "cross-verify-$i" 0 @('verify-pdr', $projects[$other], '--property',
        'p_external', '--evidence-dir', $proofs[$i])
    if ($check -notmatch '(?m)^Q3A_PDR_CERTIFICATE VERIFIED$') { throw 'Proof did not revalidate from the other root.' }
    'VERIFIED'
}
$hashes = [ordered]@{}
foreach ($name in 'invariant.txt','initiation.cnf','initiation.q3adrat','consecution.cnf','consecution.q3adrat',
    'safety.cnf','safety.q3adrat') {
    $a = (Get-FileHash -LiteralPath (Join-Path $proofs[0] $name)).Hash.ToLowerInvariant()
    $b = (Get-FileHash -LiteralPath (Join-Path $proofs[1] $name)).Hash.ToLowerInvariant()
    if ($a -cne $b) { throw "Relocation changed $name." }
    $hashes[$name] = $a
}
$modelHash = (Get-Content -LiteralPath (Join-Path $proofs[0] 'invariant.txt') -TotalCount 2)[1]
foreach ($kind in 'initiation','consecution','safety') {
    $checkerOptions = @('--check-drat', (Join-Path $proofs[0] "$kind.cnf"),
        (Join-Path $proofs[0] "$kind.q3adrat"), '--model-sha256', $modelHash, '--query-kind', "pdr-$kind")
    $checked = @(& $checker @checkerOptions)
    if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone checker rejected $kind."
    }
    $checked | Set-Content -LiteralPath (Join-Path $root "$kind.check.txt")
}

('%define GATE 1''b0'.Replace('%', [string][char]96)) |
    Set-Content -LiteralPath (Join-Path $right 'config/gate.svh') -Encoding utf8
$changedModel = Run-Q3A changed-model 0 @('--lower-project', $projects[1]) | ConvertFrom-Json
$originalModel = $models[0] | ConvertFrom-Json
if ($changedModel.input_sha256 -ceq $originalModel.input_sha256) { throw 'Changed active header kept the original source identity.' }
$null = Run-Q3A old-certificate 3 @('verify-pdr', $projects[1], '--property',
    'p_external', '--evidence-dir', $proofs[0])
if ((Get-Content -LiteralPath $log -Raw) -notmatch 'model or property identity does not match') {
    throw 'Changed header did not invalidate the earlier certificate identity.'
}
$bundle = Join-Path $right 'witness'
$counterexample = Run-Q3A changed-header-failure 0 @('prove', $projects[1], '--engine', 'pdr', '--property',
    'p_external', '--evidence-dir', (Join-Path $right 'unused'), '--bundle-dir', $bundle) | ConvertFrom-Json
if ($counterexample.status -cne 'FAIL') { throw 'Independent expectation is q=0 under assumed a=1.' }
$replay = Run-Q3A changed-header-replay 0 @('--verify-bundle', $bundle, '--require-source-model')
if ($replay -notmatch '(?m)^Q3A_BUNDLE_SOURCE_MODEL VERIFIED$' -or
    $replay -notmatch '(?m)^Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=1 candidate_frame=0$') {
    throw 'Changed-header counterexample was not source-replayed.'
}
$trace = Get-ChildItem -LiteralPath $bundle -Recurse -Filter trace.json
$frame = (Get-Content -LiteralPath $trace.FullName -Raw | ConvertFrom-Json).frames[0].signals
if ($frame.a -cne '0x1' -or $frame.q -cne '0x0') { throw 'Replayed counterexample disagrees with the Boolean reference.' }

[ordered]@{
    schema = 'Q3AFORMAL_RELOCATED_PROJECT_QUALIFICATION_1'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    source_hash = $originalModel.input_sha256
    changed_source_hash = $changedModel.input_sha256
    model_sha256 = $modelHash
    identical_proof_artifacts = $hashes
    cross_root_certificate_checks = $rechecks
    standalone_drat_passed = 3
    changed_header_replay = $frame
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: relocated source, property inventory, exact certificate bytes, three standalone DRAT checks and source replay after header mutation.'
