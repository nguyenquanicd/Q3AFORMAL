param([string[]] $Bundle = @(), [string[]] $PdrEvidence = @())

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Read-DimacsCnf([string]$Path) {
    $variableCount = $null
    $declaredClauseCount = $null
    $clauses = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[int]]::new()

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('c')) { continue }
        if ($trimmed.StartsWith('p ')) {
            if ($null -ne $variableCount) { throw "Multiple DIMACS headers in $Path" }
            $header = $trimmed -split '\s+'
            if ($header.Count -ne 4 -or $header[1] -ne 'cnf') { throw "Invalid DIMACS header in $Path" }
            $variableCount = [int]$header[2]
            $declaredClauseCount = [int]$header[3]
            continue
        }
        if ($null -eq $variableCount) { throw "DIMACS clause precedes header in $Path" }
        foreach ($token in ($trimmed -split '\s+')) {
            $literal = [int]$token
            if ($literal -eq 0) {
                $clauses.Add([int[]]$pending.ToArray())
                $pending.Clear()
            } else {
                if ([Math]::Abs($literal) -gt $variableCount) { throw "Literal outside DIMACS variable range in $Path" }
                $pending.Add($literal)
            }
        }
    }

    if ($null -eq $variableCount -or $pending.Count -ne 0) { throw "Incomplete DIMACS input: $Path" }
    if ($clauses.Count -ne $declaredClauseCount) {
        throw "DIMACS clause count mismatch in ${Path}: expected $declaredClauseCount, found $($clauses.Count)"
    }
    return [pscustomobject]@{ VariableCount = $variableCount; Clauses = $clauses }
}

function Test-RupFullScan([int]$VariableCount, [System.Collections.Generic.List[object]]$Database, [int[]]$Candidate) {
    $assignment = [int[]]::new($VariableCount + 1)
    foreach ($literal in $Candidate) {
        $variable = [Math]::Abs($literal)
        $falsifyingValue = if ($literal -gt 0) { -1 } else { 1 }
        if ($assignment[$variable] -ne 0 -and $assignment[$variable] -ne $falsifyingValue) { return $true }
        $assignment[$variable] = $falsifyingValue
    }

    while ($true) {
        $changed = $false
        foreach ($clause in $Database) {
            $satisfied = $false
            $unassignedCount = 0
            $unitLiteral = 0
            foreach ($literal in [int[]]$clause) {
                $variable = [Math]::Abs($literal)
                $value = $assignment[$variable]
                if (($literal -gt 0 -and $value -eq 1) -or ($literal -lt 0 -and $value -eq -1)) {
                    $satisfied = $true
                    break
                }
                if ($value -eq 0) {
                    $unassignedCount++
                    $unitLiteral = $literal
                }
            }
            if ($satisfied) { continue }
            if ($unassignedCount -eq 0) { return $true }
            if ($unassignedCount -eq 1) {
                $variable = [Math]::Abs($unitLiteral)
                $requiredValue = if ($unitLiteral -gt 0) { 1 } else { -1 }
                if ($assignment[$variable] -ne 0 -and $assignment[$variable] -ne $requiredValue) { return $true }
                if ($assignment[$variable] -eq 0) {
                    $assignment[$variable] = $requiredValue
                    $changed = $true
                }
            }
        }
        if (-not $changed) { return $false }
    }
}

function Test-ExhaustiveEntailment([int]$VariableCount, [System.Collections.Generic.List[object]]$Database, [int[]]$Candidate) {
    $assignmentCount = [int][Math]::Pow(2, $VariableCount)
    for ($mask = 0; $mask -lt $assignmentCount; $mask++) {
        $satisfiesDatabase = $true
        foreach ($clause in $Database) {
            $clauseSatisfied = $false
            foreach ($literal in [int[]]$clause) {
                $isSet = (($mask -band (1 -shl ([Math]::Abs($literal) - 1))) -ne 0)
                if (($literal -gt 0 -and $isSet) -or ($literal -lt 0 -and -not $isSet)) {
                    $clauseSatisfied = $true
                    break
                }
            }
            if (-not $clauseSatisfied) { $satisfiesDatabase = $false; break }
        }
        if (-not $satisfiesDatabase) { continue }

        $satisfiesCandidate = $false
        foreach ($literal in $Candidate) {
            $isSet = (($mask -band (1 -shl ([Math]::Abs($literal) - 1))) -ne 0)
            if (($literal -gt 0 -and $isSet) -or ($literal -lt 0 -and -not $isSet)) {
                $satisfiesCandidate = $true
                break
            }
        }
        if (-not $satisfiesCandidate) { return $false }
    }
    return $true
}

