
#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$project = Join-Path $prototype 'pdr-cover.q3a'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$bundle = Join-Path $root 'witness'
$certificate = Join-Path $root 'unused-certificate'
$session = Join-Path $root 'debug-session.json'
$proofOptions = @('prove', $project, '--engine', 'pdr', '--property', 'p_hit', '--max-depth', '24',
    '--evidence-dir', $certificate, '--bundle-dir', $bundle)
$raw = @(& $exe @proofOptions 2> (Join-Path $root 'prove.stderr.txt'))
$exit = $LASTEXITCODE
$raw | Set-Content -LiteralPath (Join-Path $root 'prove.json')
if ($exit -ne 0 -or $raw.Count -ne 1 -or ($raw[0] | ConvertFrom-Json).status -cne 'COVERED') {
    throw 'Expected a replay-qualified cover witness for native debug'
}
$log = @(& $exe --verify-bundle $bundle --require-source-model)
if ($LASTEXITCODE -ne 0 -or $log -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
    $log -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') { throw 'Native debug source witness was not revalidated' }
$log | Set-Content -LiteralPath (Join-Path $root 'witness.revalidation.txt')
& $exe --qualify-native-gui $bundle $session
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $session -PathType Leaf)) {
    throw 'Native waveform and session command test did not pass'
}
$actual = Get-Content -LiteralPath $session -Raw | ConvertFrom-Json
$digest = (Get-FileHash -LiteralPath (Join-Path $bundle 'manifest.json')).Hash.ToLowerInvariant()
if ($actual.schema -ne 2 -or $actual.key -cne ('q3a-debug:'+$digest+':bounded') -or
    $actual.trace -cne 'trace.q3atrace' -or $actual.signals.Count -eq 0 -or !$actual.source.file -or
    $actual.markers.Count -ne 1 -or $actual.group -cne 'Window signals' -or
    $actual.groups.Count -eq 0) {
    throw 'Saved session lost its archive, trace, group, marker, selection or source identity'
}
& $exe --qualify-native-gui $bundle $session
if ($LASTEXITCODE -ne 0) { throw 'Could not replace an existing same-bundle session' }
$digestBefore = (Get-FileHash -LiteralPath $session).Hash
$foreign = Join-Path $root 'unrelated.json'
Set-Content -LiteralPath $foreign -Value '{"unrelated":"preserve me"}' -NoNewline
$foreignBefore = (Get-FileHash -LiteralPath $foreign).Hash
& $exe --qualify-native-gui $bundle $foreign 2> (Join-Path $root 'foreign.stderr.txt')
if ($LASTEXITCODE -eq 0 -or (Get-FileHash -LiteralPath $foreign).Hash -cne $foreignBefore) {
    throw 'An unrelated file was not preserved'
}
$lock = [IO.File]::Open($session, 'Open', 'Read', 'Read')
try {
    & $exe --qualify-native-gui $bundle $session 2> (Join-Path $root 'lock.stderr.txt')
    if ($LASTEXITCODE -eq 0) { throw 'An open session unexpectedly allowed replacement' }
} finally {
    $lock.Dispose()
}
if ((Get-FileHash -LiteralPath $session).Hash -cne $digestBefore -or @(Get-ChildItem -LiteralPath $root -Filter '*.q3a-*').Count) {
    throw 'Failed save changed the session or left a temporary file'
}
[ordered]@{
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    bundle_manifest_sha256 = $digest
    session_sha256 = (Get-FileHash -LiteralPath $session).Hash.ToLowerInvariant()
    checks = @('verified witness', 'native waveform events', 'two-way source navigation', 'transition and radix controls', 'signal search', 'marker and group persistence', 'viewport cache', 'session round-trip', 'same-bundle replacement', 'foreign and locked file preservation')
    gui_performance = 'NOT_MEASURED'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: native waveform events and session restore on a source-backed cover witness.'

