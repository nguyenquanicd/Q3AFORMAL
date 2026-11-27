
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @(
    'module memory_activation(input logic clk, re, we, input logic [1:0] ra, wa, d,'
    '    output logic [1:0] q);'
    '    logic [1:0] words [0:3];'
    '    always_ff @(posedge clk) begin'
    '        if (re) q <= words[ra];'
    '        if (we) words[wa] <= d;'
    '    end'
    '    p_live: assert property (@(posedge clk) !re |=> q == $past(q));'
    '    p_dead: assert property (@(posedge clk) (re && !re) |=> q == $past(q));'
    '    p_immediate: assert property (@(posedge clk) 1''b1);'
)
function New-Project([string]$Name, [string[]]$Assumptions = @()) {
    Set-Content -LiteralPath "$root/$Name.sv" -Value ($rtl + $Assumptions + 'endmodule') -Encoding utf8NoBOM
    $project = "$root/$Name.q3a"
    Set-Content -LiteralPath $project -Value @('Q3AFORMAL_PROJECT 2','top memory_activation',
        "source systemverilog ""$Name.sv""") -Encoding utf8NoBOM
    $project
}
function Run-Memory([string]$Name, [string[]]$Arguments, [int]$Exit, [string]$Status) {
    $raw = @(& $exe @Arguments 2> "$root/$Name.stderr.txt")
    $code = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    $result = $raw | ConvertFrom-Json
    if ($code -ne $Exit -or $result.exit_code -ne $Exit -or $result.status -cne $Status) {
        throw "$Name expected $Status. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $result
}
function Expect-Activation([object]$Record, [int]$Bound, [string]$Status, [bool]$Witness) {
    if (!$Record.activation -or $Record.activation.status -cne $Status -or
        $Record.activation.transition_bound -ne $Bound -or
        ($Witness -and (!$Record.activation.PSObject.Properties['frame'] -or
            $Record.activation.frame -lt 0 -or $Record.activation.frame -gt $Bound)) -or
        (!$Witness -and $Record.activation.PSObject.Properties['frame'])) {
        throw "Unexpected activation payload: $($Record.activation | ConvertTo-Json -Compress)"
    }
}
$normal = New-Project normal
$pending = New-Project pending @('a_next: assume property (@(posedge clk) we |=> !we);')
$contradict = New-Project contradict @('a_yes: assume property (@(posedge clk) re);',
    'a_no: assume property (@(posedge clk) !re);')
$futureConflict = New-Project future-conflict @('a_now: assume property (@(posedge clk) !re);',
    'a_later: assume property (@(posedge clk) !re |=> re);')
$tests = @(
    @{name='live'; project=$normal; property='p_live'; bound=2; expected='ACTIVATED'; witness=$true},
    @{name='short'; project=$normal; property='p_live'; bound=0; expected='NOT_FOUND_WITHIN_BOUND'; witness=$false},
    @{name='dead'; project=$normal; property='p_dead'; bound=2; expected='NOT_FOUND_WITHIN_BOUND'; witness=$false},
    @{name='immediate'; project=$normal; property='p_immediate'; bound=0; expected='ACTIVATED'; witness=$true},
    @{name='pending'; project=$pending; property='p_live'; bound=2; expected='PENDING_ASSUMPTION'; witness=$true}
)
$records = @(foreach ($case in $tests) {
    $proofDir = "$root/$($case.name)-proof"
    $prove = @('dev-prove-memory',$case.project,'--property',$case.property,'--output-dir',$proofDir,
        '--max-cells','4','--activation-frames',[string]$case.bound)
    $reopen = @('dev-verify-memory',$case.project,'--property',$case.property,'--evidence-dir',$proofDir,
        '--max-cells','4','--activation-frames',[string]$case.bound)
    $result = Run-Memory $case.name $prove 0 PROVEN
    $verified = Run-Memory "$($case.name)-verified" $reopen 0 REVALIDATED
    Expect-Activation $result $case.bound $case.expected $case.witness
    Expect-Activation $verified $case.bound $case.expected $case.witness
    if ($result.model_input_sha256 -cne $verified.model_input_sha256) { throw 'Proof identity changed at reopen.' }
    [ordered]@{name=$case.name; initial=$result.activation; reopened=$verified.activation}
})
$legacy = Run-Memory default @('dev-verify-memory',$normal,'--property','p_live','--evidence-dir',"$root/live-proof",
    '--max-cells','4') 0 REVALIDATED
if ($legacy.PSObject.Properties['activation']) { throw 'Default proof replay performed activation analysis.' }
$failures = @(foreach ($case in @(@{name='sample0'; manifest=$contradict; bound=0},
                                  @{name='delayed'; manifest=$futureConflict; bound=1})) {
    $proofDir = "$root/$($case.name)-impossible"
    $result = Run-Memory $case.name @('dev-prove-memory',$case.manifest,'--property','p_live','--output-dir',$proofDir,
        '--max-cells','4') 1 INCONSISTENT
    if ($result.inconsistent_bound -ne $case.bound -or $result.property -cne 'p_live' -or
        (Test-Path -LiteralPath $proofDir)) { throw 'Contradictory environment was misclassified.' }
    [ordered]@{name=$case.name; inconsistent_bound=$result.inconsistent_bound}
})
[ordered]@{
    status = 'MEMORY_ACTIVATION_AND_FEASIBILITY_QUALIFIED'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    proof_activation_cases = $records
    inconsistent_environments = $failures
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: five bounded activation outcomes independently replayed or classified, and two infeasible environments rejected.'