function Test-RupArtifact([string]$CnfPath, [string]$ArtifactPath,
                          [string]$ModelHash = '', [string]$Kind = '') {
    $parsedCnf = Read-DimacsCnf $CnfPath
    $cnfBytes = [System.IO.File]::ReadAllBytes($CnfPath)
    $queryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cnfBytes)).ToLowerInvariant()
    $lines = [System.IO.File]::ReadAllLines($ArtifactPath)
    if ($lines.Count -lt 7 -or $lines[0] -ne 'Q3A_DRAT_ARTIFACT 2') { throw "Unsupported proof artifact: $ArtifactPath" }
    $metadata = @{}
    foreach ($line in $lines[1..4]) {
        $parts = $line -split '\s+', 2
        $metadata[$parts[0]] = $parts[1]
    }
    if ($metadata.query_sha256 -ne $queryHash) { throw "Query identity mismatch for $ArtifactPath" }
    if ($metadata.checker_id -ne 'q3a-drat-checker-0.2') { throw "Unexpected checker identity in $ArtifactPath" }
    if ($metadata.query_kind -notin @('induction-base', 'induction-step',
        'pdr-initiation', 'pdr-consecution', 'pdr-safety')) {
        throw "Unexpected query kind in $ArtifactPath"
    }
    if ($metadata.model_sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid model identity in $ArtifactPath" }
    if (($ModelHash -and $metadata.model_sha256 -cne $ModelHash) -or
        ($Kind -and $metadata.query_kind -cne $Kind)) {
        throw "Proof does not identify its expected model and obligation in $ArtifactPath"
    }
    $recordLine = $lines | Where-Object { $_ -match '^proof_records\s+' } | Select-Object -First 1
    if (-not $recordLine -or $recordLine -notmatch '^proof_records\s+[0-9]+$') { throw "Missing or invalid proof record count in $ArtifactPath" }
    $declaredRecords = [int](($recordLine -split '\s+')[1])

    $inProof = $false
    $proofEndFound = $false
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq 'proof_begin') { $inProof = $true; continue }
        if ($proofEndFound) {
            if ($trimmed) { throw "Unexpected data after proof_end in $ArtifactPath" }
            continue
        }
        if ($trimmed -eq 'proof_end') { $inProof = $false; $proofEndFound = $true; continue }
        if (-not $inProof -or -not $trimmed) { continue }
        if ($trimmed -match '^d\s') { throw "This independent RUP oracle does not accept deletion records: $ArtifactPath" }
        $tokens = $trimmed -split '\s+'
        if ($tokens[-1] -ne '0') { throw "Unterminated DRAT record in $ArtifactPath" }
        $clause = [System.Collections.Generic.List[int]]::new()
        if ($tokens.Count -gt 1) {
            foreach ($token in $tokens[0..($tokens.Count - 2)]) {
                $literal = [int]$token
                if ($literal -eq 0 -or [Math]::Abs($literal) -gt $parsedCnf.VariableCount) {
                    throw "Invalid literal in $ArtifactPath"
                }
                $clause.Add($literal)
            }
        }
        $records.Add([int[]]$clause.ToArray())
    }
    if (-not $proofEndFound) { throw "Missing proof_end in $ArtifactPath" }
    if ($records.Count -ne $declaredRecords) { throw "DRAT record count mismatch in $ArtifactPath" }

    $database = $parsedCnf.Clauses
    $emptyClauseDerived = $false
    foreach ($record in $records) {
        if ($emptyClauseDerived) { throw "Unexpected record after the empty clause in $ArtifactPath" }
        if (-not (Test-RupFullScan $parsedCnf.VariableCount $database ([int[]]$record))) {
            throw "Independent full-scan RUP check rejected an addition in $ArtifactPath"
        }
        $database.Add([int[]]$record)
        if ($record.Count -eq 0) { $emptyClauseDerived = $true }
    }
    if (-not $emptyClauseDerived) { throw "Proof did not derive the empty clause: $ArtifactPath" }
}

# Validate the oracle itself exhaustively on a small entailment and a false empty-clause claim.
$tinySat = [System.Collections.Generic.List[object]]::new()
$tinySat.Add([int[]]@(1, 2))
$tinySat.Add([int[]]@(-1, 2))
$tinyCandidate = [int[]]@(2)
if (-not (Test-ExhaustiveEntailment 2 $tinySat $tinyCandidate)) { throw 'Tiny truth-table entailment fixture failed.' }
if (-not (Test-RupFullScan 2 $tinySat $tinyCandidate)) { throw 'Tiny full-scan RUP fixture failed.' }
$falseEmpty = [System.Collections.Generic.List[object]]::new()
$falseEmpty.Add([int[]]@(1))
if (Test-ExhaustiveEntailment 1 $falseEmpty ([int[]]@())) { throw 'Truth-table oracle accepted an invalid empty-clause proof.' }
if (Test-RupFullScan 1 $falseEmpty ([int[]]@())) { throw 'Full-scan RUP oracle accepted an invalid empty-clause proof.' }

