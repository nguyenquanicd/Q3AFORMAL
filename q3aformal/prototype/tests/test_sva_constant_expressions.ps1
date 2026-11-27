#requires -Version 7.0
param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$checker = Join-Path (Split-Path -Parent $exe) 'q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-sva-constant-expression-' + [guid]::NewGuid().ToString('N')))).FullName
$manifest = Join-Path $root 'fixture.q3a'
$source = Join-Path $root 'fixture.sv'
$stderr = Join-Path $root 'stderr.txt'
$header = 'module fixture #(parameter BASE = 2, parameter PICK = 1)(input logic clk, input logic a);'

function Prove($Arguments, $ExpectedStatus, $ExpectedExit) {
    $output = @(& $exe prove $manifest @Arguments 2> $stderr)
    $code = $LASTEXITCODE
    if ($output.Count -ne 1) { throw 'Expected one product JSON object.' }
    $result = $output[0] | ConvertFrom-Json
    if ($code -ne $ExpectedExit -or $result.exit_code -ne $code -or $result.status -cne $ExpectedStatus) {
        throw "Expected $ExpectedStatus ($ExpectedExit). $output. $(Get-Content -LiteralPath $stderr -Raw)"
    }
    return $result
}

function Reopen($Bundle, $ReplayLine) {
    $verification = @(& $exe --verify-bundle $Bundle --require-source-model)
    if ($LASTEXITCODE -ne 0 -or $verification -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $verification -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        ($ReplayLine -and !($verification -cmatch $ReplayLine))) {
        throw "Unexpected bundle verification for $Bundle. $verification"
    }
    return $verification
}

