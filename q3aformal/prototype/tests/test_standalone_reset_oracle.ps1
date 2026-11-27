param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-standalone-reset-' + [Guid]::NewGuid()))).FullName
$project = Join-Path $root 'reset.q3a'
$stderr = Join-Path $root 'stderr.txt'

# A separate evaluator for this small model, independent of the engine,
# transition encoder and witness replay.
function Measure-Expression($expr, [hashtable]$values) {
    switch -CaseSensitive ($expr.kind) {
        'signal' {
            if (!$values.ContainsKey($expr.value)) { throw "Unknown oracle operand $($expr.value)." }
            return [long]$values[$expr.value]
        }
        'history_ref' {
            if (!$values.ContainsKey($expr.value)) { throw "Unknown oracle history operand $($expr.value)." }
            return [long]$values[$expr.value]
        }
        'constant' { return [long]$expr.value }
        'literal' {
            if ($expr.value -cnotmatch "^1'b[01]$") { throw "Unexpected oracle literal $($expr.value)." }
            return [long]$expr.value.Substring(3)
        }
        'select' {
            $word = Measure-Expression $expr.operands[0] $values
            $offset = Measure-Expression $expr.operands[1] $values
            return ($word -shr $offset) -band ((1L -shl $expr.width) - 1L)
        }
        'concatenation' {
            $word = 0L
            foreach ($part in $expr.operands) {
                $word = ($word -shl $part.width) -bor (Measure-Expression $part $values)
            }
            return $word
        }
        'conditional' {
            $branch = if ((Measure-Expression $expr.operands[0] $values) -ne 0) { 1 } else { 2 }
            return Measure-Expression $expr.operands[$branch] $values
        }
        'binary' {
            if ($expr.value -cne '==') { throw "Unexpected oracle operator $($expr.value)." }
            return [long]((Measure-Expression $expr.operands[0] $values) -eq
                (Measure-Expression $expr.operands[1] $values))
        }
        default { throw "Unexpected oracle expression kind $($expr.kind)." }
    }
}

function Check-Prove([string]$Engine, [string]$Property, [string]$Expected, [int]$ExitCode, [string[]]$Options) {
    $result = & $exe prove $project --engine $Engine --property $Property @Options 2>$stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne $ExitCode -or $result.status -cne $Expected) {
        throw "$Engine $Property expected $Expected. $result $(Get-Content $stderr -Raw)"
    }
}

