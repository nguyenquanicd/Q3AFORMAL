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
$manifest = @('Q3AFORMAL_PROJECT 2','top sampled','source systemverilog "sampled.sv"',
    'option profile Q3A-FOUR-STATE-DEVELOPMENT')
$project = "$root/sampled.q3a"
Set-Content -LiteralPath $project -Encoding utf8NoBOM -Value $manifest
$rtl = @"
module sampled(input logic clk, gate, output logic procedural, merged, known_p,
    output logic got_x, got_z, a, b, hold);
    logic phase, was_x, was_z;
    always_ff @(posedge clk) begin
        if (gate) procedural <= 1'b1;
        else procedural <= 1'b0;
        if (1'b0) hold <= 1'b1;
        merged <= gate ? 1'b1 : 1'b0;
        was_x <= gate === 1'bx;
        was_z <= gate === 1'bz;
        phase <= 1'b1;
        a <= b;
        b <= (phase === 1'bx) ? 1'b1 : a;
    end
    assign known_p = (procedural === 1'b0) || (procedural === 1'b1);
    assign got_x = was_x && (procedural === 1'b0) && (merged === 1'bx);
    assign got_z = was_z && (procedural === 1'b0) && (merged === 1'bx);
endmodule
"@
Set-Content -LiteralPath "$root/sampled.sv" -Encoding utf8NoBOM -Value $rtl
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Status, [int]$Code, [string[]]$ArgsList) {
    $raw = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $report = $raw | ConvertFrom-Json
    if ($report.status -cne $Status -or $actual -ne $Code -or $report.exit_code -ne $Code) {
        throw "$Name expected $Status/$Code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $report
}
$search = @('dev-prove-four-state',$project,'--expect')
$verify = @('dev-verify-four-state',$project,'--expect')
$certificates = [ordered]@{}
$cases = @(
    @{name='startup'; signal='procedural'; expected='x'; steps='0'},
    @{name='known'; signal='known_p'; expected='1'; steps='1'},
    @{name='hold'; signal='hold'; expected='x'; steps='3'},
    @{name='a-step1'; signal='a'; expected='x'; steps='1'},
    @{name='b-step1'; signal='b'; expected='1'; steps='1'},
    @{name='a-step2'; signal='a'; expected='1'; steps='2'},
    @{name='b-step2'; signal='b'; expected='x'; steps='2'}
)
foreach ($case in $cases) {
    $name = $case.name
    $folder = "$root/proof-$name"
    $argsTail = @($case.signal,$case.expected,'--evidence-dir',$folder,'--steps',$case.steps)
    $proof = Run "proved-$name" BOUNDED_PASS 0 ($search + $argsTail)
    $checked = Run "reopened-$name" REVALIDATED 0 ($verify + $argsTail)
    if ($proof.steps -ne [int]$case.steps -or $checked.steps -ne $proof.steps -or
        $proof.query_sha256 -cne (Hash "$folder/query.cnf") -or $checked.proof_sha256 -cne $proof.proof_sha256) {
        throw "Incorrect sampled certificate identity at $name."
    }
    $records = @(& $checker --check-drat "$folder/query.cnf" "$folder/proof.q3adrat" --model-sha256 $proof.proof_model_sha256 --query-kind four-state-sampled-exact)
    if ($LASTEXITCODE -ne 0 -or $records -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "DRAT failed for $name." }
    $records | Set-Content -LiteralPath "$root/checker-$name.txt" -Encoding utf8NoBOM
    $certificates[$name] = $proof.proof_sha256
}
foreach ($bit in 'x','z') {
    $folder = "$root/fail-$bit"
    $failed = Run "fail-$bit" COUNTEREXAMPLE 0 ($search + @("got_$bit",'0','--evidence-dir',$folder,'--steps','1'))
    if (!$failed.source_replayed -or $failed.trace.Count -ne 2 -or
        $failed.trace[0].gate -cne $bit -or $failed.trace[0].procedural -cne 'x' -or
        $failed.trace[1].procedural -cne '0' -or $failed.trace[1].merged -cne 'x' -or
        $failed.signals.("got_$bit") -cne '1' -or (Test-Path -LiteralPath $folder)) {
        throw "Sequential replay failed the procedural and expression distinction at $bit."
    }
}
$null = Run no-steps REJECTED 2 ($search + @('procedural','x','--evidence-dir',"$root/no-steps"))
$null = Run different-bound REJECTED 2 ($verify + @('hold','x','--evidence-dir',"$root/proof-hold",'--steps','2'))
$null = Run over-limit REJECTED 2 ($search + @('a','x','--evidence-dir',"$root/over-limit",'--steps','129'))
$mods = [ordered]@{
    'clock-as-data'=$rtl.Replace('if (gate)', 'if (clk)')
    'blocking-assignment'=$rtl.Replace("if (gate) procedural <= 1'b1", "if (gate) procedural = 1'b1")
    'second-clock'=$rtl.Replace('input logic clk, gate', 'input logic clk, clk2, gate').Replace('    assign known_p', "    always_ff @(posedge clk2) begin phase <= 1'b0; end" + [Environment]::NewLine + '    assign known_p')
}
foreach ($name in $mods.Keys) {
    Set-Content -LiteralPath "$root/$name.sv" -Encoding utf8NoBOM -Value $mods[$name]
    Set-Content -LiteralPath "$root/$name.q3a" -Encoding utf8NoBOM -Value ($manifest -replace 'sampled\.sv', "$name.sv")
    $null = Run $name REJECTED 2 @('dev-prove-four-state',"$root/$name.q3a",'--expect','a','x','--evidence-dir',"$root/$name-rejected",'--steps','1')
}
[ordered]@{
    status = 'FOUR_STATE_SAMPLED_RTL_SAT_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    proof_sha256 = $certificates
    counterexamples_replayed = 2
    rejected_cases = 6
    source_sha256 = Hash "$root/sampled.sv"
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: seven source-regenerated sampled certificates, two replayed X/Z cases and six rejections.'
