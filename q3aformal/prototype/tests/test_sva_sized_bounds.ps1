#requires -Version 7.0
param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-sva-sized-bounds-' + [guid]::NewGuid().ToString('N')))).FullName
$manifest = Join-Path $root 'fixture.q3a'
$source = Join-Path $root 'fixture.sv'
$stderr = Join-Path $root 'stderr.txt'
$header = 'module fixture(input logic clk);'

function Invoke-Proof($Arguments) {
    $stdout = @(& $exe prove $manifest @Arguments 2> $stderr)
    $code = $LASTEXITCODE
    if ($stdout.Count -ne 1) { throw "Expected one JSON response, got $($stdout.Count)." }
    $result = $stdout[0] | ConvertFrom-Json
    if ($result.exit_code -ne $code) { throw 'Process and JSON exit codes differ.' }
    return $result
}

try {
    @('Q3AFORMAL_PROJECT 2', 'top fixture', 'source systemverilog "fixture.sv"') |
        Set-Content -LiteralPath $manifest -Encoding utf8
    $valid = @(
        @{Name='p_zero'; Sequence="1'b1 ##1'd2 1'b1"; Frame=0},
        @{Name='p_range'; Sequence="1'b1 ##[1'd2:2'd1] 1'b1"; Frame=0},
        @{Name='p_repeat'; Sequence="1'b1[*2'd5] ##1 1'b1"; Frame=1},
        @{Name='p_positive'; Sequence="1'b1 ##4'sd2 1'b1"; Frame=2}
    )
    $lines = @($header)
    foreach ($entry in $valid) {
        $lines += "    $($entry.Name): cover property (@(posedge clk) $($entry.Sequence));"
    }
    $lines += "    p_safe: assert property (@(posedge clk) (1'b1 ##1'd2 1'b1) |=> 1'b1);"
    $lines += 'endmodule'
    $lines | Set-Content -LiteralPath $source -Encoding utf8

    foreach ($entry in $valid) {
        $property = $entry.Name
        foreach ($engine in 'bmc', 'pdr') {
            $bundle = Join-Path $root "$engine-$property"
            $limit = if ($engine -ceq 'bmc') { @('--frames', [string]$entry.Frame) }
                else { @('--max-depth', '4', '--evidence-dir', (Join-Path $root "certificate-$property")) }
            $argsForProof = @('--engine', $engine, '--property', $property) + $limit + @('--bundle-dir', $bundle)
            $result = Invoke-Proof $argsForProof
            if ($result.exit_code -ne 0 -or $result.status -cne 'COVERED') {
                throw "Expected $engine to reach $property at $($entry.Frame): $($result | ConvertTo-Json -Depth 6 -Compress). $(Get-Content -LiteralPath $stderr -Raw)"
            }
            $evidence = @(& $exe --verify-bundle $bundle)
            $expectedReplay = "candidate_frame=$($entry.Frame)$"
            if ($LASTEXITCODE -ne 0 -or $evidence -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
                $evidence -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
                !($evidence -cmatch $expectedReplay)) {
                throw "Could not replay $engine $property at expected frame $($entry.Frame)."
            }
            "PASS $engine $property COVERED frame=$($entry.Frame)"
        }
    }

    $inductionBundle = Join-Path $root 'induction-bundle'
    $result = Invoke-Proof @('--engine', 'induction', '--property', 'p_safe', '--k', '2',
        '--output-prefix', (Join-Path $root 'induction'), '--bundle-dir', $inductionBundle)
    if ($result.exit_code -ne 0 -or $result.status -cne 'PROVEN') { throw 'Expected a checked induction proof.' }
    $evidence = @(& $exe --verify-bundle $inductionBundle)
    if ($LASTEXITCODE -ne 0 -or $evidence -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $evidence -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        !($evidence -cmatch '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED id=base ') -or
        !($evidence -cmatch '^Q3A_BUNDLE_PROOF_CHECK ACCEPTED id=step ')) {
        throw 'The base and step obligations did not both revalidate.'
    }
    'PASS induction p_safe PROVEN with checked base and step'
    $invalid = @(
        @{Name='negative exact delay'; Sequence="1'b1 ##2'sb11 1'b1"; State='ELABORATION_ERROR'; Message='sequence delay must be nonnegative'},
        @{Name='negative upper delay'; Sequence="1'b1 ##[2'd0:2'sb11] 1'b1"; State='ELABORATION_ERROR'; Message='sequence delay upper bound must be nonnegative'},
        @{Name='negative repetition'; Sequence="1'b1[*2'sb11]"; State='ELABORATION_ERROR'; Message='repetition lower bound must be nonnegative'},
        @{Name='zero after truncation'; Sequence="1'b1[*1'd2]"; State='UNSUPPORTED'; Message='bounded repetition requires positive bounds'},
        @{Name='reversed range after truncation'; Sequence="1'b1 ##[2'd3:2'd4] 1'b1"; State='ELABORATION_ERROR'; Message='sequence delay range requires minimum <= maximum'}
    )
    $forbiddenBundle = Join-Path $root 'invalid-bundle'
    foreach ($entry in $invalid) {
        @($header, "    p_invalid: cover property (@(posedge clk) $($entry.Sequence));", 'endmodule') |
            Set-Content -LiteralPath $source -Encoding utf8
        $result = Invoke-Proof @('--engine', 'bmc', '--property', 'p_invalid', '--frames', '6',
            '--bundle-dir', $forbiddenBundle)
        $diagnostic = $result.diagnostics[0]
        if ($result.exit_code -ne 2 -or $result.status -cne $entry.State -or $result.diagnostics.Count -ne 1 -or
            $diagnostic.code -cne 'Q3A_LOWERING_ERROR' -or $diagnostic.location.file -cne 'fixture.sv' -or
            $diagnostic.location.line -ne 2 -or $diagnostic.location.column -lt 1 -or
            !$diagnostic.message.Contains($entry.Message, [StringComparison]::Ordinal) -or
            (Test-Path -LiteralPath $forbiddenBundle)) {
            throw "Unexpected rejection for $($entry.Name): $($result | ConvertTo-Json -Depth 6 -Compress)"
        }
        "PASS $($entry.Name) $($entry.State)"
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq $root) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
