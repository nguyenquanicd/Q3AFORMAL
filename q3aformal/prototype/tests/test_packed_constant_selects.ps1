#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$checker = Join-Path $prototype 'bin/q3aformal-proofcheck.exe'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$manifest = Join-Path $root 'project.q3a'
$source = Join-Path $root 'packed_constants.sv'
@('Q3AFORMAL_PROJECT 2','top packed_constants','source systemverilog "packed_constants.sv"') |
    Set-Content -LiteralPath $manifest -Encoding utf8
$fixture = @'
module child #(parameter logic [4:7] CFG = 4'b0000)(output logic [1:0] q);
    localparam logic [1:0] MIDDLE = CFG[5:6];
    assign q = MIDDLE;
endmodule
module packed_constants #(
    parameter integer BASE = -2,
    parameter logic signed [BASE:BASE+3] ASC = 4'b1011,
    parameter logic [63:0] WIDE = 64'h8000000000000001,
    parameter logic [1:0] EXPECT_PAIR = 2'b10,
    parameter logic [1:0] EXPECT_CHILD = 2'b01,
    parameter logic [1:0] EXPECT_GENERATE = 2'b10
)(input logic clk, input logic [2:0] din, output logic [2:0] q);
    localparam logic [2:0] WIDTH_CFG = 3'b011;
    localparam logic [7:6] PAIR = ASC[BASE:BASE+1];
    logic [WIDTH_CFG[1:0]-1:0] typed_bus;
    logic [1:0] child_bits, gen_bits;
    logic [63:0] copied;
    logic sign_bit;
    assign typed_bus = din;
    assign q = typed_bus;
    assign copied = WIDE[63:0];
    assign sign_bit = ASC[BASE];
    child #(.CFG({2'b00, ASC[BASE+2:BASE+3]})) u_child (.q(child_bits));
    generate
        if (ASC[BASE+2]) begin : selected
            localparam logic [8:5] SELECTED = 4'hd;
            assign gen_bits = SELECTED[7:6];
        end else begin : fallback
            assign gen_bits = 2'b01;
        end
    endgenerate
    p_expected: assert property (@(posedge clk)
        PAIR[7:6] == EXPECT_PAIR && child_bits == EXPECT_CHILD &&
        gen_bits == EXPECT_GENERATE && copied == 64'h8000000000000001 &&
        sign_bit == EXPECT_PAIR[1] && !(ASC[BASE:BASE+1] < 2'sb00) && q == din);
    p_injected: assert property (@(posedge clk) sign_bit != EXPECT_PAIR[1]);
    c_delay: cover property (@(posedge clk) 1'b1 ##(WIDTH_CFG[1:0]) WIDE[0]);
endmodule
'@
$fixture | Set-Content -LiteralPath $source -Encoding utf8

function Invoke-Q3A([string]$Label,[int]$Exit,[string[]]$Options,[string]$Program=$exe) {
    $stderr = Join-Path $root "$Label.stderr.txt"
    $result = @(& $Program @Options 2> $stderr)
    $actual = $LASTEXITCODE
    $result | Set-Content -LiteralPath (Join-Path $root "$Label.stdout.txt") -Encoding utf8
    if ($actual -ne $Exit) { throw "$Label expected $Exit, got $actual. $result $(Get-Content -LiteralPath $stderr -Raw)" }
    return $result -join [char]10
}

$runs = foreach ($mode in 'default','overridden') {
    $common = @($manifest)
    if ($mode -ceq 'overridden') {
        $common += @('--parameter','BASE','3','--parameter','ASC',"4'b0100",
            '--parameter','EXPECT_PAIR',"2'b01",'--parameter','EXPECT_CHILD',"2'b00",
            '--parameter','EXPECT_GENERATE',"2'b01")
    }
    $paths = foreach ($case in @(
        @{engine='bmc';property='p_expected';status='BOUNDED_PASS';code=1},
        @{engine='induction';property='p_expected';status='PROVEN';code=0},
        @{engine='pdr';property='p_expected';status='PROVEN';code=0},
        @{engine='bmc';property='p_injected';status='BOUNDED_FAIL';code=0;sample=0},
        @{engine='bmc';property='c_delay';status='COVERED';code=0;sample=3}
    )) {
        $id = "$mode-$($case.engine)-$($case.property)"
        $bundle = Join-Path $root "$id-bundle"
        $proof = Join-Path $root "$id-proof"
        $options = switch ($case.engine) {
            bmc { @('--frames','3','--bundle-dir',$bundle) }
            induction { @('--k','1','--output-prefix',$proof,'--bundle-dir',$bundle) }
            pdr { @('--max-depth','8','--evidence-dir',$proof) }
        }
        $result = Invoke-Q3A $id $case.code (@('prove') + $common +
            @('--engine',$case.engine,'--property',$case.property) + $options) | ConvertFrom-Json
        if ($result.status -cne $case.status) { throw "$id returned $($result.status)." }
        if ($case.engine -ceq 'pdr') {
            $check = Invoke-Q3A "$id-reopen" 0 (@('verify-pdr') + $common +
                @('--property',$case.property,'--evidence-dir',$proof))
            $marker = 'Q3A_PDR_CERTIFICATE VERIFIED'
        } else {
            $check = Invoke-Q3A "$id-reopen" 0 @('--verify-bundle',$bundle,'--require-source-model')
            $marker = 'Q3A_BUNDLE_STATUS REVALIDATED'
        }
        if (($check -split '\r?\n') -cnotcontains $marker) { throw "$id did not reopen its evidence." }
        if ($case.engine -ceq 'pdr') {
            foreach ($kind in 'initiation','consecution','safety') {
                $checked = Invoke-Q3A "$id-$kind" 0 @('--check-drat',
                    (Join-Path $proof "$kind.cnf"),(Join-Path $proof "$kind.q3adrat"),
                    '--model-sha256',$result.certificate.model_sha256,'--query-kind',"pdr-$kind") $checker
                if ($checked -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED$') { throw "$id failed $kind." }
            }
        } elseif ($case.engine -ceq 'induction') {
            $saved = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
            foreach ($kind in 'base','step') {
                $query = $saved.queries | Where-Object id -CEQ $kind
                $checked = Invoke-Q3A "$id-$kind" 0 @('--check-drat',
                    (Join-Path $bundle $query.cnf_path),"$proof.$kind.q3adrat",
                    '--model-sha256',$saved.model.sha256,'--query-kind',$query.kind) $checker
                if ($checked -notmatch '(?m)^Q3A_PROOF_CHECK ACCEPTED$') { throw "$id failed $kind." }
            }
        }
        if ($case.ContainsKey('sample')) {
            $traceFile = Get-ChildItem -LiteralPath $bundle -Recurse -Filter trace.json
            $trace = Get-Content -LiteralPath $traceFile.FullName -Raw | ConvertFrom-Json
            if ($trace.candidate_frame -ne $case.sample) { throw "$id did not match its sample oracle." }
        }
        [ordered]@{engine=$case.engine;property=$case.property;status=$result.status;sample=$case.sample}
    }
    [ordered]@{mode=$mode;paths=@($paths)}
}
$negative = foreach ($case in @(
    @{id='range';expression='ASC[BASE-1]';diagnostic='outside the declared packed range'},
    @{id='direction';expression='ASC[BASE+1:BASE]';diagnostic='direction must match'},
    @{id='dynamic';expression='ASC[din]';diagnostic='supported constant expressions'},
    @{id='nested';expression='ASC[BASE:BASE+1][0]';diagnostic='nested selects'},
    @{id='initializer-range';expression='ASC[BASE-1:BASE]';initializer=$true;diagnostic='outside the declared packed range'}
)) {
    $invalid = if ($case.initializer) {
        $fixture.Replace('PAIR = ASC[BASE:BASE+1];',"PAIR = $($case.expression);")
    } else {
        $fixture.Replace('assign sign_bit = ASC[BASE];',"assign sign_bit = $($case.expression);")
    }
    $invalid | Set-Content -LiteralPath $source -Encoding utf8
    $result = Invoke-Q3A $case.id 2 @('prove',$manifest,'--engine','bmc',
        '--property','p_expected','--frames','1') | ConvertFrom-Json
    if ($result.status -cne 'ELABORATION_ERROR' -or
        $result.diagnostics[0].message -notmatch $case.diagnostic -or
        $result.diagnostics[0].location.file -cne 'packed_constants.sv') {
        throw "Missing source-located rejection for $($case.id)."
    }
    $case.id
}
$fixture | Set-Content -LiteralPath $source -Encoding utf8
[ordered]@{schema='Q3AFORMAL_PACKED_CONSTANT_SELECTS_1';executable_sha256=(Get-FileHash $exe).Hash.ToLowerInvariant();
    source_sha256=(Get-FileHash $source).Hash.ToLowerInvariant();runs=@($runs);rejected=@($negative)} |
    ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $root 'qualification.json') -Encoding utf8
'PASS: packed parameter and localparam selects, exact RTL/SVA results across three engines, and five source-located rejections.'
