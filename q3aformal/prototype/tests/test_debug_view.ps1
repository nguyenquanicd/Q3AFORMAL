param(
    [string]$ExecutablePath = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path } else {
    Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
}
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-debug-view-' + [Guid]::NewGuid()))).FullName

try {
    $bundle = Join-Path $root 'bundle'
    $project = Join-Path $root 'fixture.q3a'
    @'
Q3AFORMAL_PROJECT 1
top fixture
source "fixture.sv"
'@ | Set-Content -LiteralPath $project
    @'
// </script><b>literal source text</b>
module fixture(
    input logic clk,
    input logic a,
    input logic [1:0] data_bus
);
    p_toggle_high: assume property (@(posedge clk) a |=> !a);
    p_toggle_low: assume property (@(posedge clk) !a |=> a);
    p_bus_fixed: assume property (@(posedge clk) data_bus == 2'b00);
    p_bad: assert property (@(posedge clk) (a && !a));
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'fixture.sv')
    $result = & $exe --bmc $project --property p_bad --frames 800 --bundle-dir $bundle
    if ($LASTEXITCODE -ne 0 -or $result -cnotcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw 'Could not produce a debug witness.'
    }
    $page = Join-Path $root 'debug.html'
    $output = & $exe debug $bundle --reset a low --group 'APB control' a --group 'CSR data' data_bus
    if ($LASTEXITCODE -ne 0) { throw 'Could not emit debug page.' }
    $output | Set-Content -LiteralPath $page -Encoding utf8
    & node (Join-Path $PSScriptRoot 'debug_view_test.cjs') $page (
        Join-Path $bundle 'properties/p_bad/trace.q3atrace')
    if ($LASTEXITCODE -ne 0) { throw 'Debug page behavior test failed.' }

    $stepBundle = Join-Path $root 'step-bundle'
    $stepProject = Join-Path $prototype 'bmc-past.q3a'
    $step = & $exe --prove-inductive $stepProject --property p_past_a --output-prefix (Join-Path $root 'step') --bundle-dir $stepBundle
    if ($LASTEXITCODE -ne 0 -or $step -cnotcontains 'Q3A_INDUCTION_STATUS NOT_1_INDUCTIVE') {
        throw 'Could not produce an induction step countermodel.'
    }
    $stepPage = @(& $exe debug $stepBundle --obligation step) -join [char]10
    if ($LASTEXITCODE -ne 0 -or !$stepPage.Contains('"Obligation":"step"') -or
        !$stepPage.Contains('"Result":"NOT_1_INDUCTIVE"')) {
        throw 'Debug view did not preserve the induction step result.'
    }

    $stderr = Join-Path $root 'stderr.txt'
    $badReset = @(& $exe debug $bundle --reset data_bus high 2> $stderr)
    if ($LASTEXITCODE -ne 2 -or $badReset.Count -ne 0 -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'known one-bit signal') {
        throw 'A vector was accepted as a reset annotation.'
    }
    $badGroup = @(& $exe debug $bundle --group 'Unknown group' absent 2> $stderr)
    if ($LASTEXITCODE -ne 2 -or $badGroup.Count -ne 0 -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'unknown signal in debug group') {
        throw 'An unknown grouped signal was accepted.'
    }
    $missing = @(& $exe debug $bundle --obligation step 2> $stderr)
    if ($LASTEXITCODE -ne 2 -or $missing.Count -ne 0) { throw 'Invalid debug obligation was accepted.' }
    Add-Content -LiteralPath (Join-Path $bundle 'model/model.json') -Value 'changed'
    $changed = @(& $exe debug $bundle 2> $stderr)
    if ($LASTEXITCODE -eq 0 -or $changed.Count -ne 0 -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'artifact size or SHA-256 mismatch') {
        throw 'Debug emitted a page for a changed result bundle.'
    }
    'PASS: verified debug page and rejection of tampered bundles.'
} finally {
    $expected = [IO.Path]::Combine([IO.Path]::GetTempPath(), (Split-Path $root -Leaf))
    if ((Resolve-Path -LiteralPath $root).Path -eq $expected) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
