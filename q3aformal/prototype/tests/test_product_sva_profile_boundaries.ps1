#requires -Version 7.0
param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-sva-profile-' + [guid]::NewGuid().ToString('N')))).FullName
$manifest = Join-Path $root 'profile.q3a'
$source = Join-Path $root 'profile.sv'
$standalone = Join-Path $root 'checks.sv'
$stderr = Join-Path $root 'stderr.txt'
$mark = '__DIAG__'
$prefix = '    p_check: assert property ('
$cases = @(
    @{Name = 'goto repetition'; Body = '@(posedge clk) a[0][__DIAG__->1] ##1 a[1]'; Message = 'goto and nonconsecutive repetition'},
    @{Name = 'nonconsecutive repetition'; Body = '@(posedge clk) a[0][__DIAG__=1:2] ##1 a[1]'; Message = 'goto and nonconsecutive repetition'},
    @{Name = 'star repetition'; Body = '@(posedge clk) a[0][*__DIAG__] ##1 a[1]'; Message = 'unbounded repetition'},
    @{Name = 'plus repetition'; Body = '@(posedge clk) a[0][__DIAG__+] ##1 a[1]'; Message = 'unbounded repetition'},
    @{Name = 'unbounded upper repetition'; Body = '@(posedge clk) a[0][*1:__DIAG__$]'; Message = 'unbounded sequence or repetition bounds'},
    @{Name = 'zero-count repetition'; Body = '@(posedge clk) a[0][*__DIAG__0]'; Message = 'must be positive'},
    @{Name = 'zero-minimum repetition'; Body = '@(posedge clk) a[0][*__DIAG__0:2]'; Message = 'must be positive'},
    @{Name = 'star delay'; Body = '@(posedge clk) a[0] ##__DIAG__[*] a[1]'; Message = 'unbounded sequence delay'},
    @{Name = 'plus delay'; Body = '@(posedge clk) a[0] ##__DIAG__[+] a[1]'; Message = 'unbounded sequence delay'},
    @{Name = 'unbounded upper delay'; Body = '@(posedge clk) a[0] ##[1:__DIAG__$] a[1]'; Message = 'unbounded sequence or repetition bounds'},
    @{Name = 's_eventually'; Body = '@(posedge clk) __DIAG__s_eventually a[0]'; Message = "temporal operator 's_eventually'"},
    @{Name = 'until'; Body = '@(posedge clk) a[0] __DIAG__until a[1]'; Message = "temporal operator 'until'"},
    @{Name = 'throughout'; Body = '@(posedge clk) a[0] __DIAG__throughout a[1]'; Message = "temporal operator 'throughout'"},
    @{Name = 'first_match'; Body = '@(posedge clk) __DIAG__first_match(a[0] ##1 a[1])'; Message = "temporal operator 'first_match'"},
    @{Name = 'gated past'; Body = '@(posedge clk) $past(a[0], 1__DIAG__, a[1])'; Message = '$past gating and alternate clocks'},
    @{Name = 'alternate past clock'; Body = '@(posedge clk) $past(a[0], 1__DIAG__, a[1], @(posedge other))'; Message = '$past gating and alternate clocks'},
    @{Name = 'event list'; Body = '@(posedge clk __DIAG__or posedge other) a[0]'; Message = 'event lists and event qualifiers'},
    @{Name = 'event qualifier'; Body = '@(posedge clk __DIAG__iff a[0]) a[1]'; Message = 'event lists and event qualifiers'},
    @{Name = 'event missing close'; Body = '@(posedge clk __DIAG__a[0]'; Status = 'SETUP_ERROR'; Message = "expected ')'"},
    @{Name = 'missing operand'; Body = '@(posedge clk) a[0] |=> __DIAG__'; Status = 'SETUP_ERROR'; Message = 'expected an expression operand'}
)
$engines = @{
    bmc = @('--frames', '2', '--bundle-dir', (Join-Path $root 'bmc-bundle'))
    induction = @('--k', '2', '--output-prefix', (Join-Path $root 'induction'),
        '--bundle-dir', (Join-Path $root 'induction-bundle'))
    pdr = @('--max-depth', '4', '--evidence-dir', (Join-Path $root 'certificate'))
}
try {
    $header = 'module profile(input logic clk, input logic other, input logic [1:0] a);'
    $manifestLines = @('Q3AFORMAL_PROJECT 2', 'top profile', 'source systemverilog "profile.sv"')
    foreach ($mode in 'inline', 'standalone') {
        $sourceLine = 2
        $sourceFile = 'profile.sv'
        $project = $manifestLines
        if ($mode -ceq 'standalone') {
            $sourceLine = 1
            $sourceFile = 'checks.sv'
            $project += 'property_source systemverilog "checks.sv"'
            @($header, 'endmodule') | Set-Content -LiteralPath $source -Encoding utf8
        }
        $project | Set-Content -LiteralPath $manifest -Encoding utf8
        foreach ($case in $cases) {
            $line = $prefix + $case.Body + ');'
            $column = $line.IndexOf($mark, [StringComparison]::Ordinal) + 1
            if (!$column) { throw "Missing diagnostic marker for $($case.Name)." }
            $line = $line.Replace($mark, '')
            if ($mode -ceq 'inline') {
                @($header, $line, 'endmodule') | Set-Content -LiteralPath $source -Encoding utf8
            } else {
                $line | Set-Content -LiteralPath $standalone -Encoding utf8
            }
            $expectedStatus = $case.Status ?? 'UNSUPPORTED'
            $location = "${sourceFile}:${sourceLine}:${column}"
            foreach ($engine in 'bmc','induction','pdr') {
                $arguments = @($manifest, '--engine', $engine, '--property', 'p_check') + $engines[$engine]
                $stdout = @(& $exe prove @arguments 2> $stderr)
                $code = $LASTEXITCODE
                if ($stdout.Count -ne 1) { throw "Expected one JSON line for $engine / $($case.Name)." }
                $result = $stdout[0] | ConvertFrom-Json
                $diagnostic = $result.diagnostics[0]
                if ($code -ne 2 -or $result.schema_version -ne 1 -or $result.exit_code -ne 2 -or
                    $result.status -cne $expectedStatus -or $result.properties.Count -ne 1 -or
                    $result.properties[0].name -cne 'p_check' -or $result.properties[0].status -cne $expectedStatus -or
                    $result.diagnostics.Count -ne 1 -or $diagnostic.code -cne 'Q3A_PARSE_ERROR' -or
                    $diagnostic.severity -cne 'error' -or $diagnostic.location.file -cne $sourceFile -or
                    $diagnostic.location.line -ne $sourceLine -or $diagnostic.location.column -ne $column -or
                    !$diagnostic.message.Contains($case.Message, [StringComparison]::Ordinal)) {
                    throw "Unexpected $engine diagnostic for $($case.Name), expected $expectedStatus at $location. $($stdout[0])"
                }
            }
            "PASS $mode $($case.Name) $expectedStatus $location (three engines)"
        }
    }
    if (@(Get-ChildItem -LiteralPath $root | Where-Object Name -cnotin 'profile.q3a','profile.sv','checks.sv','stderr.txt').Count) {
        throw 'Rejected input created a proof, witness, or bundle.'
    }

    $manifestLines | Set-Content -LiteralPath $manifest -Encoding utf8
    @($header, ($prefix + '@(posedge clk) (a[+0] == a[0]) ##[0:1] (a[1] == a[1]));'), 'endmodule') |
        Set-Content -LiteralPath $source -Encoding utf8
    $stdout = @(& $exe prove $manifest --engine bmc --property p_check --frames 2 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or ($stdout[0] | ConvertFrom-Json).status -cne 'BOUNDED_PASS') {
        throw "The supported positive packed index and finite delay failed: $($stdout[0])"
    }
    "PASS supported unary plus index and finite delay; $(2 * $cases.Count * $engines.Count) rejection decisions."
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq $root) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
