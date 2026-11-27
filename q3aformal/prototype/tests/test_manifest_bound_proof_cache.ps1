#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$cacheSegment = 'cache-' + ('x' * [Math]::Max(40, 245 - $root.Length))
$cache = Join-Path $root $cacheSegment
$source = Join-Path $root 'cache.sv'
$left = Join-Path $root 'project.q3a'
$right = Join-Path $root 'alternate.q3a'
$base = (@('Q3AFORMAL_PROJECT 2','top cache_probe','source systemverilog "cache.sv"') -join [char]10) + [char]10
[IO.File]::WriteAllText($left,$base)
[IO.File]::WriteAllText($right,$base + "# Alternate comment only$([char]10)")
@'
module cache_probe(input logic clk, input logic a);
    p_safe: assert property (@(posedge clk) a == a);
endmodule
'@ | Set-Content -LiteralPath $source -Encoding utf8

function Measure-CacheRun([string]$Id,[string]$Manifest,[string]$Expected) {
    $stderr = Join-Path $root "$Id.stderr.txt"
    $prefix = Join-Path $root $Id
    $bundle = Join-Path $root "$Id-bundle"
    $options = @('prove',$Manifest,'--engine','induction','--property','p_safe',
        '--output-prefix',$prefix,'--cache-dir',$cache,'--bundle-dir',$bundle)
    $output = @(& $exe @options 2> $stderr)
    $result = $output | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'PROVEN') { throw "Could not prove $Id." }
    $events = @(Get-Content -LiteralPath $stderr | Where-Object { $_ -cmatch '^Q3A_INDUCTION_CACHE (base|step) (STORED|HIT) key=[0-9a-f]{64} ' })
    if ($events.Count -ne 2 -or @($events | Where-Object { $_ -cnotmatch " $Expected key=" }).Count) {
        throw "Expected two $Expected events for $Id. $events"
    }
    $data = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
    $digest = (Get-FileHash -LiteralPath $Manifest).Hash.ToLowerInvariant()
    if ($data.project.manifest_sha256 -cne $digest -or $result.run_configuration.project_manifest_sha256 -cne $digest) {
        throw "Run and bundle did not record the exact manifest for $Id."
    }
    $verification = @(& $exe --verify-bundle $bundle --require-source-model)
    if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "$Id did not reopen with source-required verification."
    }
    [ordered]@{case=$Id;manifest_sha256=$digest;result=$Expected;model_sha256=$data.model.sha256;
        query_sha256=@($data.queries.cnf_sha256);keys=@($events | ForEach-Object { ($_ -split 'key=')[1].Split(' ')[0] })}
}

$first = Measure-CacheRun original $left STORED
$changed = Measure-CacheRun changed $right STORED
$reuse = Measure-CacheRun changed-repeat $right HIT
$identical = Join-Path $root 'identical.q3a'
Copy-Item -LiteralPath $left -Destination $identical
$copy = Measure-CacheRun identical-bytes $identical HIT
$cachedManifest = Join-Path $cache "$($first.keys[0])/manifest.txt"
if ($cachedManifest.Length -lt 260 -or !(Test-Path -LiteralPath $cachedManifest -PathType Leaf)) {
    throw 'Expected a stored cache manifest on a long Windows path.'
}
if ($first.manifest_sha256 -ceq $changed.manifest_sha256 -or $first.model_sha256 -cne $changed.model_sha256 -or
    ($first.query_sha256 -join ',') -cne ($changed.query_sha256 -join ',') -or
    (Compare-Object $first.keys $changed.keys).Count -ne 4 -or
    ($changed.keys -join ',') -cne ($reuse.keys -join ',') -or
    ($first.keys -join ',') -cne ($copy.keys -join ',')) {
    throw 'Manifest identity or same-model cache isolation did not match the oracle.'
}
[ordered]@{schema='Q3AFORMAL_MANIFEST_BOUND_CACHE_1';executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();
    cache_metadata_path_length=$cachedManifest.Length;cases=@($first,$changed,$reuse,$copy)} | ConvertTo-Json -Depth 7 |
    Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: distinct manifest bytes allocate distinct keys for identical queries. Exact-byte copies reuse both checked proofs.'
