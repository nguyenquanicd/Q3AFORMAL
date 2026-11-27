$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-capture-' + [Guid]::NewGuid()))).FullName
$project = Join-Path $root 'capture.q3a'
$stderr = Join-Path $root 'stderr.txt'

function Run-Bounded($Label, [string[]]$Options) {
    $bundle = Join-Path $root "$Label-bundle"
    $vcd = Join-Path $root "$Label.vcd"
    $html = Join-Path $root "$Label.html"
    $out = & $exe --bmc $project --property p_bad --frames 1 --bundle-dir $bundle --vcd $vcd --html $html @Options
    if ($LASTEXITCODE -ne 0 -or $out -cnotcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "Capture run failed. $out"
    }
    $check = & $exe --verify-bundle $bundle
    if ($LASTEXITCODE -ne 0 -or $check -cnotcontains 'Q3A_BUNDLE_WAVEFORM_CAPTURE VERIFIED') {
        throw "Capture verification failed. $check"
    }
    $capture = Get-Content (Join-Path $bundle 'trace/capture.json') -Raw | ConvertFrom-Json
    $wave = & $exe trace import-vcd $vcd --q3a-roundtrip | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Capture VCD could not be imported.' }
    $waveNames = @($wave.signals | Where-Object type -CNE 'event' | ForEach-Object name | Sort-Object)
    if ((@($capture.signals.name | Sort-Object) -join '|') -cne ($waveNames -join '|')) {
        throw 'Capture manifest and VCD select different signals.'
    }
    $htmlText = Get-Content -LiteralPath $html -Raw
    foreach ($name in 'idle_one','idle_two','watched','guard','reset_local') {
        if ($htmlText.Contains("name:" + (ConvertTo-Json $name -Compress)) -ne ($waveNames -ccontains $name)) {
            throw "Capture manifest and HTML differ for $name."
        }
    }
    return $capture
}

try {
    @'
Q3AFORMAL_PROJECT 1
top capture_top
source "capture.sv"
'@ | Set-Content -LiteralPath $project
    @'
module capture_top(
    input logic clk,
    input logic rst_n,
    input logic a,
    input logic permit,
    output logic y
);
    logic watched;
    logic guard;
    logic reset_local;
    logic latched;
    logic idle_one;
    logic idle_two;
    assign watched = a;
    assign guard = permit;
    assign reset_local = !rst_n;
    assign idle_one = permit;
    assign idle_two = a;
    always_ff @(posedge clk) begin
        if (reset_local) latched <= 1'b0;
        else             latched <= a;
    end
    assign y = latched;
    p_assume: assume property (@(posedge clk) guard);
    p_bad: assert property (@(posedge clk) watched && !watched);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'capture.sv')

    $baseline = Run-Bounded 'default' @()
    foreach ($required in 'clk','rst_n','a','permit','y','watched','guard','reset_local','latched') {
        if ($baseline.signals.name -cnotcontains $required) { throw "Missing default signal $required." }
    }
    if ($baseline.all -or $baseline.signals.name -ccontains 'idle_one' -or
        $baseline.signals.name -ccontains 'idle_two') { throw 'Default capture included unrelated logic.' }
    $expanded = Run-Bounded 'expanded' @('--trace-signal','idle_one')
    if ($expanded.signals.name -cnotcontains 'idle_one' -or $expanded.signals.name -ccontains 'idle_two') {
        throw 'Named signal expansion selected the wrong signals.'
    }
    $full = Run-Bounded 'full' @('--trace-all')
    if (!$full.all -or $full.signals.name -cnotcontains 'idle_two') { throw 'Full capture missed an internal signal.' }
    $indexed = Join-Path $root 'default-bundle/properties/p_bad/trace.q3atrace'
    $window = & $exe trace window $indexed --first 0 --last 0 --signal idle_two | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $window.signals[0].name -cne 'idle_two') {
        throw 'The selected view altered the full replay witness.'
    }

    $null = & $exe prove $project --engine bmc --property p_bad --frames 0 --vcd (Join-Path $root 'unknown.vcd') --trace-signal absent 2> $stderr
    if ($LASTEXITCODE -ne 2 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'unknown trace signal') {
        throw 'Unknown signal selection did not fail as a setup error.'
    }
    $null = & $exe prove $project --engine bmc --property p_bad --frames 0 --vcd (Join-Path $root 'duplicate.vcd') --trace-signal watched --trace-signal watched 2> $stderr
    if ($LASTEXITCODE -ne 2 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'duplicate trace signal') {
        throw 'Duplicate signal selection did not fail as a setup error.'
    }

    $pdrBundle = Join-Path $root 'pdr-bundle'
    $pdr = & $exe prove $project --engine pdr --property p_bad --evidence-dir (Join-Path $root 'certificate') --bundle-dir $pdrBundle --trace-signal idle_one 2> $stderr
    $pdrExit = $LASTEXITCODE
    if ($pdrExit -ne 0 -or ($pdr | ConvertFrom-Json).status -cne 'FAIL') {
        throw "PDR did not publish a replayed failure. $(Get-Content -LiteralPath $stderr -Raw)"
    }
    $pdrCapture = Get-Content (Join-Path $pdrBundle 'trace/capture.json') -Raw | ConvertFrom-Json
    if ($pdrCapture.signals.name -cnotcontains 'idle_one' -or $pdrCapture.signals.name -ccontains 'idle_two') {
        throw 'PDR lost the requested witness selection.'
    }

    $bundlePath = Join-Path $root 'default-bundle'
    $capturePath = Join-Path $bundlePath 'trace/capture.json'
    $manifestPath = Join-Path $bundlePath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $baseline.signals = @($baseline.signals | Where-Object name -CNE 'watched')
    [IO.File]::WriteAllText($capturePath, (($baseline | ConvertTo-Json -Depth 20 -Compress) + [char]10))
    $record = $manifest.artifacts | Where-Object role -CEQ 'waveform_capture'
    $record.sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $record.size_bytes = (Get-Item -LiteralPath $capturePath).Length
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 100))
    (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath (Join-Path $bundlePath 'manifest.sha256')
    $null = & $exe --verify-bundle $bundlePath 2> $stderr
    if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $stderr -Raw) -notmatch 'differs from the model signal selection') {
        throw 'A rehashed capture with a missing dependency was accepted.'
    }
    'PASS: dependency and control capture, explicit expansion, full capture, PDR witness capture, and rejection of inconsistent capture metadata.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), (Split-Path $root -Leaf))
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
