
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DevelopmentExecutable,
    [Parameter(Mandatory)][string]$StandardExecutable,
    [Parameter(Mandatory)][string]$CheckerExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$dev = (Resolve-Path -LiteralPath $DevelopmentExecutable).Path
$standard = (Resolve-Path -LiteralPath $StandardExecutable).Path
$checker = (Resolve-Path -LiteralPath $CheckerExecutable).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Test([string]$Name, [string]$Executable, [string[]]$Arguments) {
    $stdout = @(& $Executable @Arguments 2> "$root/$Name.stderr.txt")
    $exitCode = $LASTEXITCODE
    $stdout | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    [pscustomobject]@{Code = $exitCode; Stdout = $stdout -join [Environment]::NewLine}
}
function Require-Diagnostic([string]$Name, [string]$Executable, [string]$Manifest, [string]$Pattern) {
    $run = Invoke-Test $Name $Executable @('--lower-project', $Manifest)
    $diag = Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw
    if ($run.Code -eq 0 -or "$($run.Stdout) $diag" -cnotmatch $Pattern) {
        throw "$Name did not reject as expected. $diag $($run.Stdout)"
    }
}
function Require-Status([string]$Name, [string[]]$Arguments, [string]$Status) {
    $run = Invoke-Test $Name $dev $Arguments
    $model = $run.Stdout | ConvertFrom-Json
    if ($model.status -cne $Status -or $model.exit_code -ne $run.Code) {
        throw "$Name expected $Status. $($run.Stdout) $(Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw)"
    }
    $model
}

$lookup = @(foreach ($number in 0..31) {
    $bits = [Convert]::ToString($number, 2).PadLeft(5, '0')
    $ones = ($bits.ToCharArray() | Where-Object { $_ -eq '1' } | Measure-Object).Count
    "            5'b$bits : expected = 32'sd$ones;"
})
$rtl = @(
    'module vector_builtin(input logic clk, high_bit, low_bit, input logic [0:4] word);'
    '    logic [63:0] wide;'
    '    logic signed [31:0] expected;'
    "    assign wide = {high_bit, 62'b0, low_bit};"
    '    always_comb begin'
    '        case (word)'
) + $lookup + @(
    "            default : expected = 32'sd0;"
    '        endcase'
    '    end'
    '    p_count: assert property (@(posedge clk) $countones(word) == expected);'
    '    p_one: assert property (@(posedge clk) $onehot(word) == (expected == 32''sd1));'
    '    p_zero_or_one: assert property (@(posedge clk) $onehot0(word) == (expected <= 32''sd1));'
    '    p_wide: assert property (@(posedge clk) $onehot(wide) == (high_bit ^ low_bit));'
    '    p_max_count: assert property (@(posedge clk) $countones(64''hffff_ffff_ffff_ffff) == 32''sd64);'
    '    p_scalar: assert property (@(posedge clk) ($onehot(low_bit) == low_bit) && $onehot0(low_bit));'
    '    p_signed_compare: assert property (@(posedge clk) (($countones(word) - 32''sd1) < 32''sd0) == (expected == 32''sd0));'
    '    p_history: assert property (@(posedge clk) $onehot0($past(low_bit)));'
    '    c_zero: cover property (@(posedge clk) (word == 5''d0) && $onehot0(word) && !$onehot(word));'
    '    p_wrong: assert property (@(posedge clk) $onehot(word) == $onehot0(word));'
    'endmodule'
)
Set-Content -LiteralPath "$root/vector.sv" -Value $rtl -Encoding utf8NoBOM
$manifest = @('Q3AFORMAL_PROJECT 2','top vector_builtin','source systemverilog "vector.sv"')
$profile = 'option profile Q3A-SAMPLED-VALUE-DEVELOPMENT'
$project = "$root/vector.q3a"
Set-Content -LiteralPath $project -Value ($manifest + $profile) -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/baseline.q3a" -Value $manifest -Encoding utf8NoBOM
Require-Diagnostic implicit-baseline $dev "$root/baseline.q3a" 'unsupported system function'
Require-Diagnostic standard $standard $project 'profile'
$bad = @(
    @{name='arity'; source='p: assert property (@(posedge clk) $onehot(word,word));'; message='require one argument'},
    @{name='context'; source='assign x = $onehot(word);'; message='unsupported system function'}
)
foreach ($case in $bad) {
    Set-Content -LiteralPath "$root/$($case.name).sv" -Value "module vector_builtin(input logic clk, input logic [0:4] word, output logic x); $($case.source) endmodule" -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$($case.name).q3a" -Value (($manifest -replace 'vector\.sv', "$($case.name).sv") + $profile) -Encoding utf8NoBOM
    Require-Diagnostic $case.name $dev "$root/$($case.name).q3a" $case.message
}
$lower = Invoke-Test lower $dev @('--lower-project', $project)
$model = $lower.Stdout | ConvertFrom-Json
$history = $model.properties | Where-Object name -CEQ 'p_history'
if ($lower.Code -ne 0 -or $history.antecedent_history_guard_delay -ne 1 -or !$history.antecedent_history_guard_signal) {
    throw 'A nested sampled value lost its required prior sample.'
}

