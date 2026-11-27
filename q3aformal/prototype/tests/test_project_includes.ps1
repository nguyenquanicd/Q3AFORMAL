param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-includes-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.log'
$manifest = Join-Path $root 'fixture.q3a'
$tick = [char]96

function Prove([string]$Status, [int]$Code, [string[]]$Options = @()) {
    $json = & $exe prove $manifest --engine bmc --property p_flag --frames 0 @Options 2> $stderr
    $actual = $LASTEXITCODE
    $result = $json | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Status ($Code), got $json. $(Get-Content $stderr -Raw)"
    }
    $result
}

try {
    New-Item -ItemType Directory -Path (Join-Path $root 'option-a/inner'), (Join-Path $root 'option-b') -Force | Out-Null
    $input = Join-Path $root 'input.sv'
    $source = @(
        "$($tick)include " + '"config.svh"'
        'module fixture(input logic clk);'
        "$($tick)include " + '"checks.svh"'
        'endmodule'
    )
    $source | Set-Content $input
    @(
        "$($tick)ifndef CONFIG_DEFINED"
        "$($tick)define CONFIG_DEFINED"
        "$($tick)include " + '"config.svh"'
        "$($tick)include " + '"inner/value.svh"'
        "$($tick)endif"
    ) | Set-Content (Join-Path $root 'option-a/config.svh')
    "$($tick)define FLAG 1'b0" | Set-Content (Join-Path $root 'option-a/inner/value.svh')
    "$($tick)define FLAG 1'b1" | Set-Content (Join-Path $root 'option-b/config.svh')
    "p_flag: assert property (@(posedge clk) $($tick)FLAG);" | Set-Content (Join-Path $root 'option-a/checks.svh')
    $head = @('Q3AFORMAL_PROJECT 2', 'top fixture', 'source systemverilog "input.sv"')
    $dirs = @('include_dir "option-a"', 'include_dir "option-b"')
    ($head + $dirs) | Set-Content $manifest

    $parsed = @(& $exe --parse-project $manifest 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $parsed -cnotcontains 'Q3A_SYNTAX_OK "input.sv" modules=1' -or
        !($parsed -cmatch '^module fixture .* property_checks=1 ')) {
        throw "Project parser did not read the resolved header and macros. $(Get-Content $stderr -Raw)"
    }
    $checks = Join-Path $root 'option-a/checks.svh'
    $validChecks = Get-Content -LiteralPath $checks
    'p_flag: assert property (@(posedge clk) );' | Set-Content -LiteralPath $checks
    $badParse = @(& $exe --parse-project $manifest 2>$stderr)
    if ($LASTEXITCODE -ne 1 -or $badParse.Count -ne 0 -or
        (Get-Content $stderr -Raw) -cnotmatch 'option-a/checks\.svh:1:') {
        throw 'Project parser lost the syntax error location in the included header.'
    }
    $validChecks | Set-Content -LiteralPath $checks

    $bundle = Join-Path $root 'witness'
    $null = Prove 'BOUNDED_FAIL' 0 @('--bundle-dir', $bundle)
    $saved = Join-Path $bundle 'manifest.json'
    $record = Get-Content $saved -Raw | ConvertFrom-Json
    if ($parsed[0] -cnotmatch ("input_sha256=" + $record.profile.source_set_sha256 + ' ')) {
        throw 'Project parser and proof bundle used different source identities.'
    }
    if (($record.project.include_dirs -join ',') -cne 'option-a,option-b' -or
        ($record.project.headers.path -join ',') -cne 'option-a/config.svh,option-a/inner/value.svh,option-a/checks.svh') {
        throw 'The bundle did not record the deterministic active include order.'
    }
    $resolvedHeader = Join-Path $root 'option-a/inner/value.svh'
    $originalHeaderHash = (Get-FileHash -LiteralPath $resolvedHeader).Hash
    foreach ($export in '--vcd', '--html') {
        $null = Prove 'SETUP_ERROR' 2 @($export, $resolvedHeader)
        if ((Get-Content $stderr -Raw) -notmatch 'output path must not overwrite an RTL source file' -or
            (Get-FileHash -LiteralPath $resolvedHeader).Hash -cne $originalHeaderHash) {
            throw "Trace export overwrote an input header: $export."
        }
    }
    ($head + @($dirs[1], $dirs[0])) | Set-Content $manifest
    $null = Prove 'BOUNDED_PASS' 1
    ($head + $dirs) | Set-Content $manifest
    "$($tick)define FLAG 1'b1" | Set-Content (Join-Path $root 'option-a/inner/value.svh')
    $null = Prove 'BOUNDED_PASS' 1
    $updated = & $exe --lower-project $manifest | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $updated.input_sha256 -ceq $record.profile.source_set_sha256) {
        throw 'Changing the resolved header did not change source identity.'
    }

    $reopened = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "The old witness did not reopen from the archived headers: $reopened $(Get-Content $stderr -Raw)"
    }
    $page = @(& $exe debug $bundle 2> $stderr) -join [char]10
    $embedded = [regex]::Match($page, '(?s)<script id="debug-data" type="application/json">(.*?)</script>')
    if ($LASTEXITCODE -ne 0 -or !$embedded.Success) { throw 'Could not generate the debug page.' }
    $debug = $embedded.Groups[1].Value | ConvertFrom-Json
    if ($debug.assertion.file -cne 'option-a/checks.svh' -or $debug.assertion.line -ne 1 -or
        $debug.sources.PSObject.Properties.Name -cnotcontains 'option-a/checks.svh') {
        throw 'The included assertion did not retain its archived header and source line.'
    }
    'PASS: ordered include directories, guarded nested include, header hashes, archived replay, and header debug provenance.'

    $record.project.headers = @($record.project.headers[1], $record.project.headers[0], $record.project.headers[2])
    [IO.File]::WriteAllText($saved, ($record | ConvertTo-Json -Depth 100))
    (Get-FileHash $saved).Hash.ToLowerInvariant() |
        Set-Content (Join-Path $bundle 'manifest.sha256') -Encoding ascii -NoNewline
    $reopened = @(& $exe --verify-bundle $bundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $reopened -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content $stderr -Raw) -notmatch 'bundle include order or header identity does not match') {
        throw 'The verifier accepted a modified header roster after refreshing the manifest digest.'
    }

    foreach ($test in @(
        @{ Path = '../outside.svh'; Error = "may not contain '\.\.'" },
        @{ Path = 'missing.svh'; Error = 'include file not found' },
        @{ Path = 'loop.svh'; Error = 'include nesting exceeds 32 levels' }
    )) {
        "$($tick)include " + '"loop.svh"' | Set-Content (Join-Path $root 'loop.svh')
        "$($tick)include " + ('"' + $test.Path + '"') | Set-Content $input
        $diagnostic = (Prove 'SETUP_ERROR' 2).diagnostics[0]
        if ($diagnostic.message -notmatch $test.Error -or $diagnostic.location.line -ne 1) {
            throw "Unexpected include diagnostic: $($diagnostic.message)"
        }
    }
    'PASS: rejected a reordered header roster, path traversal, missing headers, and unguarded include cycles.'

    @'
