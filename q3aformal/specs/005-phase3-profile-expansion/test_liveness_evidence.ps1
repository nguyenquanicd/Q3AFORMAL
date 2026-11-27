#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
& "$PSScriptRoot/test_source_liveness.ps1" -ExecutablePath $exe -OutputDirectory "$root/source"
$demo = "$root/source/demo.q3a"
$forbid = "$root/source/forbid.q3a"
$reports = [ordered]@{}
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run($Name, $Command, $Project, $Evidence, $Expected, [int]$Code, [string[]]$Extra = @()) {
    $out = @(& $exe $Command $Project --request request --response response --evidence $Evidence @Extra 2> "$root/$Name.stderr.txt")
    $statusCode = $LASTEXITCODE
    $out | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $parsed = $out | ConvertFrom-Json
    if ($statusCode -ne $Code -or $parsed.exit_code -ne $Code -or $parsed.status -cne $Expected) {
        throw "$Name expected $Expected/$Code. $out $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $reports[$Name] = Hash "$root/$Name.json"
    $parsed
}

$cases = @(
    @{name='bad'; project=$demo; status='VIOLATION'; code=0; options=@()},
    @{name='valid'; project=$demo; status='NO_VIOLATION'; code=0; options=@('--justice','grant')},
    @{name='no-fair'; project=$forbid; status='NO_FAIR_EXECUTION'; code=1; options=@('--justice','grant')}
)
$hashes = [ordered]@{}
foreach ($case in $cases) {
    $file = "$root/$($case.name).q3live"
    $saved = Run "$($case.name)-saved" dev-check-liveness $case.project $file $case.status $case.code $case.options
    $opened = Run "$($case.name)-opened" dev-verify-liveness $case.project $file $case.status $case.code $case.options
    if ($saved.evidence_revalidated -or !$opened.evidence_revalidated -or
        $saved.evidence_sha256 -cne (Hash $file) -or $opened.evidence_sha256 -cne $saved.evidence_sha256 -or
        $opened.model_sha256 -cne $saved.model_sha256 -or
        ($opened.path | ConvertTo-Json -Compress) -cne ($saved.path | ConvertTo-Json -Compress)) {
        throw "The reopened evidence differs for $($case.name)."
    }
    $hashes[$case.name] = $opened.evidence_sha256
}

$badPath = "$root/bad.q3live"
$safePath = "$root/valid.q3live"
$null = Run same-destination dev-check-liveness $demo $badPath REJECTED 2
if ((Hash $badPath) -cne $hashes.bad) { throw 'The existing evidence was replaced.' }
$null = Run wrong-fairness dev-verify-liveness $demo $safePath REJECTED 2
$null = Run wrong-limits dev-verify-liveness $demo $badPath REJECTED 2 @('--max-edges','512')
$null = Run wrong-project dev-verify-liveness $forbid $badPath REJECTED 2

$changedRoot = (New-Item -ItemType Directory -Path "$root/relocated").FullName
Copy-Item -LiteralPath @($demo, "$root/source/demo.sv") -Destination $changedRoot
$relocated = "$changedRoot/demo.q3a"
$null = Run relocated dev-verify-liveness $relocated $badPath VIOLATION 0
$rtlPath = "$changedRoot/demo.sv"
(Get-Content -LiteralPath $rtlPath -Raw).Replace('active && grant', 'active || grant') |
    Set-Content -LiteralPath $rtlPath -Encoding utf8NoBOM
$null = Run changed-rtl dev-verify-liveness $relocated $badPath REJECTED 2

$invalid = "$root/invalid.q3live"
function Reject-Edit($Name, [string]$Text, [string[]]$Extra = @()) {
    Set-Content -LiteralPath $invalid -Value $Text -Encoding utf8NoBOM -NoNewline
    $null = Run $Name dev-verify-liveness $demo $invalid REJECTED 2 $Extra
}

$counterexample = Get-Content -LiteralPath $badPath -Raw
Reject-Edit trailing-data ($counterexample + "unexpected`n")
Reject-Edit truncated ($counterexample.Substring(0, $counterexample.LastIndexOf('END')))
Reject-Edit invalid-index ($counterexample -replace '(?m)(LASSO [0-9]+ [0-9]+\r?\n)[0-9]+', '${1}999999')
# Every vertex identifier remains in range. The finite path cannot close a pending loop.
Reject-Edit false-lasso ($counterexample -replace '(?ms)LASSO .*?END', "LASSO 0 2`n0`n0`nEND")
$certificate = Get-Content -LiteralPath $safePath -Raw
Reject-Edit false-exclusion ($certificate -replace '(?m)(EXCLUSION\r?\n)1 ', '${1}0 ') @('--justice','grant')
Reject-Edit wrong-build ($counterexample -replace '(?m)\A((?:[^\n]*\n){3})[a-f0-9]+', ('${1}' + ('0' * 64)))

$cancel = "$root/source/cancel.txt"
$cancelled = "$root/cancelled.q3live"
$null = Run cancelled dev-check-liveness $demo $cancelled CANCELLED 1 @('--cancel-file',$cancel)
if (Test-Path -LiteralPath $cancelled) { throw 'An interrupted run published evidence.' }

$longFolder = $root
1..3 | ForEach-Object { $longFolder = Join-Path $longFolder ("folder-" + ('x' * 42)); New-Item -Path $longFolder -ItemType Directory | Out-Null }
$longFile = Join-Path $longFolder ('evidence-' + ('y' * 50) + '.q3live')
if ($longFile.Length -le 260) { throw 'The long-path fixture did not exceed MAX_PATH.' }
$longSaved = Run long-path-save dev-check-liveness $demo $longFile VIOLATION 0
$longOpened = Run long-path-open dev-verify-liveness $demo $longFile VIOLATION 0
if (!$longOpened.evidence_revalidated -or $longSaved.evidence_sha256 -cne $longOpened.evidence_sha256) {
    throw 'Long-path reopen did not verify the saved artifact.'
}
if (@(Get-ChildItem -LiteralPath $root -Recurse -Directory -Filter '.q3a-live-*').Count) {
    throw 'Liveness publication left staging directories.'
}
[ordered]@{
    status = 'LIVENESS_ARCHIVE_QUALIFIED'
    executable_sha256 = Hash $exe
    artifact_sha256 = $hashes
    result_reports = $reports
    source_regression_sha256 = Hash "$root/source/qualification.json"
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: three archived outcomes, source relocation, tamper rejections and long-path reopening.'
