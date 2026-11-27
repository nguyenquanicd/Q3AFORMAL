param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-property-bind-' + [Guid]::NewGuid()))).FullName
$project = Join-Path $root 'bind.q3a'
$bindFile = Join-Path $root 'attach.sv'
$stderr = Join-Path $root 'stderr.txt'

function Prove([string]$Engine, [string]$Property, [string]$Status, [int]$Code, [string[]]$Options) {
    $result = & $exe prove $project --engine $Engine --property $Property @Options 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Engine $Property to return $Status ($Code). $(Get-Content $stderr -Raw)"
    }
    $result
}

try {
    @('Q3AFORMAL_PROJECT 2', 'top top', 'source systemverilog "design.sv"',
        'property_source systemverilog "monitor.sv"', 'property_source systemverilog "attach.sv"') |
        Set-Content -LiteralPath $project
    @'
module leaf(input logic clk, input logic d, output logic q);
    assign q = d;
endmodule
module top #(parameter integer CHECK_LANE = 0)(input logic clk, input logic [1:0] d, output logic [1:0] q);
    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_lane
            leaf u_dut(.clk(clk), .d(d[i]), .q(q[i]));
        end
    endgenerate
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'design.sv')
    @'
module monitor #(parameter logic EXPECT_EQUAL = 1'b1) (
    input logic sample_clk, input logic expected, input logic actual
);
    p_matches: assert property (@(posedge sample_clk) (expected == actual) == EXPECT_EQUAL);
    c_high: cover property (@(posedge sample_clk) actual);
endmodule
module drives_design(input logic clk, output logic out_port);
    assign out_port = clk;