%define PASS(path) path
%ifdef UNSET
%include %MISSING_MACRO
%endif
%include %PASS(%ROOT_HEADER)
module fixture(input logic clk);
    p_flag: assert property (@(posedge clk) %FLAG);
endmodule
'@.Replace('%', [string]$tick) | Set-Content -LiteralPath $input
    $select = @'
%define NEXT_PATH(path = "inner/value.svh") path
%include %NEXT_PATH()
'@.Replace('%', [string]$tick)
    New-Item -ItemType Directory -Path (Join-Path $root 'option-b/inner') -Force | Out-Null
    foreach ($choice in 'option-a','option-b') {
        $select | Set-Content -LiteralPath (Join-Path $root "$choice/select.svh")
    }
    "%define FLAG 1'b0".Replace('%', [string]$tick) | Set-Content -LiteralPath (Join-Path $root 'option-a/inner/value.svh')
    "%define FLAG 1'b1".Replace('%', [string]$tick) | Set-Content -LiteralPath (Join-Path $root 'option-b/inner/value.svh')
    $definition = 'define ROOT_HEADER "select.svh"'
    ($head + $dirs + $definition) | Set-Content -LiteralPath $manifest
    $macroBundle = Join-Path $root 'macro-include-witness'
    $null = Prove 'BOUNDED_FAIL' 0 @('--bundle-dir', $macroBundle)
    $macroRecord = Get-Content -LiteralPath (Join-Path $macroBundle 'manifest.json') -Raw | ConvertFrom-Json
    if (($macroRecord.project.headers.path -join ',') -cne 'option-a/select.svh,option-a/inner/value.svh') {
        throw 'Macro includes changed the relative search order or lost a nested header.'
    }
    ($head + @($dirs[1], $dirs[0]) + $definition) | Set-Content -LiteralPath $manifest
    $null = Prove 'BOUNDED_PASS' 1
    $certificate = Join-Path $root 'macro-include-proof'
    $proved = & $exe prove $manifest --engine pdr --property p_flag --evidence-dir $certificate 2>$stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $proved.status -cne 'PROVEN') {
        throw "Macro-selected header did not produce a PDR proof. $(Get-Content $stderr -Raw)"
    }
    $verified = @(& $exe verify-pdr $manifest --property p_flag --evidence-dir $certificate 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Computed-include DRAT did not revalidate. $(Get-Content $stderr -Raw)"
    }
    ($head + @($dirs[1], $dirs[0]) + 'define ROOT_HEADER "option-a/select.svh"') |
        Set-Content -LiteralPath $manifest
    $null = Prove 'BOUNDED_FAIL' 0 @('--bundle-dir', (Join-Path $root 'pinned-include-witness'))
    foreach ($bad in @(
        @{ Value = '"select.svh" "extra.svh"'; Error = 'one quoted relative path after macro expansion' },
        @{ Value = 'plain_identifier'; Error = 'one quoted relative path after macro expansion' },
        @{ Value = '%UNDEFINED_HEADER'; Error = 'undefined macro: UNDEFINED_HEADER' },
        @{ Value = '"../outside.svh"'; Error = "may not contain '\.\.'" }
    )) {
        ($head + $dirs + ('define ROOT_HEADER ' + $bad.Value.Replace('%', [string]$tick))) |
            Set-Content -LiteralPath $manifest
        $diagnostic = (Prove 'SETUP_ERROR' 2).diagnostics[0]
        if ($diagnostic.message -notmatch $bad.Error -or $diagnostic.location.file -cne 'input.sv' -or
            $diagnostic.location.line -ne 5) {
            throw "Computed include diagnostic did not point to the include directive. $($diagnostic.message)"
        }
    }
    'live header replaced' | Set-Content -LiteralPath (Join-Path $root 'option-a/select.svh')
    $reopened = @(& $exe --verify-bundle $macroBundle 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Could not reproduce the macro-selected include graph from the archived arguments and headers. $reopened"
    }
    'PASS: macro-expanded include, nested default, search precedence, checked DRAT, archived replay and four invalid operands.'

    $quoteDirectory = Join-Path $root "rtl's headers"
    New-Item -ItemType Directory -Path $quoteDirectory -Force | Out-Null
    "%define FLAG 1'b0".Replace('%', [string]$tick) |
        Set-Content -LiteralPath (Join-Path $quoteDirectory 'lane  0.svh')
    "%define FLAG 1'b1".Replace('%', [string]$tick) |
        Set-Content -LiteralPath (Join-Path $quoteDirectory 'lane  1.svh')
    $quoteSource = @'
