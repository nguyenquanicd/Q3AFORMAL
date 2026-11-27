#requires -Version 7.0
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$checker="$repo/prototype/bin/q3aformal-proofcheck.exe"
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$ref="$root/ref.q3a"
$imp="$root/imp.q3a"
$rtl="$root/imp.sv"
@('Q3AFORMAL_PROJECT 2','top gold','source systemverilog "ref.sv"')|Set-Content -LiteralPath $ref
@('Q3AFORMAL_PROJECT 2','top gate_image','source systemverilog "imp.sv"')|Set-Content -LiteralPath $imp
@'
module gold(input logic clk, input logic [1:0] d, output logic [1:0] y);
    always_ff @(posedge clk) begin
        y <= d;
    end
endmodule
'@|Set-Content -LiteralPath "$root/ref.sv"
$source=@'
module gate_image(input logic ck, input logic [1:0] value, output logic [1:0] result);
    logic [1:0] encoded;
    always_ff @(posedge ck) begin
        encoded <= ~value;
    end
    assign result = ~encoded;
endmodule
'@
$source|Set-Content -LiteralPath $rtl
$plan="$root/matched.q3e"
$prefix=@('Q3AFORMAL_EQUIVALENCE 1','clock clk ck','input d value','output y result')
($prefix+@('initial matched','state y encoded invert'))|Set-Content -LiteralPath $plan
$independent="$root/independent.q3e"
($prefix+@('initial independent','state y encoded invert'))|Set-Content -LiteralPath $independent

function Invoke-Case([string]$Name,[int]$Code,[string]$Status,[string]$UsePlan=$plan,
    [string]$Evidence="$root/$Name",[switch]$Verify) {
    $command=if($Verify){'verify-equivalence'}else{'check-equivalence'}
    $option=if($Verify){'--evidence-dir'}else{'--output-dir'}
    $out=@(& $exe $command $ref $imp --plan $UsePlan $option $Evidence 2> "$root/$Name.stderr")
    $actual=$LASTEXITCODE
    $out|Set-Content -LiteralPath "$root/$Name.json"
    if($actual -ne $Code -or $out.Count -ne 1){throw "Unexpected result $Name $actual $out $(Get-Content -Raw "$root/$Name.stderr")"}
    $report=$out[0]|ConvertFrom-Json
    if($report.status -cne $Status){throw "Unexpected status $Name $out"}
    return $report
}

$positive=Invoke-Case valid-pair 0 EQUIVALENT
$verified=Invoke-Case proof-reopen 0 CERTIFICATE_REVALIDATED $plan "$root/valid-pair" -Verify
if($positive.scope -cne 'MATCHED_INITIAL_STATES' -or $positive.context_sha256 -cne $verified.context_sha256){
    throw 'The explicit initial pair scope was not retained on reopening.'
}
foreach($role in 'state','output'){
    $dir=if($role -ceq 'state'){'state-certificate'}else{'certificate'}
    $digest=if($role -ceq 'state'){$positive.state_certificate_model_sha256}else{$positive.certificate_model_sha256}
    foreach($kind in 'initiation','consecution','safety'){
        $files="$root/valid-pair/$dir/$kind"
        $out=@(& $checker --check-drat "$files.cnf" "$files.q3adrat" --model-sha256 $digest --query-kind "pdr-$kind")
        if($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED'){throw "Independent proof failed $role $kind"}
        $out|Set-Content -LiteralPath "$root/$role-$kind.verifier"
    }
}

$failure=Invoke-Case independent 0 STATE_RELATION_VIOLATED $independent
if($failure.frame -ne 0 -or $failure.scope -cne 'INDEPENDENT_INITIAL_STATES'){throw 'Independent scope silently matched states.'}
$null=Invoke-Case changed-scope 2 REJECTED $independent "$root/valid-pair" -Verify
$noRelation="$root/no-relation.q3e"
($prefix+'initial matched')|Set-Content -LiteralPath $noRelation
$null=Invoke-Case missing-relation 2 REJECTED $noRelation

$source.Replace('encoded <= ~value;','encoded <= value;')|Set-Content -LiteralPath $rtl
$changed=Invoke-Case bad-step 0 STATE_RELATION_VIOLATED
if($changed.frame -ne 1 -or $changed.failed_obligation -cne 'STATE_PRESERVATION'){
    throw 'The initial relation was incorrectly assumed for a future sample.'
}
$null=Invoke-Case bad-step-reopen 0 STATE_WITNESS_REVALIDATED $plan "$root/bad-step" -Verify

$trace="$root/bad-step/state-witness.txt"
$hashFile="$trace.sha256"
$traceBytes=[IO.File]::ReadAllBytes($trace)
$hashBytes=[IO.File]::ReadAllBytes($hashFile)
$rows=[Text.Encoding]::UTF8.GetString($traceBytes).Split([char]10)
$values=$rows[3].TrimEnd().Split()
# ref.clk, ref.d, ref.y, imp.result, imp.encoded, control.started
if($values.Count -ne 6 -or ([int]$values[2] -bxor [int]$values[4]) -ne 3){throw 'Unexpected legal initial witness pair.'}
$values[2]=$values[4]
$rows[3]=($values -join ' ')+' '
[IO.File]::WriteAllText($trace,($rows -join [char]10))
[IO.File]::WriteAllText($hashFile,(Get-FileHash -LiteralPath $trace).Hash.ToLowerInvariant()+[char]10)
try {$null=Invoke-Case illegal-initial-pair 2 REJECTED $plan "$root/bad-step" -Verify}
finally {
    [IO.File]::WriteAllBytes($trace,$traceBytes)
    [IO.File]::WriteAllBytes($hashFile,$hashBytes)
}

$source.Replace('assign result = ~encoded;','assign result = encoded;')|Set-Content -LiteralPath $rtl
$wrongOutput=Invoke-Case sample-zero-output 0 NOT_EQUIVALENT
if($wrongOutput.frame -ne 0 -or !$wrongOutput.state_certificate_model_sha256){
    throw 'The matched scope suppressed the first output sample.'
}
$null=Invoke-Case output-witness-reopen 0 WITNESS_REVALIDATED $plan "$root/sample-zero-output" -Verify
$source|Set-Content -LiteralPath $rtl
[ordered]@{
    status='PASS'
    executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    independently_checked_obligations=6
    independent_start_difference=$failure.frame
    later_state_relation_difference=$changed.frame
    initial_output_difference=$wrongOutput.frame
    rejected_refreshed_trace_outside_initial_scope=$true
    verified_scope=$verified.scope
}|ConvertTo-Json|Set-Content -LiteralPath "$root/qualification.json"
'PASS: explicitly matched starts, checked later preservation, sample-zero observation and source-bound replay.'
