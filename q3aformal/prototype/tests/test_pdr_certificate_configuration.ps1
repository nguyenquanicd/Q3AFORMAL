#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$ExecutablePath)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$prototype=Split-Path -Parent $PSScriptRoot
$exe=if($ExecutablePath){ (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$project=Join-Path $prototype 'pdr-pipeline.q3a'
$cases=foreach($item in @(
    @{id='first';depth='8';queries='1000'},@{id='second';depth='12';queries='2000'}
)) {
    $id=$item.id
    $cert=Join-Path $root "$id-certificate"
    $stderr=Join-Path $root "$id.stderr.txt"
    $raw=& $exe prove $project --engine pdr --property p_safe --max-depth $item.depth --max-queries $item.queries --evidence-dir $cert 2> $stderr
    $rc=$LASTEXITCODE
    $result=$raw | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $root "$id.json"),$raw)
    if ($rc -ne 0 -or $result.status -cne 'PROVEN') { throw "PDR proof failed: $raw" }
    $path=Join-Path $cert 'run-configuration.json'
    $original=[IO.File]::ReadAllText($path)
    $record=$original | ConvertFrom-Json
    $hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    if ($hash -cne $result.certificate.run_configuration_sha256 -or
        $record.model_sha256 -cne $result.certificate.model_sha256 -or
        $record.run_configuration.maximum_depth -ne [int]$item.depth -or
        $record.run_configuration.maximum_search_queries -ne [int]$item.queries -or
        ($record.run_configuration | ConvertTo-Json -Depth 12 -Compress) -cne
        ($result.run_configuration | ConvertTo-Json -Depth 12 -Compress)) {
        throw 'PDR proof directory lost its originating configuration.'
    }
    $check=@(& $exe verify-pdr $project --property p_safe --evidence-dir $cert)
    if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED' -or
        $check -cnotcontains "Q3A_PDR_RUN_CONFIGURATION VERIFIED sha256=$hash") {
        throw 'PDR proof and configuration did not reopen.'
    }
    $check | Set-Content -LiteralPath (Join-Path $root "$id.verify.txt") -Encoding utf8
    $changedSettings=$original | ConvertFrom-Json -AsHashtable
    $changedSettings.run_configuration.parameters['UNDECLARED_PARAMETER']='99'
    foreach ($change in @(
        @{body=$original.Replace('"property":"p_safe"','"property":"p_fake"'); label='model, goal or search limits'},
        @{body=$original.Replace($record.obligations[0].proof_sha256,('a'*64));label='checked certificate'},
        @{body=$original.Replace($record.run_configuration.sources[0].sha256,('9'*64));label='resolved source or parameter context'},
        @{body=($changedSettings | ConvertTo-Json -Depth 12 -Compress);label='resolved source or parameter context'}
    )) {
        if ($change.body -ceq $original) { throw 'Expected the provenance substitution to change the evidence bytes.' }
        try {
            [IO.File]::WriteAllText($path,$change.body)
            $reject=@(& $exe verify-pdr $project --property p_safe --evidence-dir $cert 2> $stderr)
            if ($LASTEXITCODE -ne 3 -or $reject -ccontains 'Q3A_PDR_CERTIFICATE VERIFIED' -or
                (Get-Content -LiteralPath $stderr -Raw) -notmatch [regex]::Escape($change.label)) {
                throw 'PDR accepted a mismatched originating run description.'
            }
        } finally {
            [IO.File]::WriteAllText($path,$original)
        }
    }
    $proofFiles=Get-ChildItem -LiteralPath $cert -File | Where-Object Name -CNE 'run-configuration.json' |
        Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
    [ordered]@{id=$id;provenance_sha256=$hash;model_sha256=$record.model_sha256;depth=$record.run_configuration.maximum_depth;
        query_limit=$record.run_configuration.maximum_search_queries;core_proof_files=$proofFiles}
}
if ($cases[0].provenance_sha256 -ceq $cases[1].provenance_sha256 -or
    $cases[0].core_proof_files.Count -ne 7 -or
    ($cases[0].core_proof_files -join ',') -cne ($cases[1].core_proof_files -join ',')) {
    throw 'Changing the search options did not retain independent proof identities.'
}
$legacy=Join-Path (Split-Path -Parent $prototype) 'evidence/release/pdr-certificate-only-configuration-baseline-2026-11-25/first-evidence'
$check=@(& $exe verify-pdr $project --property p_safe --evidence-dir $legacy)
if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') { throw 'A historical certificate failed to reopen.' }
[ordered]@{executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant();cases=$cases;
    rejected_substitutions=8;historical_certificate_verified=$true} |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: two certificate directories distinguish the originating PDR options, and eight provenance substitutions reject.'
