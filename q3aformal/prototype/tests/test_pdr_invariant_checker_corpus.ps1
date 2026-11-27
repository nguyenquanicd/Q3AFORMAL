#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$project = Join-Path $prototype 'pdr-pipeline.q3a'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$original = Join-Path $root 'valid'

function Invoke-Case([string]$Name, [int]$Exit, [string]$Program, [string[]]$Options) {
    $stderr = Join-Path $root "$Name.stderr.txt"
    $stdout = @(& $Program @Options 2> $stderr)
    $actual = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath (Join-Path $root "$Name.stdout.txt") -Encoding utf8
    $errorText = [IO.File]::ReadAllText($stderr)
    if ($actual -ne $Exit) { throw "$Name expected exit $Exit, got $actual. $stdout $errorText" }
    return ($stdout -join [char]10) + $errorText
}

function Test-Invariant([int]$State, [string[]]$Clauses) {
    foreach ($clause in $Clauses) {
        $satisfied = $false
        foreach ($literal in ($clause.Trim() -split '\s+')) {
            $lit = [int]$literal
            if ($lit -eq 0) { break }
            $value = [bool]($State -band (1 -shl ([Math]::Abs($lit) - 1)))
            if ($value -eq ($lit -gt 0)) { $satisfied = $true; break }
        }
        if (!$satisfied) { return $false }
    }
    return $true
}

function Measure-Obligations([string[]]$Clauses) {
    $initialFailures = @()
    $stepFailures = @()
    $safetyFailures = @()
    foreach ($state in 0..63) {
        $q1 = [int][bool]($state -band 1)
        $q2 = [int][bool]($state -band 2)
        $history0 = [int][bool]($state -band 4)
        $history1 = [int][bool]($state -band 8)
        $valid0 = [int][bool]($state -band 16)
        $valid1 = [bool]($state -band 32)
        $holds = Test-Invariant $state $Clauses
        if (!$valid0 -and !$valid1 -and !$holds) { $initialFailures += $state }
        if (!$holds) { continue }
        if ($valid1 -and $q2 -ne $history1) { $safetyFailures += $state }
        foreach ($a in 0,1) {
            $next = $a + (2 * $q1) + (4 * $a) + (8 * $history0) + 16 + (32 * $valid0)
            if (!(Test-Invariant $next $Clauses)) { $stepFailures += @{state=$state;a=$a;next=$next} }
        }
    }
    return [ordered]@{initiation=@($initialFailures);consecution=@($stepFailures);safety=@($safetyFailures)}
}

$model = Invoke-Case lowered 0 $exe @('--lower-project',$project) | ConvertFrom-Json
$expectedOrder = 'q1,q2,__q3a_history_data_0_stage_0,__q3a_history_data_0_stage_1,__q3a_history_valid_stage_0,__q3a_history_valid_stage_1'
if (($model.next_state_equations.target -join ',') -cne $expectedOrder) {
    throw 'Certificate bit order no longer matches the independently reviewed RTL oracle.'
}
$proved = & $exe prove $project --evidence-dir $original 2> (Join-Path $root 'prove.stderr.txt') | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $proved.status -cne 'PROVEN') { throw 'The source pipeline failed to produce a certificate.' }
$invariant = [IO.File]::ReadAllLines((Join-Path $original 'invariant.txt'))
$header = $invariant[0..2]
$learned = Measure-Obligations $invariant[3..($invariant.Count - 1)]
if ($learned.initiation.Count + $learned.consecution.Count + $learned.safety.Count -ne 0) {
    throw 'The production invariant fails the independent source transition oracle.'
}

$verify = @('verify-pdr',$project,'--property','p_safe','--evidence-dir')
$first = Invoke-Case valid-first 0 $exe ($verify + $original)
$second = Invoke-Case valid-second 0 $exe ($verify + $original)
if ($first -cne $second -or $first -notmatch 'Q3A_PDR_CERTIFICATE VERIFIED') {
    throw 'The same valid certificate did not produce a stable verdict.'
}
foreach ($kind in 'initiation','consecution','safety') {
    $cnf = Join-Path $original "$kind.cnf"
    $proof = Join-Path $original "$kind.q3adrat"
    $accepted = Invoke-Case "valid-$kind" 0 $checker @('--check-drat',$cnf,$proof,
        '--model-sha256',$proved.certificate.model_sha256,'--query-kind',"pdr-$kind")
    if ($accepted -notmatch 'Q3A_PROOF_CHECK ACCEPTED') { throw "Standalone checker rejected $kind." }
}

$relationFirst = @('-1 3 -5 0','1 -3 -5 0')
$relationSecond = @('-2 4 -6 0','2 -4 -6 0')
$reference = Measure-Obligations ($relationFirst + $relationSecond)
if ($reference.initiation.Count + $reference.consecution.Count + $reference.safety.Count -ne 0) {
    throw 'The manual reference invariant is invalid.'
}
$negatives = foreach ($scenario in @(
    @{case='false-initiation';kind='initiation';clauses=($relationFirst + $relationSecond + '5 0')},
    @{case='false-consecution';kind='consecution';clauses=$relationSecond},
    @{case='false-safety';kind='safety';clauses=$relationFirst}
)) {
    $counts = Measure-Obligations $scenario.clauses
    foreach ($kind in 'initiation','consecution','safety') {
        if (($counts[$kind].Count -gt 0) -ne ($kind -ceq $scenario.kind)) {
            throw "$($scenario.case) does not isolate $($scenario.kind)."
        }
    }
    $directory = Join-Path $root $scenario.case
    Copy-Item -LiteralPath $original -Destination $directory -Recurse
    [IO.File]::WriteAllText((Join-Path $directory 'invariant.txt'),
        (($header + $scenario.clauses) -join [char]10) + [char]10)
    $rejected = Invoke-Case $scenario.case 3 $exe ($verify + $directory)
    if ($rejected -notmatch 'saved PDR query differs from the regenerated obligation') {
        throw "$($scenario.case) failed to reject the changed invariant against the original query bytes."
    }
    [ordered]@{case=$scenario.case;failed_obligation=$scenario.kind;oracle_counterexamples=$counts[$scenario.kind];
        verifier_rejected_at='regenerated-query-binding'}
}

