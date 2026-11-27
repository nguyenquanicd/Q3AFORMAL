#requires -Version 7.0
param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$checker = Join-Path (Split-Path -Parent $exe) 'q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-shift-profile-' + [guid]::NewGuid().ToString('N')))).FullName
$stderr = Join-Path $root 'stderr.txt'
try {
    $manifest = Join-Path $prototype 'bmc-rtl-017-unsupported-shifts.q3a'
    $bundle = Join-Path $root 'rejected-bundle'
    $evidence = Join-Path $root 'rejected-certificate'
    $proof = Join-Path $root 'rejected-proof'
    foreach ($case in @(
        @{ Property='p_dynamic_shift'; Line=7; Message='compile-time constant shift distances' },
        @{ Property='p_negative_shift'; Line=11; Message='negative constant shift distances' }
    )) {
        foreach ($engine in 'bmc','induction','pdr') {
            $options = @(switch ($engine) {
                bmc { '--frames'; '1' }
                induction { '--k'; '1'; '--output-prefix'; $proof }
                pdr { '--max-depth'; '4'; '--evidence-dir'; $evidence }
            })
            $arguments = @($manifest, '--engine', $engine, '--property', $case.Property) +
                $options + @('--bundle-dir', $bundle)
            $stdout = @(& $exe prove @arguments 2> $stderr)
            $exitCode = $LASTEXITCODE
            if ($stdout.Count -ne 1) { throw 'Expected one product JSON summary.' }
            $result = $stdout[0] | ConvertFrom-Json
            $diagnostic = $result.diagnostics | Select-Object -First 1
            if ($exitCode -ne 2 -or $result.exit_code -ne 2 -or $result.status -cne 'UNSUPPORTED' -or
                $result.properties.Count -ne 1 -or $result.properties[0].status -cne 'UNSUPPORTED' -or
                $result.properties[0].name -cne $case.Property -or $result.diagnostics.Count -ne 1 -or
                $diagnostic.code -cne 'Q3A_BITBLAST_ERROR' -or $diagnostic.severity -cne 'error' -or
                $diagnostic.location.file -cne 'corpus/source-model-vectors/rtl-017-unsupported-shifts.sv' -or
                $diagnostic.location.line -ne $case.Line -or $diagnostic.location.column -ne 27 -or
                !$diagnostic.message.Contains($case.Message, [StringComparison]::Ordinal) -or
                $result.bundle_dir -or @(Get-ChildItem -LiteralPath $root | Where-Object Name -CLike 'rejected-*').Count) {
                throw "Unexpected $engine shift diagnostic. $stdout. $(Get-Content -LiteralPath $stderr -Raw)"
            }
            "PASS $engine $($case.Property) UNSUPPORTED at $($case.Line):27"
        }
    }

    $manifest = Join-Path $prototype 'bmc-rtl-017-shifts.q3a'
    foreach ($direction in 'left','right') {
        foreach ($amount in 0..7) {
            $property = "p_${direction}_$amount"
            $certificate = Join-Path $root $property
            $result = & $exe prove $manifest --engine pdr --property $property --max-depth 4 --evidence-dir $certificate 2> $stderr |
                ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $result.status -cne 'PROVEN') {
                throw "PDR failed for $property. $(Get-Content -LiteralPath $stderr -Raw)"
            }
            $verification = @(& $exe verify-pdr $manifest --property $property --evidence-dir $certificate)
            if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
                throw "PDR certificate did not revalidate for $property."
            }
            $model = (Get-Content -LiteralPath (Join-Path $certificate 'invariant.txt') -TotalCount 2)[1]
            foreach ($kind in 'initiation','consecution','safety') {
                $check = @(& $checker --check-drat (Join-Path $certificate "$kind.cnf") (
                    Join-Path $certificate "$kind.q3adrat") --model-sha256 $model --query-kind "pdr-$kind")
                if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
                    throw "Standalone checker did not accept $kind for $property."
                }
            }
            "PASS pdr $property three standalone DRAT checks"
        }
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq $root) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