$names = @('p_count','p_one','p_zero_or_one','p_wide','p_max_count','p_scalar','p_signed_compare','p_history')
$results = @{}
foreach ($name in $names) {
    $proof = "$root/$name-certificate"
    $results[$name] = Require-Status $name @('prove',$project,'--engine','pdr','--property',$name,
        '--evidence-dir',$proof,'--max-depth','12') 'PROVEN'
    $replay = Invoke-Test "$name-reopen" $dev @('verify-pdr',$project,'--property',$name,'--evidence-dir',$proof)
    if ($replay.Code -ne 0 -or $replay.Stdout -cnotmatch 'Q3A_PDR_CERTIFICATE VERIFIED' -or
        $replay.Stdout -cnotmatch 'Q3A_PDR_RUN_CONFIGURATION VERIFIED') { throw "Source-bound proof failed to reopen for $name." }
}
$standalone = @(foreach ($obligation in $results.p_count.certificate.obligations) {
    $stem = $obligation.kind.Substring(4)
    $base = "$root/p_count-certificate/$stem"
    $result = Invoke-Test "standalone-$stem" $checker @('--check-drat',"$base.cnf","$base.q3adrat",'--model-sha256',
        $results.p_count.certificate.model_sha256,'--query-kind',$obligation.kind)
    if ($result.Code -ne 0 -or $result.Stdout -cnotmatch 'Q3A_PROOF_CHECK ACCEPTED' -or
        (Hash "$base.cnf") -cne $obligation.query_sha256 -or (Hash "$base.q3adrat") -cne $obligation.proof_sha256) {
        throw "Standalone count proof failed $stem."
    }
    $obligation
})
if ($standalone.Count -ne 3) { throw 'PDR count proof must have three independently checked obligations.' }
$null = Require-Status all-zero @('prove',$project,'--engine','bmc','--property','c_zero','--frames','0',
    '--bundle-dir',"$root/zero-cover") 'COVERED'
$null = Require-Status mutation @('prove',$project,'--engine','pdr','--property','p_wrong','--max-depth','8',
    '--evidence-dir',"$root/unused-proof",'--bundle-dir',"$root/zero-failure") 'FAIL'
foreach ($bundle in 'zero-cover','zero-failure') {
    $replay = Invoke-Test "$bundle-reopen" $dev @('--verify-bundle',"$root/$bundle",'--require-source-model')
    if ($replay.Code -ne 0 -or $replay.Stdout -cnotmatch 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $replay.Stdout -cnotmatch 'Q3A_BUNDLE_STATUS REVALIDATED') { throw "Source-backed witness failed to reopen for $bundle." }
}
[ordered]@{
    status = 'DEVELOPMENT_BIT_VECTOR_QUALIFIED'
    executable_sha256 = Hash $dev
    standard_sha256 = Hash $standard
    standalone_checker_sha256 = Hash $checker
    exhaustive_lookup_entries = $lookup.Count
    proven_and_source_revalidated = $names
    standalone_count_obligations = $standalone
    source_replayed_witnesses = @('zero-cover','zero-failure')
    negative_inputs = 4
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: all bit-vector functions matched an exhaustive five-bit truth table and passed scalar, signed-count, history and 64-bit checks.'