try {
    @('Q3AFORMAL_PROJECT 2', 'top top', 'source systemverilog "design.sv"',
        'property_source systemverilog "checks.sv"') | Set-Content -LiteralPath $project
    @'
module stage(input logic clk, input logic reset, input logic data, output logic q);
    always_ff @(posedge clk) begin
        if (reset) q <= 1'b0;
        else q <= data;
    end
endmodule
module wrap(input logic clk, input logic reset, input logic data, output logic q);
    stage u_stage(.clk(clk), .reset(reset), .data(data), .q(q));
endmodule
module top(input logic clk, input logic [1:0] reset, input logic [1:0] data, output logic [1:0] q);
    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_lane
            wrap u_wrap(.clk(clk), .reset(reset[i]), .data(data[i]), .q(q[i]));
        end
    endgenerate
endmodule
'@ | Set-Content -LiteralPath (Join-Path $root 'design.sv')
    @'
p_lane0: assert property (@(posedge $root.top.g_lane[0].u_wrap.u_stage.clk)
    g_lane[0].u_wrap.u_stage.q == ($past(g_lane[0].u_wrap.u_stage.reset) ?
       1'b0 : $past(g_lane[0].u_wrap.u_stage.data)));
p_lane1: assert property (@(posedge clk)
    g_lane[1].u_wrap.q == ($past(g_lane[1].u_wrap.reset) ?
       1'b0 : $past(g_lane[1].u_wrap.data)));
p_crossed: assert property (@(posedge clk)
    g_lane[0].u_wrap.u_stage.q == $past(g_lane[1].u_wrap.u_stage.data));
c_initial: cover property (@(posedge clk) $root.top.q == 2'b01);
'@ | Set-Content -LiteralPath (Join-Path $root 'checks.sv')
    $model = & $exe --lower-project $project 2>$stderr | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) { throw "Could not lower reset fixture. $(Get-Content $stderr -Raw)" }
    $laneNames = @(
        foreach ($lane in 0..1) {
            $prefix = "g_lane[$lane].u_wrap."
            $laneState = @($model.signals | Where-Object { $_.role -ceq 'state' -and $_.name.StartsWith($prefix) })
            if ($laneState.Count -ne 1) { throw "Incorrect flattened state for lane $lane." }
            $laneState[0].name
        }
    )
    $history = @($model.signals | Where-Object { $_.role -cin 'history_valid','history_data' })
    $checksByName = @{}
    foreach ($name in 'p_lane0','p_lane1','p_crossed') {
        $property = $model.properties | Where-Object name -CEQ $name
        if ($property.clock -cne 'clk' -or $property.antecedent.automaton.transitions.Count -ne 1 -or
            !$property.antecedent_history_guard_signal) {
            throw "Incorrect clock, sequence or validity guard for $name."
        }
        $checksByName[$name] = $property
    }
    $checked = $crossedFailures = 0
    foreach ($initial in 0..3) {
        foreach ($first in 0..15) {
            foreach ($second in 0..15) {
                $values = @{}
                $values[$laneNames[0]] = $initial -band 1
                $values[$laneNames[1]] = ($initial -shr 1) -band 1
                foreach ($signal in $history) { $values[$signal.name] = 0 }
                $expected = $initial
                $previousData = 0
                $inputs = $first, $second, ($first -bxor 15)
                for ($sample = 0; $sample -lt $inputs.Count; $sample++) {
                    $values.reset = ($inputs[$sample] -shr 2) -band 3
                    $values.data = $inputs[$sample] -band 3
                    foreach ($equation in $model.combinational_equations) {
                        $values[$equation.target] = Measure-Expression $equation.expression $values
                    }
                    if ($values.q -ne $expected) {
                        throw "Incorrect sampled output at sample $sample, trace $initial/$first/$second."
                    }
                    foreach ($name in 'p_lane0','p_lane1','p_crossed') {
                        $property = $checksByName[$name]
                        $guard = $values[$property.antecedent_history_guard_signal]
                        if ($guard -ne [int]($sample -gt 0)) { throw "Incorrect history validity for $name." }
                        if (!$guard) { continue }
                        $expectedCheck = $true
                        if ($name -ceq 'p_crossed') {
                            $expectedCheck = ($expected -band 1) -eq (($previousData -shr 1) -band 1)
                            if (!$expectedCheck) { $crossedFailures++ }
                        }
                        $actualCheck = Measure-Expression $property.antecedent.automaton.transitions[0].predicate $values
                        if ($actualCheck -ne [int]$expectedCheck) {
                            throw "Incorrect $name at sample $sample, trace $initial/$first/$second."
                        }
                    }
                    $next = @{}
                    foreach ($equation in $model.next_state_equations) {
                        $next[$equation.target] = Measure-Expression $equation.expression $values
                    }
                    $expected = $values.data -band (3 -bxor $values.reset)
                    $previousData = $values.data
                    foreach ($target in $next.Keys) { $values[$target] = $next[$target] }
                    $checked++
                }
            }
        }
    }
    if ($checked -ne 3072 -or $crossedFailures -ne 1024) {
        throw "Incorrect oracle population: $checked samples and $crossedFailures crossed-lane failures."
    }
    "PASS: $checked sampled states over 1024 traces, including $crossedFailures crossed-lane failures."
    Check-Prove bmc p_lane1 BOUNDED_PASS 1 @('--frames','2')
    $certificate = Join-Path $root 'proof'
    Check-Prove pdr p_lane0 PROVEN 0 @('--evidence-dir',$certificate)
    $checkedProof = @(& $exe verify-pdr $project --property p_lane0 --evidence-dir $certificate 2>$stderr)
    if ($LASTEXITCODE -ne 0 -or $checkedProof -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
        throw "Reset property DRAT did not revalidate. $(Get-Content $stderr -Raw)"
    }
    $fail = Join-Path $root 'crossed'
    $cover = Join-Path $root 'initial'
    Check-Prove bmc p_crossed BOUNDED_FAIL 0 @('--frames','2','--bundle-dir',$fail)
    Check-Prove bmc c_initial COVERED 0 @('--frames','0','--bundle-dir',$cover)
    foreach ($bundle in $fail, $cover) {
        $reopened = @(& $exe --verify-bundle $bundle 2>$stderr)
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Reset witness could not reopen. $(Get-Content $stderr -Raw)"
        }
    }
    'PASS: PDR DRAT, bounded mutant witness, and cover from an unconstrained initial state.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-standalone-reset-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
