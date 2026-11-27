param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-preprocess-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.log'
$manifest = Join-Path $root 'fixture.q3a'
$tick = [char]96

function Check-Prove([string]$Project, [string]$Property, [string]$Status, [int]$Code,
                     [string[]]$Options = @()) {
    $line = & $exe prove $Project --engine bmc --property $Property --frames 1 @Options 2> $stderr
    $actual = $LASTEXITCODE
    $result = $line | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Status ($Code), got $line. $(Get-Content -LiteralPath $stderr -Raw)"
    }
    $result
}

try {
    @'
@define RESET_MARKER
@undef RESET_MARKER
@ifndef RESET_MARKER
    @ifdef UNUSED
        @UNDEFINED_IN_INACTIVE_BRANCH
    @elsif FEATURE
        @define LOCAL_ON @FLAG_VALUE
    @else
        @define LOCAL_ON 1'b0
    @endif
@endif
module macro_top(input logic clk);
    macro_leaf leaf(.clk(clk));
endmodule
'@.Replace('@', [string]$tick) | Set-Content (Join-Path $root 'design.sv')
    @'
module macro_leaf(input logic clk);
    logic value_signal;
    assign value_signal = $LOCAL_ON;
    p_on: assert property (@(posedge clk) value_signal);
endmodule
'@.Replace('$LOCAL_ON', "$($tick)LOCAL_ON") | Set-Content (Join-Path $root 'checks.sv')
    $header = @('Q3AFORMAL_PROJECT 2', 'top macro_top')
    $sources = @('source systemverilog "design.sv"', 'property_source systemverilog "checks.sv"')
    $enabled = @('define FEATURE', "define FLAG_VALUE (1'b1)")
    ($header + $enabled + $sources) | Set-Content -LiteralPath $manifest
    $model = @(& $exe --lower-project $manifest) -join [char]10
    if ($LASTEXITCODE -ne 0) { throw 'Enabled macro project did not lower.' }
    ($header + @($enabled[1], $enabled[0]) + $sources) | Set-Content -LiteralPath $manifest
    $reordered = @(& $exe --lower-project $manifest) -join [char]10
    if ($LASTEXITCODE -ne 0 -or $model -cne $reordered) {
        throw 'Unique manifest definitions should identify the same macro environment regardless of order.'
    }
    $bundle = Join-Path $root 'macro-proof'
    $null = Check-Prove $manifest 'leaf.p_on' 'BOUNDED_PASS' 1 @('--bundle-dir', $bundle)
    $bundleManifestPath = Join-Path $bundle 'manifest.json'
    $bundleManifest = Get-Content -LiteralPath $bundleManifestPath -Raw | ConvertFrom-Json
    if ($bundleManifest.project.macros.FLAG_VALUE -cne "(1'b1)" -or
        $bundleManifest.project.macros.FEATURE -cne '') {
        throw 'The bundle did not capture the macro environment.'
    }
    $reopened = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Macro bundle did not recompile from archived inputs: $reopened $(Get-Content $stderr -Raw)"
    }
    $bundleManifest.project.macros.FLAG_VALUE = "(1'b0)"
    [IO.File]::WriteAllText($bundleManifestPath, ($bundleManifest | ConvertTo-Json -Depth 100))
    (Get-FileHash $bundleManifestPath).Hash.ToLowerInvariant() |
        Set-Content (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
    $reopened = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $reopened -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'source-set identity does not match') {
        throw 'Modified macro metadata was accepted after the manifest digest was refreshed.'
    }
    ($header + @('define FEATURE', "define FLAG_VALUE (1'b0)") + $sources) |
        Set-Content -LiteralPath $manifest
    $null = Check-Prove $manifest 'leaf.p_on' 'BOUNDED_FAIL' 0
    $different = @(& $exe --lower-project $manifest) -join [char]10
    if ($LASTEXITCODE -ne 0 -or
        ($model | ConvertFrom-Json).input_sha256 -ceq ($different | ConvertFrom-Json).input_sha256) {
        throw 'Changing a manifest definition failed to change model identity.'
    }
    ($header + $sources) | Set-Content -LiteralPath $manifest
    $null = Check-Prove $manifest 'leaf.p_on' 'BOUNDED_FAIL' 0
    'PASS: ordered source preprocessing, conditional branches, nested macros, manifest identity, and bundle reopening.'

    $functionProject = Join-Path $root 'functions.q3a'
    @('Q3AFORMAL_PROJECT 2', 'top functions', 'source systemverilog "functions.sv"') |
        Set-Content $functionProject
    $headerFile = Join-Path $root 'checks.svh'
    @'
