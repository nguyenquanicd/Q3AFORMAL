$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('q3a-gate-a-' + [guid]::NewGuid().ToString('N'))
$manifest = Join-Path $scratch 'case.q3a'
$source = Join-Path $scratch 'case.sv'

$expressions = @{
    'RTL-008' = @("'h1")
    'RTL-009' = @("1'bx", "1'bz")
    'RTL-018' = @('a * b', 'a / b', 'a % b', 'a ** b', '1.5')
}
$moduleItems = @{
    'RTL-021' = @('always_comb begin if (a) y = b; end')
    'RTL-024' = @(
        'always_ff @(negedge clk) y <= a;',
        'always_ff @(posedge clk or posedge rst) y <= a;',
        'assign y = a; assert property (@(posedge clk) a); assert property (@(posedge clk2) a);'
    )
    'RTL-030' = @(
        'always @(posedge clk) y <= a;',
        'function logic f(); return a; endfunction',
        'task t(); endtask',
        'union packed {logic a; logic b;} val;',
        'logic memory [0:3];',
        'class c; endclass',
        'import "DPI-C" function int f();',
        'always_ff @(posedge clk) begin #1 y <= a; end',
        'always_ff @(posedge clk) begin force y = a; end',
        'always_ff @(posedge clk) begin release y; end'
    )
}
$sva = @{
    'SVA-011' = @('$past(a,0)', '$past(a,1,b)', '$past(a,1,b,@(posedge clk2))')
    'SVA-012' = @(
        'disable iff (rst) a', 's_eventually a', 'a[*1:$]', 'a[->1]', 'a[=1]',
        'a[*0]', 'a[*0:2]', 'a ##b b', '$stable(a)', '$rose(a)', '$fell(a)', '$changed(a)'
    )
}
$cases = foreach ($rule in $expressions.Keys) {
    foreach ($expr in $expressions[$rule]) { @{ Rule = $rule; Item = "assign y = $expr;" } }
}
$cases += foreach ($rule in $moduleItems.Keys) {
    foreach ($item in $moduleItems[$rule]) { @{ Rule = $rule; Item = $item } }
}
$cases += foreach ($rule in $sva.Keys) {
    foreach ($expr in $sva[$rule]) {
        @{ Rule = $rule; Item = "assign y = a; assert property (@(posedge clk) $expr);" }
    }
}
$cases += @{ Rule = 'RTL-030'; Prefix = 'interface unsupported_interface; endinterface'; Item = 'assign y = a;' }
$cases += @{ Rule = 'SVA-012'; Item = 'assign y = a; property p; logic local_value; @(posedge clk) a; endproperty assert property (p);' }

[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    [IO.File]::WriteAllLines($manifest, @('Q3AFORMAL_PROJECT 1', 'top rejected_case', 'source "case.sv"'))
    foreach ($case in $cases) {
        [IO.File]::WriteAllLines($source, @(
            [string]$case.Prefix,
            'module rejected_case(input logic clk, clk2, rst, a, b, output logic y);',
            $case.Item, 'endmodule'
        ))
        $out = @(& $tool --lower-project $manifest 2>&1)
        if ($LASTEXITCODE -ne 1 -or ($out -join "`n") -notmatch 'case\.sv:[1-4]:\d+:' -or
            ($out -join "`n") -match 'Q3A_BMC_STATUS|Q3A-TIR-0\.4') {
            throw "Expected a source-located rejection for $($case.Rule), $($case.Item):`n$($out -join "`n")"
        }
        "$($case.Rule) $($case.Item) $($out -join ' ')"
    }
    "PASS: all $($cases.Count) Gate A negative examples rejected before proof with source locations."
} finally {
    foreach ($path in @($manifest, $source)) { [IO.File]::Delete($path) }
    [IO.Directory]::Delete($scratch)
}
