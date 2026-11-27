
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @(
    'module large_mem(input logic clk, re, we, din,'
    '    input logic [19:0] ra, wa, output logic dout);'
    '    logic [0:0] words [0:1048575];'
    '    always_ff @(posedge clk) begin'
    '        if (re) dout <= words[ra];'
    '        if (we) words[wa] <= din;'
    '    end'
    '    p_ok: assert property (@(posedge clk) 1''b1);'
    'endmodule'
)
$project = "$root/large.q3a"
Set-Content -LiteralPath "$root/large.sv" -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath $project -Value @('Q3AFORMAL_PROJECT 2','top large_mem','source systemverilog "large.sv"') -Encoding utf8NoBOM
function Check-Run([string]$Name, [int]$Cells, [string]$Expected, [int]$ExpectedExit, [string]$Pattern) {
    $evidence = "$root/$Name-evidence"
    $commandArguments = @('dev-prove-memory',$project,'--property','p_ok','--output-dir',$evidence,
        '--max-cells',[string]$Cells,'--memory-mib','16','--timeout-ms','5000')
    $raw = @(& $exe @commandArguments 2> "$root/$Name.stderr.txt")
    $exit = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    $response = $raw | ConvertFrom-Json
    $log = Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw
    if ($exit -ne $ExpectedExit -or $response.status -cne $Expected -or $response.exit_code -ne $exit -or
        $log -cnotmatch $Pattern -or (Test-Path -LiteralPath $evidence)) {
        throw "Unexpected $Name verdict. $raw $log"
    }
    return $log
}
$log = Check-Run preallocation 1048576 RESOURCE_LIMIT 1 'Q3A_MEMORY_RESOURCE .*pending=[1-9][0-9]{7,}'
$null = Check-Run cell-limit 1048575 REJECTED 2 'exceeds the caller.s cell budget'
$pending = [regex]::Match($log,'pending=(\d+)').Groups[1].Value
[ordered]@{
    status = 'EXACT_MEMORY_LOWERING_RESOURCE_GUARD_PASSED'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    requested_cells = 1048576
    memory_limit_mib = 16
    pending_vector_bytes = [long]$pending
    reservation_status = 'RESOURCE_LIMIT'
    cell_limit_status = 'REJECTED'
    proof_evidence_published = $false
} | ConvertTo-Json | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: refused a $pending-byte model vector reservation before allocation, with no proof evidence published."

