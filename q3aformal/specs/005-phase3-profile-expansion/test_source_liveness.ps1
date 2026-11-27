#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rtl = @"
module liveness_demo(input logic clk, request, grant, output logic response);
    logic active, pending;
    assign response = active && grant;
    assign active = pending || request;
    always_ff @(posedge clk) begin
        pending <= active && !grant;
    end
endmodule
"@
$manifest = @('Q3AFORMAL_PROJECT 2', 'top liveness_demo', 'source systemverilog "demo.sv"')
$project = "$root/demo.q3a"
Set-Content -LiteralPath $project -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/demo.sv" -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/forbid.sv" -Value ($rtl.Replace('endmodule', @"
    a_no_grant: assume property (@(posedge clk) !grant);
endmodule
"@)) -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/temporal.sv" -Value ($rtl.Replace('endmodule', @"
    a_temporal: assume property (@(posedge clk) request |=> grant);
endmodule
"@)) -Encoding utf8NoBOM
foreach ($name in 'forbid','temporal') {
    Set-Content -LiteralPath "$root/$name.q3a" -Value ($manifest -replace 'demo\.sv', "$name.sv") -Encoding utf8NoBOM
}
$cancel = "$root/cancel.txt"
Set-Content -LiteralPath $cancel -Value 'cancel' -Encoding ascii

function Invoke-Case($Name, $Project, $Status, [int]$ExitCode, [string[]]$Extra = @(), [string]$Request = 'request') {
    $out = @(& $exe dev-check-liveness $Project --request $Request --response response @Extra 2> "$root/$Name.stderr.txt")
    $actualExit = $LASTEXITCODE
    $out | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $result = $out | ConvertFrom-Json
    if ($result.status -cne $Status -or $actualExit -ne $ExitCode -or $result.exit_code -ne $ExitCode) {
        throw "$Name expected $Status/$ExitCode. $out $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $result
}

function Signal-Value($Layout, [int]$Packed, [string]$Name) {
    foreach ($bit in $Layout) {
        if ($bit.name -ceq $Name) { return ($Packed -band ((1 -shl $bit.width) - 1)) }
        $Packed = $Packed -shr $bit.width
    }
    throw "Signal $Name absent from layout."
}

function Check-Path($Result, [bool]$Violation, [bool]$Fair) {
    $path = @($Result.path)
    $entry = $Result.loop_start
    if (!$Result.checked_graph_evidence -or $entry -ge $path.Count - 1 -or $path[0].waiting) {
        throw 'Invalid lasso indices or initial monitor state.'
    }
    $last = $path.Count - 1
    foreach ($field in 'state','input','waiting') {
        if ($path[$entry].$field -ne $path[$last].$field) { throw 'Lasso closure changed.' }
    }
    $justice = $false
    for ($i = 0; $i -lt $last; ++$i) {
        $sample = $path[$i]
        $request = Signal-Value $Result.input_layout $sample.input request
        $grant = Signal-Value $Result.input_layout $sample.input grant
        $pending = Signal-Value $Result.state_layout $sample.state pending
        $active = $request -or $pending
        $response = $active -and $grant
        $nextState = Signal-Value $Result.state_layout $path[$i + 1].state pending
        if ($nextState -ne [int]($active -and !$grant) -or
            $path[$i + 1].waiting -ne (($sample.waiting -or $request) -and !$response)) {
            throw "Independent RTL or monitor replay disagreed at sample $i."
        }
        if ($i -ge $entry) {
            if ($Violation -and (!$sample.waiting -or $response)) { throw 'Loop resolves the obligation.' }
            $justice = $justice -or $grant
        }
    }
    if ($Fair -and !$justice) { throw 'Required grant only occurs before the loop.' }
}

$failed = Invoke-Case bad $project VIOLATION 0
Check-Path $failed $true $false
$proved = Invoke-Case fair $project NO_VIOLATION 0 @('--justice','grant')
Check-Path $proved $false $true
if ($proved.model_sha256 -cne $failed.model_sha256) { throw 'The fairness option changed the elaborated design.' }
$empty = Invoke-Case no-fair "$root/forbid.q3a" NO_FAIR_EXECUTION 1 @('--justice','grant')
if (!$empty.checked_graph_evidence -or $null -ne $empty.path) { throw 'No-fair outcome exposes a misleading witness.' }
$null = Invoke-Case forbid-grant "$root/forbid.q3a" VIOLATION 0
$null = Invoke-Case delayed-assumption "$root/temporal.q3a" REJECTED 2
$null = Invoke-Case small-vertices $project RESOURCE_LIMIT 1 @('--max-vertices','1')
$null = Invoke-Case small-edges $project RESOURCE_LIMIT 1 @('--max-edges','1')
$null = Invoke-Case cancelled $project CANCELLED 1 @('--cancel-file',$cancel)
$null = Invoke-Case immediate-response $project NO_VIOLATION 0 @() 'response'
$null = Invoke-Case dup-justice $project REJECTED 2 @('--justice','grant','--justice','grant')
$null = Invoke-Case missing-signal $project REJECTED 2 @('--justice','unknown')
[ordered]@{
    status = 'SOURCE_LIVENESS_FUNCTIONALLY_QUALIFIED'
    executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    cases = 11
    independently_replayed_lassos = 2
    model_sha256 = $proved.model_sha256
    reports = @(Get-ChildItem -LiteralPath $root -Filter '*.json' | Sort-Object Name | ForEach-Object {
        @{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
    })
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: 11 RTL liveness cases, including two independently replayed lassos.'