$malformed = Join-Path $root 'malformed-invariant'
Copy-Item -LiteralPath $original -Destination $malformed -Recurse
[IO.File]::WriteAllText((Join-Path $malformed 'invariant.txt'),
    (($header + '1 1 0') -join [char]10) + [char]10)
$diagnostic = Invoke-Case malformed 3 $exe ($verify + $malformed)
if ($diagnostic -notmatch 'literal is out of range, repeated, or unordered') {
    throw 'Malformed repeated state literal was not diagnosed.'
}

$incomplete = Join-Path $root 'incomplete-proof'
Copy-Item -LiteralPath $original -Destination $incomplete -Recurse
$changed = Join-Path $incomplete 'consecution.q3adrat'
$lines = [IO.File]::ReadAllLines($changed)
if ($lines[-2].Trim() -cne '0' -or $lines[-1] -cne 'proof_end' -or $lines[5] -notmatch '^proof_records ([0-9]+)$') {
    throw 'Expected checked proof records terminated by the empty clause.'
}
$lines[5] = "proof_records $([int]$Matches[1] - 1)"
[IO.File]::WriteAllText($changed, (($lines[0..($lines.Count - 3)] + 'proof_end') -join [char]10) + [char]10)
$diagnostic = Invoke-Case incomplete 3 $exe ($verify + $incomplete)
if ($diagnostic -notmatch 'empty clause|record count') { throw 'An incomplete proof yielded the wrong diagnostic.' }
$diagnostic = Invoke-Case incomplete-standalone 1 $checker @('--check-drat',
    (Join-Path $incomplete 'consecution.cnf'),$changed,'--model-sha256',$proved.certificate.model_sha256,
    '--query-kind','pdr-consecution')
if ($diagnostic -notmatch 'Q3A_PROOF_CHECK REJECTED' -or $diagnostic -notmatch 'empty clause|record count') {
    throw 'The standalone checker did not reject the incomplete proof.'
}

$swapped = foreach ($kind in 'initiation','consecution','safety') {
    $directory = Join-Path $root ("unrelated-$kind-" + ('x' * 120))
    Copy-Item -LiteralPath $original -Destination $directory -Recurse
    $cnf = Join-Path $directory "$kind.cnf"
    $proof = Join-Path $directory "$kind.q3adrat"
    if ($cnf.Length -lt 260 -or $proof.Length -lt 260) {
        throw 'Expected a long Windows path for the standalone proof tools.'
    }
    [IO.File]::WriteAllText($cnf, (@('p cnf 1 2','1 0','-1 0') -join [char]10) + [char]10)
    Remove-Item -LiteralPath $proof
    $metadata = @('--model-sha256',$proved.certificate.model_sha256,'--query-kind',"pdr-$kind")
    $null = Invoke-Case "create-unrelated-$kind" 0 $checker (@('--create-drat',$cnf,$proof) + $metadata)
    $accepted = Invoke-Case "check-unrelated-$kind" 0 $checker (@('--check-drat',$cnf,$proof) + $metadata)
    if ($accepted -notmatch 'Q3A_PROOF_CHECK ACCEPTED') { throw "$kind replacement pair is not a valid proof." }
    $sameFile = Invoke-Case "reject-overwrite-$kind" 1 $checker (@('--create-drat',$cnf,$cnf) + $metadata)
    if ($sameFile -notmatch 'output path must not overwrite the CNF input' -or
        (Get-FileHash -LiteralPath $cnf).Hash.ToLowerInvariant() -cne
            [regex]::Match($accepted, 'Q3A_PROOF_QUERY_SHA256 ([0-9a-f]{64})').Groups[1].Value) {
        throw "$kind same-file protection did not preserve the original query."
    }
    $rejected = Invoke-Case "reject-unrelated-$kind" 3 $exe ($verify + $directory)
    if ($rejected -notmatch 'saved PDR query differs from the regenerated obligation') {
        throw "$kind replacement pair was not rejected at query binding."
    }
    [ordered]@{kind=$kind;cnf_path_length=$cnf.Length;proof_path_length=$proof.Length;input_preserved=$true}
}
$again = Invoke-Case valid-after-defects 0 $exe ($verify + $original)
if ($again -cne $first) { throw 'Defect checks changed the original verdict.' }

[ordered]@{
    schema='Q3AFORMAL_INVARIANT_CHECKER_CORPUS_1'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    checker_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    checked_initial_states=16; checked_transition_inputs=128; checked_safety_states=64
    learned_invariant_counterexamples=$learned
    semantic_negatives=@($negatives)
    malformed_invariant_rejected=$true
    incomplete_proof_rejected=$true
    incomplete_proof_rejected_standalone=$true
    valid_but_unrelated_pairs_rejected=@($swapped)
    repeated_valid_verdict_identical=$true
} | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: independently evaluated PDR invariant, isolated semantic defects, malformed records, and deterministic certificate verdicts.'
