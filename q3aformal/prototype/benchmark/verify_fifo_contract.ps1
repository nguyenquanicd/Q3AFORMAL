#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ExecutablePath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$checker = Join-Path (Split-Path -Parent $exe) 'q3aformal-proofcheck.exe'
$manifest = Join-Path $PSScriptRoot 'fixtures/P1_fifo_contract.q3a'
$rtl = Join-Path $PSScriptRoot 'fixtures/P1_fifo_contract.sv'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName

function Run-Prove($Id, $Arguments, $Status, $ExitCode) {
    $stderr = Join-Path $root "$Id.log"
    $stdout = @(& $exe prove $manifest @Arguments 2> $stderr)
    $code = $LASTEXITCODE
    if ($stdout.Count -ne 1) { throw "Expected a single JSON summary for $Id." }
    $result = $stdout[0] | ConvertFrom-Json
    if ($code -ne $ExitCode -or $result.exit_code -ne $ExitCode -or $result.status -cne $Status) {
        throw "Unexpected result for ${Id}: $stdout. $(Get-Content -LiteralPath $stderr -Raw)"
    }
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Id.result.json") -Encoding utf8
    return $result
}

function Read-VerifiedBundle($Id, $Bundle, $ExpectedLine) {
    $verify = @(& $exe --verify-bundle $Bundle --require-source-model)
    if ($LASTEXITCODE -ne 0 -or $verify -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $verify -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or !($verify -cmatch $ExpectedLine)) {
        throw "Bundle verification failed for ${Id}: $verify"
    }
    $verify | Set-Content -LiteralPath (Join-Path $root "$Id.revalidation.txt") -Encoding utf8
}

function Check-Drat($Cnf, $Proof, $ModelHash, $Kind) {
    $result = @(& $checker --check-drat $Cnf $Proof --model-sha256 $ModelHash --query-kind $Kind)
    if ($LASTEXITCODE -ne 0 -or $result -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Standalone DRAT checker rejected ${Kind}: $result"
    }
    return [ordered]@{
        obligation=$Kind
        cnf_sha256=(Get-FileHash -LiteralPath $Cnf).Hash.ToLowerInvariant()
        proof_sha256=(Get-FileHash -LiteralPath $Proof).Hash.ToLowerInvariant()
        verdict=$result
    }
}

function Value($Signals, [string]$Name) {
    $value = $Signals[$Name]
    if ($null -eq $value -or $value -cnotmatch '^0x[0-9a-f]+$') {
        throw "Witness signal $Name is missing or invalid."
    }
    return [Convert]::ToInt32($value.Substring(2), 16)
}

function Check-QueueTrace($Id, $Trace, [int]$Terminal, [bool]$Mutated) {
    $data = Get-Content -LiteralPath $Trace -Raw | ConvertFrom-Json -AsHashtable
    if ($data.frames.Count -ne ($Terminal + 1) -or (Value $data.frames[0].signals 'rst') -ne 1) {
        throw "$Id did not start the expected transaction from reset."
    }
    $queue = [Collections.Generic.List[int]]::new()
    $observations = @(for ($frame = 1; $frame -le $Terminal; ++$frame) {
        $signals = $data.frames[$frame].signals
        $reset = (Value $signals 'rst') -eq 1
        if ($data.frames[$frame].index -ne $frame -or ($reset -and (!$Mutated -or $frame -lt $Terminal))) {
            throw "Unexpected frame index or reset in $Id at $frame."
        }
        $ready = (Value $signals 'out_ready') -eq 1
        $valid = (Value $signals 'in_valid') -eq 1
        $expectedInputReady = $queue.Count -lt 2 -or $ready
        $expectedOutputValid = $queue.Count -gt 0
        $push = $valid -and $expectedInputReady
        $pop = $ready -and $expectedOutputValid
        if ((Value $signals 'occupancy') -ne $queue.Count -or
            (Value $signals 'in_ready') -ne [int]$expectedInputReady -or
            (Value $signals 'out_valid') -ne [int]$expectedOutputValid) {
            throw "Queue handshake or occupancy diverged in $Id at frame $frame."
        }
        $expectFront = if ($expectedOutputValid) { $queue[0] }
        $dutFront = if ($expectedOutputValid) { Value $signals 'front' }
        $mismatch = $expectedOutputValid -and ($dutFront -ne $expectFront)
        if ($mismatch -ne ($Mutated -and $frame -eq $Terminal)) {
            throw "Unexpected queue payload in $Id at frame $frame. Expected $expectFront, observed $dutFront."
        }
        [ordered]@{
            frame=$frame; reset=$reset; occupancy=$queue.Count; push=$push; pop=$pop
            input_data=(Value $signals 'in_data'); expected_front=$expectFront; observed_front=$dutFront
        }
        if ($pop) { $queue.RemoveAt(0) }
        if ($push) { $queue.Add((Value $signals 'in_data')) }
    })
    if (!$observations[0].push -or $observations[0].pop -or
        !$observations[1].push -or $observations[1].pop -or
        $observations[2].occupancy -ne 2 -or !$observations[2].push -or !$observations[2].pop) {
        throw "$Id did not perform two fills followed by full simultaneous enqueue and dequeue."
    }
    if (!$Mutated -and (!$observations[3].pop -or $observations[3].push -or !$observations[4].pop -or
        $observations[4].push -or $observations[5].push -or $observations[5].occupancy -ne 0 -or
        $observations[0].input_data -ne 3 -or $observations[1].input_data -ne 9 -or
        $observations[2].input_data -ne 12 -or $observations[3].observed_front -ne 9 -or
        $observations[4].observed_front -ne 12)) {
        throw "$Id did not drain the two distinct remaining payloads in order."
    }
    return [ordered]@{
        trace_sha256=(Get-FileHash -LiteralPath $Trace).Hash.ToLowerInvariant()
        mismatch_frame=if ($Mutated) { $Terminal }
        reset_condition='synchronous reset at frame 0'
        observations=$observations
    }
}