try {
    @('Q3AFORMAL_PROJECT 2', 'top fixture', 'source systemverilog "fixture.sv"') |
        Set-Content -LiteralPath $manifest -Encoding utf8
    @($header,
        '    localparam LATE = BASE + 1;',
        '    logic q;',
        '    always_ff @(posedge clk) begin q <= a; end',
        "    p_exact: cover property (@(posedge clk) 1'b1 ##(BASE + (2 - 1)) 1'b1);",
        "    p_grouped: cover property (@(posedge clk) 1'b1 ##BASE (1'b1));",
        "    p_range: cover property (@(posedge clk) 1'b1 ##[PICK ? BASE : LATE:LATE + 1] 1'b1);",
        "    p_repeat: cover property (@(posedge clk) 1'b1[*1 + BASE:LATE + 1] ##1 1'b1);",
        '    p_past: cover property (@(posedge clk) $past(1''b1, 1 + BASE));',
        "    p_safe: assert property (@(posedge clk) a |=> (1'b1 ##(BASE - BASE) q));",
        'endmodule') | Set-Content -LiteralPath $source -Encoding utf8

    foreach ($configuration in @(
        @{ Name = 'defaults'; Parameters = @(); Frames = @{ p_exact=3; p_grouped=2; p_range=2; p_repeat=3; p_past=3 } },
        @{ Name = 'override'; Parameters = @('--parameter','BASE','4','--parameter','PICK','0')
           Frames = @{ p_exact=5; p_grouped=4; p_range=5; p_repeat=5; p_past=5 } }
    )) {
        foreach ($property in 'p_exact','p_grouped','p_range','p_repeat','p_past') {
            $frame = $configuration.Frames[$property]
            foreach ($engine in 'bmc','pdr') {
                $id = "$($configuration.Name)-$engine-$property"
                $bundle = Join-Path $root "$id-bundle"
                $certificate = Join-Path $root "$id-certificate"
                $limits = if ($engine -ceq 'bmc') { @('--frames', [string]$frame) }
                    else { @('--max-depth', '8', '--evidence-dir', $certificate) }
                $arguments = $configuration.Parameters + @('--engine', $engine, '--property', $property) +
                    $limits + @('--bundle-dir', $bundle)
                $null = Prove $arguments 'COVERED' 0
                $null = Reopen $bundle "candidate_frame=$frame$"
                "PASS $id COVERED frame=$frame"
            }
        }

        $induction = Join-Path $root "$($configuration.Name)-induction"
        $arguments = $configuration.Parameters + @('--engine','induction','--property','p_safe','--k','2',
            '--output-prefix', (Join-Path $root "$($configuration.Name)-proof"), '--bundle-dir', $induction)
        $null = Prove $arguments 'PROVEN' 0
        $verify = @(Reopen $induction '')
        foreach ($kind in 'base','step') {
            if (!($verify -cmatch "^Q3A_BUNDLE_PROOF_CHECK ACCEPTED id=$kind ")) {
                throw "Missing checked induction obligation $kind."
            }
        }

        $certificate = Join-Path $root "$($configuration.Name)-pdr-certificate"
        $arguments = $configuration.Parameters + @('--engine','pdr','--property','p_safe','--max-depth','8',
            '--evidence-dir', $certificate)
        $null = Prove $arguments 'PROVEN' 0
        $arguments = $configuration.Parameters + @('--property','p_safe','--evidence-dir',$certificate)
        $checked = @(& $exe verify-pdr $manifest @arguments)
        if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw "Could not revalidate PDR certificate. $checked"
        }
        $modelHash = (Get-Content -LiteralPath (Join-Path $certificate 'invariant.txt') -TotalCount 2)[1]
        foreach ($kind in 'initiation','consecution','safety') {
            $checked = @(& $checker --check-drat (Join-Path $certificate "$kind.cnf") (
                Join-Path $certificate "$kind.q3adrat") --model-sha256 $modelHash --query-kind "pdr-$kind")
            if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') {
                throw "Standalone checker rejected $kind for $($configuration.Name)."
            }
        }
        "PASS $($configuration.Name) checked two induction and three PDR obligations"
    }

    $invalid = @(
        @{ Id='runtime delay'; Expression="1'b1 ##(a + 1) 1'b1"; Status='ELABORATION_ERROR'; Message="unresolved expression name 'a'" },
        @{ Id='runtime repetition'; Expression="1'b1[*a + 1]"; Status='ELABORATION_ERROR'; Message="unresolved expression name 'a'" },
        @{ Id='negative folded delay'; Expression="1'b1 ##(BASE - 3) 1'b1"; Status='ELABORATION_ERROR'; Message='sequence delay must be nonnegative' },
        @{ Id='zero folded repetition'; Expression="1'b1[*BASE - 2]"; Status='UNSUPPORTED'; Message='bounded repetition requires positive bounds' },
        @{ Id='reversed folded range'; Expression="1'b1 ##[BASE + 2:BASE + 1] 1'b1"; Status='ELABORATION_ERROR'; Message='sequence delay range requires minimum <= maximum' }
    )
    $rejected = Join-Path $root 'rejected'
    foreach ($case in $invalid) {
        @($header, "    p_bad: cover property (@(posedge clk) $($case.Expression));", 'endmodule') |
            Set-Content -LiteralPath $source -Encoding utf8
        $result = Prove @('--engine','bmc','--property','p_bad','--frames','6','--bundle-dir',$rejected) $case.Status 2
        $diagnostic = $result.diagnostics[0]
        if ($result.diagnostics.Count -ne 1 -or $diagnostic.code -cne 'Q3A_LOWERING_ERROR' -or
            $diagnostic.location.file -cne 'fixture.sv' -or $diagnostic.location.line -ne 2 -or
            !$diagnostic.message.Contains($case.Message, [StringComparison]::Ordinal) -or
            (Test-Path -LiteralPath $rejected)) {
            throw "Incorrect typed diagnostic for $($case.Id): $($result | ConvertTo-Json -Depth 6 -Compress)"
        }
        "PASS $($case.Id) $($case.Status)"
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq $root) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