%define FIRST() 0
%define ROOT rtl
%define HEADER(n = 1) %"%ROOT's headers/lane  n%%.svh%"
%include %HEADER(%FIRST())
module fixture(input logic clk);
    p_flag: assert property (@(posedge clk) %FLAG);
endmodule
'@.Replace('%', [string]$tick)
    $head | Set-Content -LiteralPath $manifest
    $quoteSource | Set-Content -LiteralPath $input
    $quoteBundle = Join-Path $root 'quoted-path-witness'
    $null = Prove 'BOUNDED_FAIL' 0 @('--bundle-dir', $quoteBundle)
    $quoteRecord = Get-Content -LiteralPath (Join-Path $quoteBundle 'manifest.json') -Raw | ConvertFrom-Json
    if (($quoteRecord.project.headers.path -join ',') -cne "rtl's headers/lane  0.svh") {
        throw 'Macro quotation lost whitespace, punctuation or a substituted argument.'
    }
    $quoteSource.Replace("$($tick)HEADER($($tick)FIRST())", "$($tick)HEADER()") |
        Set-Content -LiteralPath $input
    $null = Prove 'BOUNDED_PASS' 1
    $quoteProof = Join-Path $root 'quoted-path-proof'
    $result = & $exe prove $manifest --engine pdr --property p_flag --evidence-dir $quoteProof 2>$stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'PROVEN') {
        throw "Quoted path did not produce a PDR proof. $(Get-Content $stderr -Raw)"
    }
    $verified = @(& $exe verify-pdr $manifest --property p_flag --evidence-dir $quoteProof 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Quoted path DRAT did not revalidate. $(Get-Content $stderr -Raw)"
    }
    @'
%define STATIC_HEADER %"rtl's headers/lane  1.svh%"
%include %STATIC_HEADER
module fixture(input logic clk);
    p_flag: assert property (@(posedge clk) %FLAG);
endmodule
'@.Replace('%', [string]$tick) | Set-Content -LiteralPath $input
    $null = Prove 'BOUNDED_PASS' 1
    'changed live quoted header' | Set-Content -LiteralPath (Join-Path $quoteDirectory 'lane  0.svh')
    $reopened = @(& $exe --verify-bundle $quoteBundle 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Could not reopen a bundle with a generated quoted header path. $reopened"
    }
    foreach ($badQuote in @(
        @{ Text = '%define FILE %"unfinished'; Error = 'unterminated macro quotation'; Line = 1 },
        @{ Text = '%define FILE %"%FILE%"'; Error = 'recursive or excessively nested macro'; Line = 2 }
    )) {
        @($badQuote.Text, '%include %FILE', 'module fixture(input logic clk); endmodule') |
            ForEach-Object { $_.Replace('%', [string]$tick) } | Set-Content -LiteralPath $input
        $diagnostic = (Prove 'SETUP_ERROR' 2).diagnostics[0]
        if ($diagnostic.location.file -cne 'input.sv' -or $diagnostic.location.line -ne $badQuote.Line -or
            $diagnostic.message -notmatch $badQuote.Error) {
            throw "Bad macro quotation lost its source diagnostic. $($diagnostic.message)"
        }
    }
    'PASS: object and function macro quotation, nested expansion, defaults, literal spacing, checked DRAT, archived replay and invalid quotes.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path $resolved -Leaf) -like 'q3a-includes-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
