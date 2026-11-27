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
function Fixture($Name, $Source, [switch]$Baseline) {
    $Source | Set-Content -LiteralPath "$root/$Name.sv" -Encoding utf8NoBOM
    $manifest = @('Q3AFORMAL_PROJECT 2', 'top named', ('source systemverilog "{0}.sv"' -f $Name))
    if (!$Baseline) { $manifest += 'option profile Q3A-FOUR-STATE-DEVELOPMENT' }
    $manifest | Set-Content -LiteralPath "$root/$Name.q3a" -Encoding utf8NoBOM
}
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }

Fixture named @'
module observer(input logic clk, input logic d);
    logic q;
    always_ff @(posedge clk) begin q <= d; end
    sequence zz; d === 1'bz; endsequence
    property alias_prop();
        base_prop()
    endproperty : alias_prop
    property base_prop;
        @(posedge clk) zz |=> q === 1'bz;
    endproperty
    property cover_z; q === 1'bz; endproperty
    p_capture: assert property (alias_prop());
    c_z: cover property (@(posedge clk) cover_z());
endmodule
module named(input logic clk, input logic d);
    observer left(.clk(clk), .d(d));
    observer right(.clk(clk), .d(1'b0));
    property input_z; @(posedge clk) d === 1'bz; endproperty
    a_input: assume property (input_z());
    p_input: assert property (input_z);
    c_input: cover property (input_z);
endmodule
'@

function Run($Id, $Property, $Status, [int]$Code, [switch]$Verify) {
    $command = if ($Verify) { 'dev-verify-four-state' } else { 'dev-prove-four-state' }
    $raw = & $exe $command "$root/named.q3a" --property $Property --evidence-dir "$root/$Property" --steps 1 2> "$root/$Id.stderr.txt"
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Id.json" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($actual -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Id expected $Status/$Code. $raw $(Get-Content "$root/$Id.stderr.txt" -Raw)"
    }
    $result
}

$certificates = [ordered]@{}
foreach ($case in @(
    @{ property='left.p_capture'; status='BOUNDED_PASS'; kind='four-state-sampled-sva'; code=0 },
    @{ property='p_input'; status='BOUNDED_PASS'; kind='four-state-sampled-sva'; code=0 },
    @{ property='right.c_z'; status='NOT_FOUND_WITHIN_BOUND'; kind='four-state-sampled-cover'; code=1 }
)) {
    $property = $case.property
    $proof = Run "$property-check" $property $case.status $case.code
    $reopened = Run "$property-verify" $property REVALIDATED 0 -Verify
    $accepted = @(& $checker --check-drat "$root/$property/query.cnf" "$root/$property/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind $case.kind)
    if ($LASTEXITCODE -ne 0 -or $accepted -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED' -or
        $proof.proof_sha256 -cne $reopened.proof_sha256) { throw "Invalid certificate for $property." }
    $accepted | Set-Content -LiteralPath "$root/$property-checker.txt" -Encoding utf8NoBOM
    $certificates[$property] = $proof.proof_sha256
}

$witnesses = [ordered]@{}
foreach ($case in @(@{ property='left.c_z'; sample=1 }, @{ property='c_input'; sample=0 })) {
    $property = $case.property
    $hit = Run "$property-hit" $property COVERED 0
    $reopened = Run "$property-replay" $property COVERED 0 -Verify
    if (!$reopened.witness_revalidated -or !$reopened.source_replayed -or
        $reopened.witness_sha256 -cne $hit.witness_sha256 -or $reopened.match_sample -ne $case.sample) {
        throw "Incorrect replay for $property."
    }
    $witnesses[$property] = $reopened.witness_sha256
}

$model = & $exe dev-lower-four-state "$root/named.q3a" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $model.clocks.Count -ne 1 -or $model.clocks[0] -cne 'clk') {
    throw 'The declaration clock did not bind to the top-level clock.'
}
$instance = $model.properties | Where-Object name -CEQ 'left.p_capture'
if ($instance.kind -cne 'assert' -or $instance.source.line -ne 12 -or
    $instance.antecedent.terms[0].predicate.source.line -ne 4 -or
    $instance.consequent.terms[0].predicate.source.line -ne 9) {
    throw 'The lowered assertion lost either its check location or the declaration expression locations.'
}

$rejections = @(
    @{ name='missing-clock'; body='property p; a; endproperty assert property (p());'; match='requires one explicit sampling clock' },
    @{ name='conflict'; body='property p; @(posedge clk) a; endproperty assert property (@(posedge other) p());'; match='conflicting named property clocks' },
    @{ name='recursive'; body='property p; @(posedge clk) r(); endproperty property r; p; endproperty assert property (p());'; match='recursive or excessively nested named property' },
    @{ name='undefined'; body='assert property (unknown_prop());'; match='unresolved property reference' },
    @{ name='argument'; body='property p; @(posedge clk) a; endproperty assert property (p(a));'; match='named property arguments' },
    @{ name='parameter'; body='property p(input logic d); @(posedge clk) d; endproperty assert property (p);'; match='named property parameters' },
    @{ name='end-label'; body='property p; @(posedge clk) a; endproperty : wrong assert property (p);'; match='endproperty label differs' },
    @{ name='duplicate'; body='property p; @(posedge clk) a; endproperty property p; @(posedge clk) a; endproperty assert property (p);'; match='duplicate property declaration' },
    @{ name='collision'; body='property a; @(posedge clk) 1; endproperty assert property (a);'; match='conflicting named property declaration' }
)
foreach ($case in $rejections) {
    $name = $case.name
    Fixture $name "module named(input logic clk, other, a); $($case.body) endmodule"
    & $exe dev-lower-four-state "$root/$name.q3a" > "$root/$name.stdout.txt" 2> "$root/$name.stderr.txt"
    if ($LASTEXITCODE -ne 2 -or (Get-Content "$root/$name.stderr.txt" -Raw) -notlike "*$($case.match)*") {
        throw "Unexpected rejection for $name. $(Get-Content "$root/$name.stderr.txt" -Raw)"
    }
}

Fixture baseline 'module named(input logic clk, a); property p; @(posedge clk) a; endproperty s: assert property (p); endmodule' -Baseline
& $exe --lower-project "$root/baseline.q3a" > "$root/baseline.stdout.txt" 2> "$root/baseline.stderr.txt"
if ($LASTEXITCODE -ne 0 -or !((Get-Content "$root/baseline.stdout.txt" -Raw) -match '"name":"s"')) {
    throw 'The original baseline named-property syntax regressed.'
}
[ordered]@{
    status = 'FOUR_STATE_NAMED_PROPERTY_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/named.sv"
    proof_sha256 = $certificates
    witness_sha256 = $witnesses
    rejected_cases = $rejections.Count
    baseline_named_property_preserved = $true
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: reusable named properties, inherited clocks, hierarchical replay, checked certificates, and nine rejections.'