$proofs = foreach ($property in 'p_reset','p_step','p_ports','p_full_replace') {
    $certificate = Join-Path $root "$property-certificate"
    $result = Run-Prove $property @('--timeout-ms','30000','--engine','pdr','--property',$property,
        '--max-depth','12','--evidence-dir',$certificate) 'PROVEN' 0
    $verify = @(& $exe verify-pdr $manifest --property $property --evidence-dir $certificate)
    if ($LASTEXITCODE -ne 0 -or $verify -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Source-backed PDR verification failed for $property."
    }
    $verify | Set-Content -LiteralPath (Join-Path $root "$property.revalidation.txt") -Encoding utf8
    $model = (Get-Content -LiteralPath (Join-Path $certificate 'invariant.txt') -TotalCount 2)[1]
    $checks = @(foreach ($kind in 'initiation','consecution','safety') {
        Check-Drat (Join-Path $certificate "$kind.cnf") (Join-Path $certificate "$kind.q3adrat") $model "pdr-$kind"
    })
    [ordered]@{property=$property; status=$result.status; elapsed_ms=$result.elapsed_ms; standalone_checks=$checks}
}

$induction = Join-Path $root 'induction-bundle'
$null = Run-Prove 'induction' @('--timeout-ms','30000','--engine','induction','--property','p_step','--k','2',
    '--output-prefix',(Join-Path $root 'induction'), '--bundle-dir',$induction) 'PROVEN' 0
Read-VerifiedBundle 'induction' $induction '^Q3A_BUNDLE_REVALIDATION ACCEPTED proof_artifacts=2$'
$inductionManifest = Get-Content -LiteralPath (Join-Path $induction 'manifest.json') -Raw | ConvertFrom-Json
$inductionChecks = @(foreach ($query in $inductionManifest.queries) {
    $proof = $inductionManifest.artifacts | Where-Object {
        $_.role -ceq 'checked_drat_proof' -and $_.path.EndsWith("/$($query.id).q3adrat")
    }
    if (!$proof) { throw "Induction proof $($query.id) is missing." }
    Check-Drat (Join-Path $induction $query.cnf_path) (Join-Path $induction $proof.path) $inductionManifest.model.sha256 $query.kind
})
if ($inductionChecks.Count -ne 2) { throw 'Expected two checked induction obligations.' }

$bounded = Join-Path $root 'bounded-pass'
$null = Run-Prove 'bounded-pass' @('--timeout-ms','30000','--engine','bmc','--property','p_full_replace',
    '--frames','4','--bundle-dir',$bounded) 'BOUNDED_PASS' 1
Read-VerifiedBundle 'bounded-pass' $bounded '^Q3A_BUNDLE_BMC_QUERY REVALIDATED status=BOUNDED_PASS bound=4$'

$cover = Join-Path $root 'cover'
$coverProperty = 'c_full_replace_drain'
$null = Run-Prove 'cover' @('--timeout-ms','30000','--engine','bmc','--property',$coverProperty,
    '--frames','6','--bundle-dir',$cover) 'COVERED' 0
Read-VerifiedBundle 'cover' $cover 'candidate_frame=6$'
$coverOracle = Check-QueueTrace 'cover' (Join-Path $cover "properties/$coverProperty/trace.json") 6 $false

$mutations = foreach ($engine in 'bmc','pdr') {
    $id = "wrong-replace-$engine"
    $bundle = Join-Path $root $id
    $limits = if ($engine -ceq 'bmc') { @('--frames','4') }
        else { @('--max-depth','8','--evidence-dir',(Join-Path $root "$id-certificate")) }
    $status = if ($engine -ceq 'bmc') { 'BOUNDED_FAIL' } else { 'FAIL' }
    $arguments = @('--parameter','WRONG_REPLACE','1','--timeout-ms','30000','--engine',$engine,'--property',
        'p_full_replace') + $limits + @('--bundle-dir',$bundle)
    $null = Run-Prove $id $arguments $status 0
    Read-VerifiedBundle $id $bundle 'candidate_frame=4$'
    [ordered]@{engine=$engine; status=$status; oracle=Check-QueueTrace $id (
        Join-Path $bundle 'properties/p_full_replace/trace.json') 4 $true}
}
[ordered]@{
    schema='Q3AFORMAL_FIFO_CONTRACT_QUALIFICATION_1'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    manifest_sha256=(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()
    rtl_sha256=(Get-FileHash -LiteralPath $rtl).Hash.ToLowerInvariant()
    capacity=2
    payload_bits=4
    pdr_proofs=$proofs
    induction_checks=$inductionChecks
    cover_oracle=$coverOracle
    mutations=$mutations
} | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS four PDR safety proofs, two k-induction obligations, bounded pass, drain cover and two independent software mutation replays.'
