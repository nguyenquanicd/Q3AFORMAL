
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$CheckerPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$checker = (Resolve-Path -LiteralPath $CheckerPath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @(
    'module controlled_mem #(parameter FAULT = 0) ('
    '    input logic clk, other_clk, reset, capture, rd_request, wr_request,'
    '    input logic [1:0] next_address, next_data,'
    '    output logic [1:0] dout'
    ');'
    '    logic [1:0] words [0:2];'
    '    logic [1:0] address_q, data_q, rd_addr, wr_data;'
    '    logic rd_en, wr_en;'
    '    always_ff @(posedge clk) begin // capture_request'
    '        if (reset) begin'
    '            address_q <= 2''d0;'
    '            data_q <= 2''d0;'
    '        end else if (capture) begin'
    '            address_q <= next_address;'
    '            data_q <= next_data;'
    '        end'
    '    end'
    '    assign rd_addr = ((FAULT != 2) && (address_q == 2''d3)) ? 2''d1 : address_q;'
    '    assign rd_en = rd_request && !reset;'
    '    assign wr_en = wr_request && !reset && ((FAULT == 1) || (address_q != 2''d3));'
    '    assign wr_data = (FAULT == 3) ? ~data_q : data_q;'
    '    always_ff @(posedge clk) begin // access_memory'
    '        if (rd_en) dout <= words[rd_addr];'
    '        if (wr_en) words[address_q] <= wr_data;'
    '    end'
    '    p_history: assert property (@(posedge clk)'
    '        (wr_en && (address_q == rd_addr)) ##1'
    '        (rd_en && (rd_addr == $past(address_q))) |=> (dout == $past(data_q, 2)));'
    '    p_read_hold: assert property (@(posedge clk) !rd_en |=> (dout == $past(dout)));'
    'endmodule'
)
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Project([string]$Name, [string[]]$Source, [int]$Fault=0) {
    Set-Content -LiteralPath "$root/$Name.sv" -Value $Source -Encoding utf8NoBOM
    $project = "$root/$Name.q3a"
    @('Q3AFORMAL_PROJECT 2','top controlled_mem',"source systemverilog ""$Name.sv""","parameter FAULT $Fault") |
        Set-Content -LiteralPath $project -Encoding utf8NoBOM
    $project
}
function Run([string]$Name, [string]$Project, [string]$Property,
             [string]$Status, [int]$Exit, [string]$Reopen = '', [string]$Diagnostic = '') {
    $command = if ($Reopen) { 'dev-verify-memory' } else { 'dev-prove-memory' }
    $option = if ($Reopen) { '--evidence-dir' } else { '--output-dir' }
    $target = if ($Reopen) { $Reopen } else { "$root/$Name-evidence" }
    $raw = @(& $exe $command $Project --property $Property $option $target --max-cells 3 --timeout-ms 30000 2> "$root/$Name.stderr.txt")
    $code = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    $json = $raw | ConvertFrom-Json
    $stderr = Get-Content -LiteralPath "$root/$Name.stderr.txt" -Raw
    if ($code -ne $Exit -or $json.exit_code -ne $code -or $json.status -cne $Status -or
        ($Diagnostic -and $stderr -cnotmatch $Diagnostic)) {
        throw "$Name expected $Status ($Exit). $raw $stderr"
    }
    if (!$Reopen -and $code -ne 0 -and (Test-Path -LiteralPath $target)) { throw "$Name published failed evidence." }
    $json
}
$healthy = Project healthy $rtl
$proved = Run history $healthy p_history PROVEN 0
$checked = Run reopened $healthy p_history REVALIDATED 0 "$root/history-evidence"
if ($proved.model_input_sha256 -cne $checked.model_input_sha256 -or $checked.manifest_sha256 -cne (Hash $healthy)) {
    throw 'Reopened history proof changed model identity.'
}
$null = Run hold $healthy p_read_hold PROVEN 0
$null = Run hold-reopened $healthy p_read_hold REVALIDATED 0 "$root/hold-evidence"

$faults = @(
    @{name='bad-write'; fault=1; status='RANGE_UNPROVED'; property='__q3a_write_in_range'}
    @{name='bad-read'; fault=2; status='RANGE_UNPROVED'; property='__q3a_read_in_range'}
    @{name='bad-data'; fault=3; status='PROPERTY_UNPROVED'; property='p_history'}
)
foreach ($fault in $faults) {
    $bad = Project $fault.name $rtl $fault.fault
    $report = Run $fault.name $bad p_history $fault.status 1
    if ($report.property -cne $fault.property) { throw "$($fault.name) failed the wrong obligation." }
}
$other = Project other-clock ($rtl -creplace 'posedge clk\) begin // capture_request','posedge other_clk) begin // capture_request')
$null = Run other-clock $other p_history REJECTED 2 -Diagnostic 'same positive-edge clock'
$floating = Project floating ($rtl | Where-Object { $_ -cnotmatch 'assign rd_en' })
$null = Run floating $floating p_history REJECTED 2 -Diagnostic 'scalar helper signal has no driver'
$multi = Project multiple-accesses ($rtl -creplace '^endmodule$', ("    always_ff @(posedge clk) begin if (wr_request) words[address_q] <= data_q; end" + [Environment]::NewLine + 'endmodule'))
$null = Run multiple-accesses $multi p_history REJECTED 2 -Diagnostic 'exactly one process with memory accesses'

$obligations = @(foreach ($folder in 'read-range','write-range','property') {
    $place = "$root/history-evidence/$folder"
    $model = (Get-Content -LiteralPath "$place/invariant.txt" -TotalCount 2)[1]
    foreach ($kind in 'initiation','consecution','safety') {
        $base = "$place/$kind"
        $raw = @(& $checker --check-drat "$base.cnf" "$base.q3adrat" --model-sha256 $model --query-kind "pdr-$kind")
        $exit = $LASTEXITCODE
        $raw | Set-Content -LiteralPath "$root/check-$folder-$kind.txt" -Encoding utf8NoBOM
        if ($exit -ne 0 -or $raw -cnotcontains 'Q3A_PROOF_CHECK ACCEPTED') { throw "Checker rejected $folder/$kind." }
        [ordered]@{group=$folder; kind=$kind; query_sha256=Hash "$base.cnf"; proof_sha256=Hash "$base.q3adrat"}
    }
})
if ($obligations.Count -ne 9) { throw 'Expected three checked obligations per proof target.' }
[ordered]@{
    status = 'EXACT_MEMORY_WITH_SAME_CLOCK_SCALAR_CONTROL_QUALIFIED'
    executable_sha256 = Hash $exe
    checker_sha256 = Hash $checker
    source_sha256 = Hash "$root/healthy.sv"
    manifest_sha256 = Hash $healthy
    validated_property_groups = @('p_history','p_read_hold')
    standalone_obligations = $obligations
    negative_range_and_property = @($faults.name)
    negative_unsupported = @('other-clock','floating','multiple-accesses')
    timed_acceptance = 'PENDING'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: exact read-old memory with registered controls, two source-revalidated proof groups, and nine standalone checked obligations.'