$proofPairs = @(
    @('evidence/benchmark/preflight/B-01-counter4-2026-11-19/queries/p_wraps_to_zero.base.cnf', 'evidence/benchmark/preflight/B-01-counter4-2026-11-19/properties/p_wraps_to_zero/base.q3adrat'),
    @('evidence/benchmark/preflight/B-01-counter4-2026-11-19/queries/p_wraps_to_zero.step.cnf', 'evidence/benchmark/preflight/B-01-counter4-2026-11-19/properties/p_wraps_to_zero/step.q3adrat'),
    @('evidence/benchmark/preflight/B-03-casez-2026-11-19/queries/p_casez_decode_matches_priority.base.cnf', 'evidence/benchmark/preflight/B-03-casez-2026-11-19/properties/p_casez_decode_matches_priority/base.q3adrat'),
    @('evidence/benchmark/preflight/B-03-casez-2026-11-19/queries/p_casez_decode_matches_priority.step.cnf', 'evidence/benchmark/preflight/B-03-casez-2026-11-19/properties/p_casez_decode_matches_priority/step.q3adrat'),
    @('evidence/conformance/rtl-015-concat-three-2026-11-19/queries/p_three_member_concat_order.base.cnf', 'evidence/conformance/rtl-015-concat-three-2026-11-19/properties/p_three_member_concat_order/base.q3adrat'),
    @('evidence/conformance/rtl-015-concat-three-2026-11-19/queries/p_three_member_concat_order.step.cnf', 'evidence/conformance/rtl-015-concat-three-2026-11-19/properties/p_three_member_concat_order/step.q3adrat'),
    @('evidence/conformance/rtl-007-fill-literals-2026-11-19/queries/p_fill_context_width.base.cnf', 'evidence/conformance/rtl-007-fill-literals-2026-11-19/properties/p_fill_context_width/base.q3adrat'),
    @('evidence/conformance/rtl-007-fill-literals-2026-11-19/queries/p_fill_context_width.step.cnf', 'evidence/conformance/rtl-007-fill-literals-2026-11-19/properties/p_fill_context_width/step.q3adrat'),
    @('evidence/conformance/rtl-005-decimal-context-2026-11-19/proof.base.cnf', 'evidence/conformance/rtl-005-decimal-context-2026-11-19/proof.base.q3adrat'),
    @('evidence/conformance/rtl-005-decimal-context-2026-11-19/proof.step.cnf', 'evidence/conformance/rtl-005-decimal-context-2026-11-19/proof.step.q3adrat')
)
foreach ($pair in $proofPairs) {
    $cnfPath = Join-Path $repoRoot $pair[0]
    $artifactPath = Join-Path $repoRoot $pair[1]
    Test-RupArtifact $cnfPath $artifactPath
}

Write-Output 'PASS: exhaustive tiny-formula checks and independent full-scan RUP validation accepted ten B-01/B-03/RTL-015/RTL-007/RTL-005 induction artifacts.'

foreach ($path in $PdrEvidence) {
    $root = (Resolve-Path -LiteralPath $path).Path
    $header = @(Get-Content -LiteralPath (Join-Path $root 'invariant.txt') -TotalCount 3)
    if ($header.Count -ne 3 -or $header[0] -cne 'Q3A_PDR_INVARIANT 1' -or
        $header[1] -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Expected a PDR invariant header with a model digest.'
    }
    foreach ($obligation in 'initiation', 'consecution', 'safety') {
        Test-RupArtifact (Join-Path $root "$obligation.cnf") (
            Join-Path $root "$obligation.q3adrat") $header[1] "pdr-$obligation"
        Write-Output "PASS: independent full-scan RUP accepted PDR $obligation for $($header[2])"
    }
}

foreach ($path in $Bundle) {
    $root = (Resolve-Path -LiteralPath $path).Path
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    $modelPath = Join-Path $root $manifest.model.path
    $modelHash = (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.result.status -cne 'PROVEN' -or $manifest.result.bound -ne 1 -or
        $manifest.model.sha256 -cne $modelHash) {
        throw "Expected a one-inductive proof with a matching model digest: $path"
    }
    foreach ($id in @('base', 'step')) {
        $queries = @($manifest.queries | Where-Object id -CEQ $id)
        $kind = "induction-$id"
        if ($queries.Count -ne 1 -or $queries[0].kind -cne $kind -or
            $queries[0].status -cne 'UNSAT_CHECKED') {
            throw "Expected one checked $kind query in $path"
        }
        $query = $queries[0]
        $cnf = Join-Path $root $query.cnf_path
        if ((Get-FileHash -LiteralPath $cnf -Algorithm SHA256).Hash.ToLowerInvariant() -cne $query.cnf_sha256) {
            throw "Query digest mismatch for $kind in $path"
        }
        $artifact = Join-Path $root "properties/$($manifest.result.property)/$id.q3adrat"
        Test-RupArtifact $cnf $artifact $modelHash $kind
        Write-Output "PASS: independent full-scan RUP accepted $kind for $($manifest.result.property)"
    }
}