%define SAME(A, B) ((A) == (B))
%define ID(X) (X)
%define SELECT(X, Y = 2'b10) %SAME(X,Y)
%define EMPTY() 1'b1
'@.Replace('%', [string]$tick) | Set-Content $headerFile
    @'
%include "checks.svh"
module functions(input logic clk);
    p_ok: assert property (@(posedge clk) %SELECT({1'b1,1'b0}) && %EMPTY() && %ID(%ID(1'b1)));
    p_empty: assert property (@(posedge clk) %SELECT({1'b1,1'b0},));
    p_override: assert property (@(posedge clk) %SELECT({1'b1,1'b0}, 2'b01));
endmodule
'@.Replace('%', [string]$tick) | Set-Content (Join-Path $root 'functions.sv')
    $null = Check-Prove $functionProject 'p_ok' 'BOUNDED_PASS' 1
    $null = Check-Prove $functionProject 'p_empty' 'BOUNDED_PASS' 1
    $functionBundle = Join-Path $root 'function-witness'
    $null = Check-Prove $functionProject 'p_override' 'BOUNDED_FAIL' 0 @('--bundle-dir', $functionBundle)
    $certificate = Join-Path $root 'function-certificate'
    $proved = & $exe prove $functionProject --engine pdr --property p_ok --evidence-dir $certificate 2> $stderr
    if ($LASTEXITCODE -ne 0 -or ($proved | ConvertFrom-Json).status -cne 'PROVEN') {
        throw "PDR did not prove the expanded property: $proved. $(Get-Content $stderr -Raw)"
    }
    $verified = & $exe verify-pdr $functionProject --property p_ok --evidence-dir $certificate 2> $stderr
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "The DRAT certificate did not revalidate: $verified. $(Get-Content $stderr -Raw)"
    }
    foreach ($obligation in 'initiation', 'consecution', 'safety') {
        if (!(Test-Path -LiteralPath (Join-Path $certificate "$obligation.q3adrat") -PathType Leaf)) {
            throw "Missing DRAT evidence for $obligation."
        }
    }
    "Changed live header" | Set-Content -LiteralPath $headerFile
    $reopened = & $exe --verify-bundle $functionBundle 2> $stderr
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The macro witness did not reopen from the archived header: $reopened."
    }
    'PASS: function macros, defaults, nested arguments, exact override, DRAT revalidation, and archived-header replay.'

    $continuedSource = @'
%ifdef SKIP
%define UNREACHABLE \
    %endif
not active tokens
%endif
%define BITS \
    {1'b1, \
     1'b0}
%define MATCH(value, \
             expected = 2'b10) \
    ((value) == \
     (expected))
module functions(input logic clk);
    p_match: assert property (@(posedge clk) %MATCH(%BITS));
    p_false: assert property (@(posedge clk) %MATCH(%BITS,2'b01));
endmodule
'@.Replace('%', [string]$tick) -replace '\r\n', "`n"
    foreach ($newline in "`n", "`r`n") {
        [IO.File]::WriteAllText((Join-Path $root 'functions.sv'), $continuedSource.Replace("`n", $newline))
        $null = Check-Prove $functionProject 'p_match' 'BOUNDED_PASS' 1
        $null = Check-Prove $functionProject 'p_false' 'BOUNDED_FAIL' 0
    }
    $continuedProof = Join-Path $root 'continued-proof'
    $expanded = & $exe prove $functionProject --engine pdr --property p_match --evidence-dir $continuedProof 2> $stderr
    if ($LASTEXITCODE -ne 0 -or ($expanded | ConvertFrom-Json).status -cne 'PROVEN') {
        throw "PDR failed on the continued definition: $expanded. $(Get-Content $stderr -Raw)"
    }
    $revalidated = & $exe verify-pdr $functionProject --property p_match --evidence-dir $continuedProof 2> $stderr
    if ($LASTEXITCODE -ne 0 -or $revalidated -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "The continued-definition certificate did not revalidate: $revalidated."
    }
    'PASS: LF and CRLF macro continuation across parameters and replacement tokens, skipped definitions, and PDR certificate revalidation.'

    $pasteProject = Join-Path $root 'paste.q3a'
    @('Q3AFORMAL_PROJECT 2', 'top pasted', 'source systemverilog "paste.sv"') | Set-Content $pasteProject
    $pasteHeader = Join-Path $root 'paste.svh'
    @'
%define INDEX 1
%define DATA_1 1'b1
%define READ_PORT(n) port%%_%%n
%define CONST_BY_NAME(prefix, n) %prefix%%n
%define LITERAL(width, suffix) width%%suffix
%define FIRST_PORT port%%_0
'@.Replace('%', [string]$tick) | Set-Content -LiteralPath $pasteHeader
    @'
%include "paste.svh"
module pasted(input logic clk, input logic port_0, input logic port_1);
    p_literal: assert property (@(posedge clk) %LITERAL(1,'b1) == %CONST_BY_NAME(DATA_,%INDEX));
    p_port: assert property (@(posedge clk) %READ_PORT(%INDEX) == port_1);
    p_wrong: assert property (@(posedge clk) %FIRST_PORT == %READ_PORT(%INDEX));
endmodule
'@.Replace('%', [string]$tick) | Set-Content (Join-Path $root 'paste.sv')
    $null = Check-Prove $pasteProject 'p_literal' 'BOUNDED_PASS' 1
    $null = Check-Prove $pasteProject 'p_port' 'BOUNDED_PASS' 1
    $pasteBundle = Join-Path $root 'paste-witness'
    $null = Check-Prove $pasteProject 'p_wrong' 'BOUNDED_FAIL' 0 @('--bundle-dir', $pasteBundle)
    $pasteProof = Join-Path $root 'paste-proof'
    $proved = & $exe prove $pasteProject --engine pdr --property p_port --evidence-dir $pasteProof 2>$stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $proved.status -cne 'PROVEN') {
        throw "PDR did not prove the pasted port reference. $(Get-Content $stderr -Raw)"
    }
    $verified = @(& $exe verify-pdr $pasteProject --property p_port --evidence-dir $pasteProof 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "The pasted port certificate did not revalidate. $(Get-Content $stderr -Raw)"
    }
    'Changed live header' | Set-Content -LiteralPath $pasteHeader
    $verified = @(& $exe --verify-bundle $pasteBundle 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Token-paste witness did not reopen from archived source. $(Get-Content $stderr -Raw)"
    }
    'PASS: token paste for port names, nested macro names, based literals, checked DRAT and archived replay.'

    $invalidProject = Join-Path $root 'invalid.q3a'
    @('Q3AFORMAL_PROJECT 2', 'top bad', 'source systemverilog "invalid.sv"') | Set-Content $invalidProject
    foreach ($case in @(
        @{ Body = '1%%alphabetic'; Error = 'macro token paste did not form a single token' },
        @{ Body = 'value%%'; Error = 'macro token paste requires operands on both sides' },
        @{ Body = '%%value'; Error = 'macro token paste requires operands on both sides' }
    )) {
        @(('%define BROKEN ' + $case.Body), '%BROKEN', 'module bad(); endmodule') |
            ForEach-Object { $_.Replace('%', [string]$tick) } | Set-Content (Join-Path $root 'invalid.sv')
        $diagnostic = (Check-Prove $invalidProject 'p' 'SETUP_ERROR' 2).diagnostics[0]
        if ($diagnostic.location.file -cne 'invalid.sv' -or $diagnostic.location.line -ne 2 -or
            $diagnostic.message -cnotmatch $case.Error) {
            throw "Invalid paste did not report its invocation position. $($diagnostic.message)"
        }
    }
    foreach ($case in @(
        @{ First = "$($tick)timescale 1ns/1ps"; Code = 2; Status = 'UNSUPPORTED'; Message = 'timescale' },
        @{ First = "$($tick)define FUN(x,x) x"; Code = 2; Status = 'SETUP_ERROR'; Message = 'duplicate macro formal' },
        @{ First = "$($tick)include " + '"missing.svh"'; Code = 2; Status = 'SETUP_ERROR'; Message = 'include file not found' },
        @{ First = "$($tick)ifdef FLAG"; Code = 2; Status = 'SETUP_ERROR'; Message = 'unterminated conditional' },
        @{ First = "$($tick)loop"; Code = 2; Status = 'SETUP_ERROR'; Message = 'undefined macro' }
    )) {
        @($case.First, 'module bad(); endmodule') | Set-Content (Join-Path $root 'invalid.sv')
        $diagnostic = (Check-Prove $invalidProject 'p' $case.Status $case.Code).diagnostics[0]
        if ($diagnostic.location.file -cne 'invalid.sv' -or $diagnostic.location.line -ne 1 -or
            $diagnostic.message -notmatch $case.Message) {
            throw "Incorrect preprocessing diagnostic: $($diagnostic.message)"
        }
    }
    @("$($tick)define BROKEN 1'b0 \ ", 'module bad(); endmodule') |
        Set-Content (Join-Path $root 'invalid.sv')
    $badContinuation = (Check-Prove $invalidProject 'p' 'SETUP_ERROR' 2).diagnostics[0]
    if ($badContinuation.location.line -ne 1 -or $badContinuation.message -notmatch 'immediately before the newline') {
        throw 'Malformed continuation did not produce a source-located setup error.'
    }
    @("$($tick)define LOOP $($tick)LOOP", "$($tick)LOOP", 'module bad(); endmodule') |
        Set-Content (Join-Path $root 'invalid.sv')
    $recursive = (Check-Prove $invalidProject 'p' 'SETUP_ERROR' 2).diagnostics[0]
    if ($recursive.location.line -ne 2 -or $recursive.message -notmatch 'recursive or excessively nested macro') {
        throw 'Recursive expansion was not rejected at the invocation.'
    }
    foreach ($case in @(
        @{ Actual = ''; Message = 'parenthesized argument list' },
        @{ Actual = '()'; Message = 'missing macro argument' },
        @{ Actual = '(1,2)'; Message = 'too many macro arguments' },
        @{ Actual = '({1,2])'; Message = 'mismatched delimiter' },
        @{ Actual = '(1'; Message = 'unterminated macro argument list' }
    )) {
        @("$($tick)define FUN(x) x", "$($tick)FUN$($case.Actual)", 'module bad(); endmodule') |
            Set-Content (Join-Path $root 'invalid.sv')
        $diagnostic = (Check-Prove $invalidProject 'p' 'SETUP_ERROR' 2).diagnostics[0]
        if ($diagnostic.location.line -ne 2 -or $diagnostic.message -notmatch $case.Message) {
            throw "Incorrect macro invocation diagnostic: $($diagnostic.message)"
        }
    }
    'PASS: source-located rejection of undefined and recursive macros, unbalanced conditionals and unsupported directives.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-preprocess-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
