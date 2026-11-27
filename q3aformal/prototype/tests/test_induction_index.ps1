$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-induction-index-' + [Guid]::NewGuid()))).FullName
$project = Join-Path $prototype 'bmc-past.q3a'
$stderr = Join-Path $root 'errors.txt'

function Write-Manifest($Bundle, $Manifest) {
    $path = Join-Path $Bundle 'manifest.json'
    [IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath (Join-Path $Bundle 'manifest.sha256')
}

try {
    foreach ($case in @(
        @{ Id = 'base'; Depth = 2; Status = 'FAIL' },
        @{ Id = 'step'; Depth = 1; Status = 'NOT_1_INDUCTIVE' }
    )) {
        $bundle = Join-Path $root "$($case.Id)-bundle"
        $options = @('--output-prefix', (Join-Path $root $case.Id), '--bundle-dir', $bundle, '--trace-signal', 'a')
        $out = & $exe --prove-inductive $project --property p_past_a --k $case.Depth @options
        if ($LASTEXITCODE -ne 0 -or $out -cnotcontains "Q3A_INDUCTION_STATUS $($case.Status)") {
            throw "Unexpected induction outcome. $out"
        }
        $capture = Get-Content (Join-Path $bundle 'trace/capture.json') -Raw | ConvertFrom-Json
        if ($capture.requested -cnotcontains 'a' -or $capture.signals.name -cnotcontains 'a') {
            throw 'Induction trace lost its capture options.'
        }
        $path = Join-Path $bundle "properties/p_past_a/$($case.Id).trace.q3atrace"
        $json = & $exe trace window $path --first 0 --last 1 --signal a
        $window = $json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $window.property -cne 'p_past_a' -or
            $window.frame_count -ne 2 -or $window.candidate_frame -ne 1 -or
            $window.signals[0].name -cne 'a' -or $window.signals[0].changes[0][0] -ne 0) {
            throw 'Indexed trace window has the wrong witness identity or sample range.'
        }
        $expectedReplay = "Q3A_BUNDLE_INDUCTION_INDEXED_TRACE VERIFIED id=$($case.Id)"
        $reopened = & $exe --verify-bundle $bundle
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains $expectedReplay -or
            $reopened -cnotcontains 'Q3A_BUNDLE_WAVEFORM_CAPTURE VERIFIED') {
            throw 'Induction bundle did not revalidate its indexed witness and capture.'
        }

        $bundleManifest = Get-Content (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
        foreach ($record in ($bundleManifest.artifacts | Where-Object role -CEQ 'replay_validated_witness')) {
            Remove-Item -LiteralPath (Join-Path $bundle $record.path)
        }
        $bundleManifest.artifacts = @($bundleManifest.artifacts | Where-Object role -CNE 'replay_validated_witness')
        Write-Manifest $bundle $bundleManifest
        $reopened = & $exe --verify-bundle $bundle
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains $expectedReplay -or
            $reopened -cnotcontains "Q3A_BUNDLE_RESULT_STATUS $($case.Status)" -or
            $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw 'Indexed-only induction verification lost the recorded result.'
        }

        $binary = [IO.File]::ReadAllBytes($path)
        if ($binary[16] -ne 1) { throw 'Expected failure frame 1 in the binary header.' }
        $binary[16] = 0
        [IO.File]::WriteAllBytes($path, $binary)
        $indexRecord = $bundleManifest.artifacts |
            Where-Object { $_.role -ceq 'indexed_induction_witness' -and $_.path.EndsWith("/$($case.Id).trace.q3atrace") }
        $indexRecord.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Manifest $bundle $bundleManifest
        $null = & $exe --verify-bundle $bundle 2> $stderr
        if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'indexed induction witness replay failed') {
            throw 'Verifier accepted a rehashed witness with the wrong candidate frame.'
        }
    }
    'PASS: indexed-only induction base and step replay, trace windows, capture consistency, and altered candidate rejection.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), (Split-Path $root -Leaf))
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
