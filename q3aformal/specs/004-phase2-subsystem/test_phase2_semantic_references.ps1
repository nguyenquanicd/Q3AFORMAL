#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('memory', 'clock')][string]$Fixture,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$CheckerPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).ProviderPath
$checker = (Resolve-Path -LiteralPath $CheckerPath).ProviderPath
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project = Join-Path $PSScriptRoot "scalar_${Fixture}_review.q3a"
$source = Join-Path $PSScriptRoot "scalar_${Fixture}_review.sv"

function Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$exeHash = Sha256 $exe
$checkerHash = Sha256 $checker
$projectHash = Sha256 $project
$sourceHash = Sha256 $source
$cases = if ($Fixture -eq 'memory') {
    @(
        @{ Name = 'read-range'; Property = 'read_in_range'; Status = 'PROVEN' },
        @{ Name = 'write-range'; Property = 'write_in_range'; Status = 'PROVEN' },
        @{ Name = 'read-old'; Property = 'read_old'; Status = 'PROVEN' },
        @{ Name = 'disabled-hold'; Property = 'disabled_read_holds'; Status = 'PROVEN' },
        @{ Name = 'write-one-cell'; Property = 'single_cell_update'; Status = 'PROVEN' },
        @{ Name = 'observable-collision'; Property = 'distinct_collision'; Status = 'COVERED' },
        @{ Name = 'unguarded-read'; Property = 'read_in_range'; Status = 'FAIL'; Parameter = 'CHECK_RANGE'; Value = '0' },
        @{ Name = 'unguarded-write'; Property = 'write_in_range'; Status = 'FAIL'; Parameter = 'CHECK_RANGE'; Value = '0' },
        @{ Name = 'write-first'; Property = 'read_old'; Status = 'FAIL'; Parameter = 'WRITE_FIRST'; Value = '1' }
    )
} else {
    @(
        @{ Name = 'hold-a'; Property = 'hold_a'; Status = 'PROVEN' },
        @{ Name = 'hold-b'; Property = 'hold_b'; Status = 'PROVEN' },
        @{ Name = 'reset-a'; Property = 'reset_on_a'; Status = 'PROVEN' },
        @{ Name = 'reset-b'; Property = 'reset_on_b'; Status = 'PROVEN' },
        @{ Name = 'joint-prestate'; Property = 'joint_prestate'; Status = 'PROVEN' },
        @{ Name = 'idle-history'; Property = 'idle_history'; Status = 'PROVEN' },
        @{ Name = 'local-history'; Property = 'local_history'; Status = 'PROVEN' },
        @{ Name = 'distinct-swap'; Property = 'distinct_swap'; Status = 'COVERED' },
        @{ Name = 'serialized-edge'; Property = 'joint_prestate'; Status = 'FAIL'; Parameter = 'SERIALIZE_JOINT_EDGE'; Value = '1' },
        @{ Name = 'peer-edge-history'; Property = 'idle_history'; Status = 'FAIL'; Parameter = 'ADVANCE_ON_PEER_EDGE'; Value = '1' }
    )
}
$results = foreach ($case in $cases) {
    $path = Join-Path $root $case.Name
    New-Item -ItemType Directory -Path $path | Out-Null
    $configuration = if ($case.Parameter) { @('--parameter', $case.Parameter, $case.Value) } else { @() }
    $proof = Join-Path $path 'certificate'
    $bundle = Join-Path $path 'bundle'
    $options = @('prove', $project) + $configuration + @('--engine', 'pdr',
        '--property', $case.Property, '--evidence-dir', $proof, '--bundle-dir', $bundle)
    $raw = @(& $exe @options 2> (Join-Path $path 'prove.stderr.txt'))
    $exitCode = $LASTEXITCODE
    $raw | Set-Content -LiteralPath (Join-Path $path 'result.json') -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($exitCode -ne 0 -or $raw.Count -ne 1 -or $result.status -cne $case.Status) {
        throw "Unexpected result for $($case.Name): exit $exitCode, $($result.status)."
    }
    $obligations = @()
    if ($case.Status -ceq 'PROVEN') {
        $log = @(& $exe verify-pdr $project --property $case.Property --evidence-dir $proof)
        if ($LASTEXITCODE -ne 0 -or $log -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw "Source certificate failed revalidation for $($case.Name)."
        }
        $log | Set-Content -LiteralPath (Join-Path $path 'revalidation.txt')
        $obligations = @(foreach ($item in $result.certificate.obligations) {
            $stem = $item.kind.Substring(4)
            $cnf = Join-Path $proof "$stem.cnf"
            $drat = Join-Path $proof "$stem.q3adrat"
            if ((Sha256 $cnf) -cne $item.query_sha256 -or (Sha256 $drat) -cne $item.proof_sha256) {
                throw "Certificate digest differs for $($case.Name)/$stem."
            }
            $checked = @(& $checker --check-drat $cnf $drat --model-sha256 $result.certificate.model_sha256 --query-kind $item.kind)
            if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
                throw "Standalone checker rejected $($case.Name)/$stem."
            }
            [ordered]@{ kind = $item.kind; query_sha256 = $item.query_sha256; proof_sha256 = $item.proof_sha256 }
        })
        if ($obligations.Count -ne 3) { throw "Expected three obligations for $($case.Name)." }
    } else {
        $log = @(& $exe --verify-bundle $bundle --require-source-model)
        if ($LASTEXITCODE -ne 0 -or $log -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
            $log -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            -not ($log -cmatch '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED')) {
            throw "Source witness failed revalidation for $($case.Name)."
        }
        $log | Set-Content -LiteralPath (Join-Path $path 'revalidation.txt')
    }
    [ordered]@{ name = $case.Name; property = $case.Property; status = $result.status; drat = $obligations }
}

if ((Sha256 $exe) -cne $exeHash -or (Sha256 $checker) -cne $checkerHash -or
    (Sha256 $project) -cne $projectHash -or (Sha256 $source) -cne $sourceHash) {
    throw 'Executable or fixture identity changed during qualification.'
}
[ordered]@{
    status = 'PASS'
    scope = 'SCALAR_REFERENCE_TRANSITION_ONLY'
    fixture = $Fixture
    runner_sha256 = Sha256 $PSCommandPath
    executable_sha256 = $exeHash
    checker_sha256 = $checkerHash
    project_sha256 = $projectHash
    source_sha256 = $sourceHash
    cases = @($results)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8NoBOM
"PASS: $Fixture scalar reference, independent certificates, cover and mutant witnesses."
