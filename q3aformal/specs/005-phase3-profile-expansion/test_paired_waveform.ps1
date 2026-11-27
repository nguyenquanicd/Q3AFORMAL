#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$EquivalenceEvidence,
    [Parameter(Mandatory)][string]$StateEvidence,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$exe=(Resolve-Path -LiteralPath $ExecutablePath).Path
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$eq=(Resolve-Path -LiteralPath $EquivalenceEvidence).Path
$state=(Resolve-Path -LiteralPath $StateEvidence).Path
$sha=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
foreach($folder in $eq,$state){
    $q=Get-Content -Raw "$folder/qualification.json"|ConvertFrom-Json
    if($q.executable_sha256 -cne $sha -or $q.status -cne 'PASS'){throw 'Mismatch fixture must use this exact build'}
}

function Test-Waveform([string]$Case,[string]$Folder,[string]$Report) {
    $verdict=Get-Content -Raw $Report|ConvertFrom-Json
    $vcd=Join-Path $Folder $verdict.waveform_file
    $data=& $exe trace import-vcd $vcd --q3a-roundtrip
    if($LASTEXITCODE -ne 0){throw "Round-trip VCD import rejected $Case"}
    $parsed=$data|ConvertFrom-Json
    $prefix='__q3a_equivalence_product.'
    $names=@($parsed.signals|ForEach-Object {($_.scope -join '.')+'.'+$_.name})
    $marker=[Array]::IndexOf($names,$prefix+'__q3a_diagnostic.failure_sample')
    if($marker -lt 0 -or $parsed.formal_evidence -or $parsed.four_state -or
        -not @($names|Where-Object {$_ -like "$($prefix)shared.*"}).Count){
        throw 'The waveform lacks the shared-input scope or diagnostic marker.'
    }
    $found=@()
    $atFailure=$null
    $values=@{}
    foreach($sample in $parsed.samples){
        foreach($change in $sample.changes){$values[$names[[int]$change[0]]]=[string]$change[1]}
        if($values[$names[$marker]] -ceq '1'){$found+=[int]$sample.timestamp}
        if([int]$sample.timestamp -eq $verdict.frame){$atFailure=$values.Clone()}
    }
    if($found.Count -ne 1 -or $found[0] -ne $verdict.frame -or !$atFailure){throw 'Wrong failure marker sample'}
    foreach($diff in $verdict.mismatches){
        $left=[Convert]::ToUInt64($atFailure[$prefix+$diff.reference_signal],2)
        $right=[Convert]::ToUInt64($atFailure[$prefix+$diff.implementation_signal],2)
        if($left.ToString() -cne $diff.reference_value -or $right.ToString() -cne $diff.implementation_value){
            throw 'The waveform disagreement does not match the checked witness report.'
        }
    }
    $data|Set-Content -LiteralPath "$root/$Case.roundtrip.json"
    $html=@(& $exe trace view-vcd $vcd)
    if($LASTEXITCODE -ne 0 -or ($html -join [char]10) -notmatch 'failure_sample'){
        throw 'Could not produce the offline waveform view.'
    }
    $html|Set-Content -LiteralPath "$root/$Case.html"
    return @{case=$Case;frame=$verdict.frame;signals=$parsed.signals.Count;samples=$parsed.samples.Count;
        waveform_sha256=(Get-FileHash -LiteralPath $vcd).Hash.ToLowerInvariant()}
}

$output=Test-Waveform output "$eq/wrong-update" "$eq/wrong-update.json"
$relation=Test-Waveform state "$state/bad-step" "$state/bad-step.json"

# The source fixtures were restored by the qualification scripts. Recreate only the
# tested faulty source in a working copy, then reopen the existing waveform evidence.
$temp="$root/reconstructed"
New-Item -ItemType Directory -Path $temp|Out-Null
Copy-Item -LiteralPath "$eq/ref.q3a","$eq/imp.q3a","$eq/reference.sv","$eq/reset.q3e" -Destination $temp
(Get-Content -Raw "$eq/implementation.sv").Replace('else encoded <= !value;','else encoded <= value;') |
    Set-Content -LiteralPath "$temp/implementation.sv" -NoNewline
$commands=@('verify-equivalence',"$temp/ref.q3a","$temp/imp.q3a",'--plan',"$temp/reset.q3e",'--evidence-dir',"$eq/wrong-update")
$verified=& $exe @commands
if($LASTEXITCODE -ne 0 -or ($verified|ConvertFrom-Json).status -cne 'WITNESS_REVALIDATED'){
    throw 'Generated waveform did not reopen from reconstructed source.'
}
$path="$eq/wrong-update/paired-witness.vcd"
$original=[IO.File]::ReadAllBytes($path)
try {
    $edited=[Text.Encoding]::UTF8.GetString($original) -creplace '(?m)^1f$','0f'
    if($edited -ceq [Text.Encoding]::UTF8.GetString($original)){throw 'Did not replace the marker'}
    [IO.File]::WriteAllText($path,$edited)
    $discard=& $exe @commands 2> "$root/changed-marker.stderr"
    if($LASTEXITCODE -ne 2 -or (Get-Content -Raw "$root/changed-marker.stderr") -notmatch 'waveform differs'){
        throw 'A changed failure marker passed witness reopening.'
    }
} finally {[IO.File]::WriteAllBytes($path,$original)}
Rename-Item -LiteralPath $path -NewName 'paired-witness.saved'
try {
    $discard=& $exe @commands 2> "$root/missing-waveform.stderr"
    if($LASTEXITCODE -ne 2){throw 'A version 2 witness reopened without a waveform.'}
} finally {Rename-Item -LiteralPath "$eq/wrong-update/paired-witness.saved" -NewName 'paired-witness.vcd'}

$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$old="$repo/evidence/r-p2-equivalence"
$legacy=& $exe verify-equivalence "$old/ref.q3a" "$old/imp.q3a" --plan "$old/independent.q3e" --evidence-dir "$old/initial-pairs"
if($LASTEXITCODE -ne 0 -or ($legacy|ConvertFrom-Json).status -cne 'WITNESS_REVALIDATED' -or
    ($legacy|ConvertFrom-Json).PSObject.Properties.Name -contains 'waveform_file'){
    throw 'Version 1 witness compatibility changed.'
}
[ordered]@{status='PASS';executable_sha256=$sha;waveforms=@($output,$relation);former_witness='REVALIDATED';
    changed_marker_rejected=$true;missing_waveform_rejected=$true}|ConvertTo-Json -Depth 5|
    Set-Content -LiteralPath "$root/qualification.json"
'PASS: paired output and state waveforms round-trip, display offline and reject marker or artifact changes.'
