#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @"
module sva_live(input logic clk, req, enable, grant);
    logic delayed, owed;
    always_ff @(posedge clk) begin
        delayed <= req;
        owed <= (owed || req) && !grant;
    end
    p_overlap: assert property (@(posedge clk) (req && enable) |-> s_eventually (req && enable));
    p_next_fail: assert property (@(posedge clk) (req && enable) |=> s_eventually (req && enable));
    property p_delay_decl;
        @(posedge clk) req |=> s_eventually delayed;
    endproperty
    p_next_ok: assert property (p_delay_decl);
    p_fair: assert property (@(posedge clk) req |-> s_eventually ((owed || req) && grant));
    p_safety: assert property (@(posedge clk) req |=> delayed);
endmodule
"@
$manifest = @('Q3AFORMAL_PROJECT 2', 'top sva_live', 'source systemverilog "live.sv"',
    'option profile Q3A-LIVENESS-DEVELOPMENT')
Set-Content -LiteralPath "$root/live.sv" -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/live.q3a" -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/baseline.q3a" -Value $manifest[0..2] -Encoding utf8NoBOM
$caseCount = 0
function Run([string]$Name, [string]$Expected, [int]$Code, [string[]]$ArgsList) {
    $output = @(& $exe @ArgsList 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $result = $output | ConvertFrom-Json
    if ($result.status -cne $Expected -or $actual -ne $Code) {
        throw "$Name expected $Expected/$Code. $output $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    ++$script:caseCount
    $result
}
$project = "$root/live.q3a"
$direct = @('dev-check-liveness',$project,'--property')
$null = Run overlap NO_VIOLATION 0 ($direct + 'p_overlap')
$archive = "$root/strict.q3live"
$violation = Run next-only VIOLATION 0 ($direct + @('p_next_fail','--evidence',$archive))
if ($violation.property -cne 'p_next_fail' -or $violation.path.Count -lt 3 -or
    !$violation.path[$violation.loop_start].waiting) {
    throw 'The strict next-sample result did not include a pending lasso.'
}
$signalMask = @{}
$offset = 0
foreach ($signal in $violation.input_layout) {
    if ($signal.name -in 'req','enable') { $signalMask[$signal.name] = 1 -shl $offset }
    $offset += $signal.width
}
if ($signalMask.Count -ne 2) { throw 'Missing lasso input fields.' }
$both = $signalMask.req -bor $signalMask.enable
$antecedentSeen = $false
for ($index = 0; $index -lt $violation.path.Count; ++$index) {
    $level = ($violation.path[$index].input -band $both) -eq $both
    if ($index -lt $violation.loop_start) {
        $antecedentSeen = $antecedentSeen -or $level
    } elseif ($level) {
        throw 'The strict lasso loop includes a future response.'
    }
}
if (!$antecedentSeen) { throw 'The lasso prefix lacks a triggering request.' }
$check = @('dev-verify-liveness',$project,'--property')
$verified = Run reopened VIOLATION 0 ($check + @('p_next_fail','--evidence',$archive))
if (!$verified.evidence_revalidated -or $verified.evidence_sha256 -cne $violation.evidence_sha256) {
    throw 'Named assertion archive did not reopen.'
}
$null = Run swapped-property REJECTED 2 ($check + @('p_overlap','--evidence',$archive))
$null = Run named-declaration NO_VIOLATION 0 ($direct + 'p_next_ok')
$null = Run no-justice VIOLATION 0 ($direct + 'p_fair')
$null = Run with-justice NO_VIOLATION 0 ($direct + @('p_fair','--justice','grant'))
$null = Run conflicting-query REJECTED 2 ($direct + @('p_fair','--request','req','--response','grant'))
$null = Run unrelated-safety REJECTED 2 ($direct + 'p_safety')
$null = Run baseline-rejects REJECTED 2 @('dev-check-liveness',"$root/baseline.q3a",'--property','p_fair')

foreach ($setup in @(
    @{name='bounded'; engine='bmc'; options=@('--frames','2')},
    @{name='induction'; engine='induction'; options=@('--k','1','--output-prefix',"$root/ind")},
    @{name='pdr'; engine='pdr'; options=@('--evidence-dir',"$root/pdr")}
)) {
    $null = Run $setup.name UNSUPPORTED 2 (@('prove',$project,'--engine',$setup.engine,'--property','p_next_fail') + $setup.options)
}
$null = Run finite-safety BOUNDED_PASS 1 @('prove',$project,'--engine','bmc','--property','p_safety','--frames','2')

foreach ($setup in @(
    @{name='range'; fragment='req |-> s_eventually [1:3] delayed'; kind='assert'},
    @{name='sequence'; fragment='req ##1 enable |-> s_eventually delayed'; kind='assert'},
    @{name='sampled-history'; fragment='req |-> s_eventually $past(delayed)'; kind='assert'},
    @{name='assume'; fragment='req |-> s_eventually delayed'; kind='assume'},
    @{name='cover'; fragment='req |-> s_eventually delayed'; kind='cover'}
)) {
    $name = $setup.name
    $changed = $rtl.Replace('assert property (@(posedge clk) (req && enable) |-> s_eventually (req && enable))',
        "$($setup.kind) property (@(posedge clk) $($setup.fragment))")
    Set-Content -LiteralPath "$root/$name.sv" -Value $changed -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$name.q3a" -Value ($manifest -replace 'live\.sv',"$name.sv") -Encoding utf8NoBOM
    $null = Run $name REJECTED 2 @('dev-check-liveness',"$root/$name.q3a",'--property','p_overlap')
}

[ordered]@{
    status = 'SVA_LIVENESS_PROFILE_QUALIFIED'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    command_cases = $caseCount
    reports = @(Get-ChildItem -LiteralPath $root -Filter '*.json' | Sort-Object Name | ForEach-Object {
        @{name=$_.Name; sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    })
    named_archive_sha256 = $verified.evidence_sha256
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: $caseCount named SVA liveness and safety-dispatch cases."
