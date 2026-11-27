#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$CheckerPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @'
module cover_demo(input logic clk, input logic d, input logic req);
    logic q;
    always_ff @(posedge clk) begin q <= d; end
    scalar_z: cover property (@(posedge clk) d === 1'bz);
    unknown: cover property (@(posedge clk) 1'bx);
    delayed: cover property (@(posedge clk) (d === 1'bz) ##[2:3] ($past(d, 2) === 1'bz));
    repeat_z: cover property (@(posedge clk) (d === 1'bz)[*2:3]);
    overlap: cover property (@(posedge clk) (d === 1'bz) |-> (d === 1'bz));
    nonoverlap: cover property (@(posedge clk) (d === 1'bz) |=> (q === 1'bz));
    vacuous: cover property (@(posedge clk) 1'b0 |-> 1'b1);
    always_holds: assert property (@(posedge clk) 1'b1);
    ASSUMPTION
endmodule
'@
$cases = [ordered]@{
    base = ''
    closed = "env: assume property (@(posedge clk) d !== 1'bz);"
    feasible = "env: assume property (@(posedge clk) req === 1'b0);"
    open = 'env: assume property (@(posedge clk) req |=> !req);'
    inconsistent = "env: assume property (@(posedge clk) 1'bx);"
}
foreach ($name in $cases.Keys) {
    $rtl.Replace('ASSUMPTION', $cases[$name]) | Set-Content -LiteralPath "$root/$name.sv" -Encoding utf8NoBOM
    @('Q3AFORMAL_PROJECT 2','top cover_demo',('source systemverilog "{0}.sv"' -f $name),
        'option profile Q3A-FOUR-STATE-DEVELOPMENT') |
        Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM
}

function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Id, $ExpectedStatus, [int]$Code, $Project, $Property, $Steps, $Directory, [switch]$Verify) {
    $command = if ($Verify) { 'dev-verify-four-state' } else { 'dev-prove-four-state' }
    $raw = @(& $exe $command "$root/$Project.q3a" --property $Property --evidence-dir $Directory --steps $Steps 2> "$root/$Id.stderr.txt")
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($result.status -cne $ExpectedStatus -or $actual -ne $Code -or $result.exit_code -ne $Code) {
        throw "$Id expected $ExpectedStatus/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$unused = "$root/no-certificate"
$hits = [ordered]@{}
foreach ($item in @(
    @{property='scalar_z'; steps=0; matched=0},
    @{property='delayed'; steps=2; matched=2},
    @{property='repeat_z'; steps=1; matched=1},
    @{property='overlap'; steps=0; matched=0; antecedent=0},
    @{property='nonoverlap'; steps=1; matched=1; antecedent=0}
)) {
    $name = $item.property
    $path = "$root/witness-$name"
    $witness = Run "hit-$name" COVERED 0 base $name $item.steps $path
    $reopened = Run "reopen-$name" COVERED 0 base $name $item.steps $path -Verify
    if ($witness.witness_revalidated -or !$reopened.witness_revalidated -or
        $witness.witness_sha256 -cne (Hash "$path/cover.q3awitness") -or
        $reopened.witness_sha256 -cne $witness.witness_sha256 -or
        $reopened.attempt_sample -ne $witness.attempt_sample -or
        $reopened.match_sample -ne $witness.match_sample -or
        (ConvertTo-Json -InputObject $reopened.trace -Compress -Depth 6) -cne
        (ConvertTo-Json -InputObject $witness.trace -Compress -Depth 6)) {
        throw "Saved witness did not independently reproduce $name."
    }
    if (!$witness.source_replayed -or $witness.property_kind -cne 'cover' -or
        $witness.attempt_sample -ne 0 -or $witness.match_sample -ne $item.matched -or
        $witness.trace.Count -ne ($item.steps + 1) -or $witness.trace[0].d -cne 'z' -or
        $witness.antecedent_end_sample -ne $item.antecedent -or
        ($name -in @('repeat_z','nonoverlap') -and $witness.signals.q -cne 'z')) {
        throw "Incorrect match or four-state witness for $name."
    }
    $hits[$name] = $reopened.witness_sha256
}
$proofs = [ordered]@{}
foreach ($item in @(
    @{id='unknown'; project='base'; property='unknown'; steps=2},
    @{id='vacuous'; project='base'; property='vacuous'; steps=2},
    @{id='short'; project='base'; property='delayed'; steps=1},
    @{id='nonoverlap-short'; project='base'; property='nonoverlap'; steps=0},
    @{id='excluded'; project='closed'; property='scalar_z'; steps=1}
)) {
    $path = "$root/proof-$($item.id)"
    $miss = Run "miss-$($item.id)" NOT_FOUND_WITHIN_BOUND 1 $item.project $item.property $item.steps $path
    $checked = Run "check-$($item.id)" REVALIDATED 0 $item.project $item.property $item.steps $path -Verify
    $records = @(& $checker --check-drat "$path/query.cnf" "$path/proof.q3adrat" --model-sha256 $checked.proof_model_sha256 --query-kind four-state-sampled-cover)
    if ($miss.property_kind -cne 'cover' -or $checked.property_kind -cne 'cover' -or
        $miss.proof_sha256 -cne $checked.proof_sha256 -or $checked.query_sha256 -cne (Hash "$path/query.cnf") -or
        $LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
        throw "Cover miss certificate failed qualification for $($item.id)."
    }
    $records | Set-Content -LiteralPath "$root/checker-$($item.id).txt" -Encoding utf8NoBOM
    $proofs[$item.id] = $checked.proof_sha256
}
$pendingPath = "$root/witness-pending"
$pending = Run pending WITNESS_PENDING_ASSUMPTION 1 open scalar_z 1 $pendingPath
$reopened = Run reopened-pending WITNESS_PENDING_ASSUMPTION 1 open scalar_z 1 $pendingPath -Verify
if (!$reopened.witness_revalidated -or $reopened.witness_sha256 -cne (Hash "$pendingPath/cover.q3awitness")) {
    throw 'An unfinished environment lost its provisional status on replay.'
}
if (!$pending.source_replayed -or !$pending.assumption_boundary_open -or $pending.signals.d -cne 'z') {
    throw 'Unfinished assumptions must mark a valid cover match as provisional.'
}
$inconsistent = Run inconsistent INCONSISTENT 1 inconsistent scalar_z 0 $unused
if ($inconsistent.property_kind -cne 'cover' -or (Test-Path -LiteralPath $unused)) {
    throw 'An inconsistent environment or a witness unexpectedly published a certificate.'
}
$null = Run wrong-bound REJECTED 2 base delayed 2 "$root/proof-short" -Verify
$null = Run wrong-property REJECTED 2 base always_holds 2 "$root/proof-unknown" -Verify
$null = Run assumption-as-goal REJECTED 2 closed env 1 $unused

$sourcePath = "$root/witness-scalar_z"
$preserved = Hash "$sourcePath/cover.q3awitness"
$null = Run existing-witness REJECTED 2 base scalar_z 0 $sourcePath
if ((Hash "$sourcePath/cover.q3awitness") -cne $preserved) { throw 'A new run overwrote existing evidence.' }
$null = Run wrong-witness-bound REJECTED 2 base scalar_z 1 $sourcePath -Verify
$null = Run wrong-witness-environment REJECTED 2 closed scalar_z 0 $sourcePath -Verify
$feasible = "$root/witness-feasible"
$null = Run constrained-hit COVERED 0 feasible scalar_z 0 $feasible
$null = Run constrained-reopen COVERED 0 feasible scalar_z 0 $feasible -Verify
function ReviewModified($Name, $Project, $Content, $Diagnostic) {
    $dir = (New-Item -ItemType Directory -Path "$root/mutated-$Name").FullName
    [IO.File]::WriteAllText("$dir/cover.q3awitness", $Content)
    $null = Run $Name REJECTED 2 $Project scalar_z 0 $dir -Verify
    if ((Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw) -notlike "*$Diagnostic*") {
        throw "Incorrect rejection reason for $Name."
    }
}
$rawWitness = [IO.File]::ReadAllText("$sourcePath/cover.q3awitness")
$payloadOffset = $rawWitness.LastIndexOf([char]10, $rawWitness.Length - 2) + 1
$invalidTrace = $rawWitness.Substring(0, $payloadOffset) + '0' + $rawWitness.Substring($payloadOffset + 1)
ReviewModified no-match base $invalidTrace 'does not reach the selected property'
ReviewModified truncated base ($rawWitness.Substring(0, $rawWitness.Length - 1)) 'invalid four-state cover witness sample boundary'
ReviewModified trailing base ($rawWitness + 'unexpected') 'unexpected data following'
ReviewModified wrong-schema base ($rawWitness.Replace('WITNESS_1','WITNESS_9')) 'identity differs'
$rawFeasible = [IO.File]::ReadAllText("$feasible/cover.q3awitness")
if (!$rawFeasible.EndsWith(('z0' + [char]10))) { throw 'Constrained trace did not contain the fixture input values.' }
ReviewModified violated-assumption feasible ($rawFeasible.Substring(0, $rawFeasible.Length - 2) + '1' + [char]10) 'violates an assumption'
$ambiguous = (New-Item -ItemType Directory -Path "$root/ambiguous").FullName
Copy-Item -LiteralPath "$sourcePath/cover.q3awitness" -Destination $ambiguous
Copy-Item -LiteralPath "$root/proof-unknown/query.cnf" -Destination $ambiguous
$null = Run ambiguous REJECTED 2 base scalar_z 0 $ambiguous -Verify
[ordered]@{
    status = 'FOUR_STATE_COVER_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    witness_sha256 = $hits
    proof_sha256 = $proofs
    provisional_case = 'pending'
    witness_reopen_cases = 7
    rejected_cases = 12
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: five reopened cover hits, five checked misses, constrained and provisional reopen, and twelve rejections.'