endmodule
module lane_environment(input logic sample_clk, input logic observed);
    env_quiet: assume property (@(posedge sample_clk) !observed);
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'monitor.sv')
    $directives = @(
        'bind leaf monitor all_checks (.sample_clk(clk), .expected(d), .actual(q));',
        'bind top.g_lane[1].u_dut monitor #(.EXPECT_EQUAL(1''b0)) selected_check (clk, d, q);',
        'bind top.g_lane[1].u_dut lane_environment selected_env (clk, d);',
        'bind top monitor top_check (clk, d[CHECK_LANE], q[CHECK_LANE]);'
    )
    $directives | Set-Content -LiteralPath $bindFile
    $model = & $exe --lower-project $project 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Bind lowering failed. $(Get-Content $stderr -Raw)" }
    $expectedNames = @(
        'g_lane[0].u_dut.all_checks.p_matches', 'g_lane[1].u_dut.all_checks.p_matches',
        'g_lane[1].u_dut.selected_check.p_matches', 'top_check.p_matches'
    )
    $assertions = @($model.properties | Where-Object kind -CEQ assert)
    if ((Compare-Object ($assertions.name | Sort-Object) ($expectedNames | Sort-Object)) -or
        @($assertions | Where-Object { $_.clock -cne 'clk' -or $_.source.file -cne 'monitor.sv' -or $_.source.line -ne 4 }).Count) {
        throw 'Bound monitors were attached to the wrong instances or lost their sampling/source identity.'
    }
    $syntax = @(& $exe --parse-project $project 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $syntax -cnotcontains 'Q3A_SYNTAX_OK "attach.sv" modules=0' -or
        !($syntax -cmatch '^bind top\.g_lane\[1\]\.u_dut monitor selected_check 2:1$')) {
        throw "Project parser did not report the exact binding target. $(Get-Content $stderr -Raw)"
    }
    $inventory = & $exe properties $project 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect bound properties. $(Get-Content $stderr -Raw)" }
    $topCheck = $inventory.properties | Where-Object name -CEQ 'top_check.p_matches'
    $laneAssumption = $inventory.properties | Where-Object name -CEQ 'g_lane[1].u_dut.selected_env.env_quiet'
    if (($topCheck.signals.rtl -join ',') -cne 'clk,d,q' -or $laneAssumption.kind -cne 'assume' -or
        ($laneAssumption.signals.rtl -join ',') -cne 'clk,d') {
        throw 'Bound property inventory did not resolve formal names into the target design scope.'
    }
    foreach ($name in $expectedNames | Where-Object { $_ -cnotlike '*selected_check*' }) {
        $null = Prove 'bmc' $name 'BOUNDED_PASS' 1 @('--frames', '1')
    }
    $proof = Join-Path $root 'certificate'
    $null = Prove 'pdr' $expectedNames[0] 'PROVEN' 0 @('--evidence-dir', $proof)
    $reopen = & $exe verify-pdr $project --property $expectedNames[0] --evidence-dir $proof 2>$stderr
    if ($LASTEXITCODE -ne 0 -or $reopen -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "The bound-monitor DRAT evidence did not revalidate. $(Get-Content $stderr -Raw)"
    }
    $bundle = Join-Path $root 'witness'
    $null = Prove 'induction' $expectedNames[2] 'FAIL' 0 @('--output-prefix', (Join-Path $root 'try'), '--bundle-dir', $bundle)
    $coverBundle = Join-Path $root 'cover'
    $null = Prove 'bmc' 'top_check.c_high' 'COVERED' 0 @('--frames', '1', '--bundle-dir', $coverBundle)
    $null = Prove 'bmc' 'g_lane[1].u_dut.all_checks.c_high' 'BOUNDED_COVER_MISS' 1 @('--frames', '1')
    $overrideArgs = @('--parameter', 'CHECK_LANE', '1')
    $overrideInventory = & $exe properties $project @overrideArgs 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $overrideInventory.source_set_sha256 -ceq $inventory.source_set_sha256) {
        throw "Property inspection did not apply the command-line parameter. $(Get-Content $stderr -Raw)"
    }
    $missBundle = Join-Path $root 'cover-override'
    $miss = & $exe prove $project @overrideArgs --engine bmc --property top_check.c_high --frames 1 --bundle-dir $missBundle 2>$stderr |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $miss.status -cne 'BOUNDED_COVER_MISS') {
        throw "The command-line parameter did not select the restricted lane. $(Get-Content $stderr -Raw)"
    }
    $proofIdentity = (Get-Content (Join-Path $missBundle 'manifest.json') -Raw | ConvertFrom-Json).profile.source_set_sha256
    if ($proofIdentity -cne $overrideInventory.source_set_sha256) {
        throw 'Property inspection and proof used different parameter-resolved project identities.'
    }
    'This live file no longer contains a binding.' | Set-Content -LiteralPath $bindFile
    foreach ($path in $bundle, $coverBundle, $missBundle) {
        $reopen = & $exe --verify-bundle $path 2>$stderr
        if ($LASTEXITCODE -ne 0 -or $reopen -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $reopen -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Could not reopen a bound property from archived sources. $(Get-Content $stderr -Raw)"
        }
    }
    'PASS: module-wide and generated-instance bind, named/positional ports, parameter override, scoped assumptions, checked DRAT, and archived replay.'

    foreach ($case in @(
        @{ Line = 'bind top.missing monitor check (clk, d[0], q[0]);'; Status = 'ELABORATION_ERROR'; Error = 'not in the elaborated hierarchy' },
        @{ Line = 'bind missing monitor check (clk, d, q);'; Status = 'ELABORATION_ERROR'; Error = 'unresolved module' },
        @{ Line = 'bind top drives_design bad (clk, q[0]);'; Status = 'ELABORATION_ERROR'; Error = 'only input ports' },
        @{ Line = 'bind top monitor bad (clk, d, q[0]);'; Status = 'ELABORATION_ERROR'; Error = 'exact widths are required' },
        @{ Line = 'bind top monitor top_check (clk, d[0], q[0]);'; Status = 'ELABORATION_ERROR'; Error = 'duplicate instance name' },
        @{ Line = 'bind leaf : u_dut monitor check (clk, d, q);'; Status = 'UNSUPPORTED'; Error = 'instance lists' },
        @{ Line = 'bind top.g_lane[i].u_dut monitor check (clk, d, q);'; Status = 'UNSUPPORTED'; Error = 'nonnegative decimal literals' }
    )) {
        ($directives + $case.Line) | Set-Content -LiteralPath $bindFile
        $result = Prove 'bmc' 'top_check.p_matches' $case.Status 2 @('--frames', '0')
        if ($result.diagnostics[0].location.file -cne 'attach.sv' -or
            $result.diagnostics[0].message -notmatch $case.Error) {
            throw "Wrong bind diagnostic: $($result.diagnostics[0].message)"
        }
    }
    'PASS: seven invalid or unsupported bindings rejected with source-located diagnostics.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-property-bind-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
