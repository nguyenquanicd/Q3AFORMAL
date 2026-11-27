param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-standalone-sva-' + [Guid]::NewGuid()))).FullName
$project = Join-Path $root 'check.q3a'
$checks = Join-Path $root 'checks.sv'
$stderr = Join-Path $root 'stderr.txt'

function Prove([string]$Engine, [string]$Property, [string]$Status, [int]$Code, [string[]]$Options) {
    $result = & $exe prove $project --engine $Engine --property $Property @Options 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne $Code -or $result.status -cne $Status -or $result.exit_code -ne $Code) {
        throw "$Engine $Property expected $Status ($Code). $result $(Get-Content $stderr -Raw)"
    }
    $result
}

try {
    @('Q3AFORMAL_PROJECT 2', 'top top', 'source systemverilog "design.sv"',
        'property_source systemverilog "checks.sv"') | Set-Content -LiteralPath $project
    @'
module leaf(input logic clk, input logic d, output logic q);
    logic observed;
    assign observed = d;
    assign q = observed;
endmodule
module wrapper(input logic clk, input logic d, output logic q);
    leaf u_leaf(.clk(clk), .d(d), .q(q));
endmodule
module wide(input logic [1:0] data, output logic [1:0] result);
    assign result = data;
endmodule
module top(input logic clk, input logic [1:0] d, output logic [1:0] q, output logic [1:0] wide_out);
    wide u_wide(.data(d), .result(wide_out));
    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_lane
            wrapper u_wrap(.clk(clk), .d(d[i]), .q(q[i]));
        end
    endgenerate
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'design.sv')
    $standalone = @'
property equal_path;
    @(posedge $root.top.g_lane[0].u_wrap.u_leaf.clk)
        g_lane[0].u_wrap.u_leaf.d == $root.top.g_lane[0].u_wrap.u_leaf.q;
endproperty
p_eq: assert property (equal_path);
env_zero: assume property (@(posedge $root.top.clk) !g_lane[0].u_wrap.u_leaf.d);
env_one: assume property (@(posedge clk) g_lane[1].u_wrap.d);
p_bad: assert property (@(posedge clk) g_lane[0].u_wrap.u_leaf.q == g_lane[1].u_wrap.u_leaf.observed);
c_hit: cover property (@(posedge clk) g_lane[1].u_wrap.u_leaf.q);
p_history: assert property (@(posedge clk)
    $past(g_lane[1].u_wrap.u_leaf.d) == $past(g_lane[1].u_wrap.q));
p_vector: assert property (@(posedge clk) u_wide.data[1] == $root.top.u_wide.result[1]);
'@
    $standalone | Set-Content -LiteralPath $checks
    $syntax = @(& $exe --parse-project $project 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $syntax -cnotcontains 'standalone property_declarations=1 property_checks=7') {
        throw "Could not inspect standalone source. $(Get-Content $stderr -Raw)"
    }
    $inventory = & $exe properties $project 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $inventory.properties.Count -ne 7 -or
        @($inventory.properties | Where-Object { $_.clock -cne 'clk' -or $_.source.file -cne 'checks.sv' }).Count) {
        throw "Standalone inventory has incorrect source or clock binding. $(Get-Content $stderr -Raw)"
    }
    $named = $inventory.properties | Where-Object name -CEQ p_eq
    if ($named.source.line -ne 5 -or ($named.signals.rtl -join ',') -cne 'clk,d,q') {
        throw "Named property lost its alias or source span: $($named | ConvertTo-Json -Depth 8)"
    }
    $null = Prove bmc p_history BOUNDED_PASS 1 @('--frames','3')
    $null = Prove bmc p_vector BOUNDED_PASS 1 @('--frames','1')
    $certificate = Join-Path $root 'certificate'
    $null = Prove pdr p_eq PROVEN 0 @('--evidence-dir',$certificate)
    $proof = @(& $exe verify-pdr $project --property p_eq --evidence-dir $certificate 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $proof -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Standalone PDR DRAT did not revalidate. $(Get-Content $stderr -Raw)"
    }
    $witness = Join-Path $root 'witness'
    $cover = Join-Path $root 'cover'
    $null = Prove induction p_bad FAIL 0 @('--output-prefix',(Join-Path $root 'induction'),'--bundle-dir',$witness)
    $null = Prove bmc c_hit COVERED 0 @('--frames','1','--bundle-dir',$cover)
    'This live source has been replaced.' | Set-Content -LiteralPath $checks
    foreach ($bundle in $witness, $cover) {
        $verified = @(& $exe --verify-bundle $bundle 2>$stderr)
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $verified -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Standalone property bundle failed source-backed replay. $verified $(Get-Content $stderr -Raw)"
        }
    }
    'PASS: standalone named/inline SVA, generated nested aliases, clock, assumptions, history, DRAT and archived replay.'

    foreach ($bad in @(
        @{ Line = 'bad: assert property (@(posedge clk) g_lane[0].u_wrap.u_leaf.unknown);'; Status = 'ELABORATION_ERROR'; Error = 'unresolved expression name' },
        @{ Line = 'bad: assert property (@(posedge clk) $root.other.clk);'; Status = 'ELABORATION_ERROR'; Error = 'outside the selected top' },
        @{ Line = 'bad: assert property (@(posedge clk) g_lane[i].u_wrap.q);'; Status = 'UNSUPPORTED'; Error = 'nonnegative decimal literals' },
        @{ Line = 'bad: assert property (@(posedge g_lane[0].u_wrap.d) clk);'; Status = 'ELABORATION_ERROR'; Error = 'clock must resolve' }
    )) {
        $bad.Line | Set-Content -LiteralPath $checks
        $result = Prove bmc bad $bad.Status 2 @('--frames','0')
        if ($result.diagnostics[0].location.file -cne 'checks.sv' -or $result.diagnostics[0].message -cnotmatch $bad.Error) {
            throw "Incorrect standalone property diagnostic: $($result.diagnostics[0].message)"
        }
    }
    'PASS: unresolved path, wrong root, dynamic generate index and invalid sampling clock rejected at source.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-standalone-sva-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
