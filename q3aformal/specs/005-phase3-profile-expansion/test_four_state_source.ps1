#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$StandardExecutable,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (New-Item -Path $OutputDirectory -ItemType Directory).FullName
$dev = (Resolve-Path -LiteralPath $ExecutablePath).Path
$standard = (Resolve-Path -LiteralPath $StandardExecutable).Path
$rtl = @"
module data_xz(
    input logic sel, input logic signed [1:0] a, input logic [3:0] b,
    output logic [3:0] mux, masked, preserve, fill, padded, joined,
    output logic eq, strict, different, logical_value
);
    logic [3:0] intermediate;
    assign mux = sel ? intermediate : b;
    assign intermediate = a | 4'b00z0;
    assign masked = b & 4'b00z1;
    assign preserve = 1'b1 ? 4'hz : b;
    assign fill = 'Z;
    assign padded = 4'bx;
    assign joined = {a, b[1:0]};
    assign eq = a == b;
    assign strict = b === 4'b01zz;
    assign different = b !== 4'b01zz;
    assign logical_value = a || b;
endmodule
"@
$manifest = @('Q3AFORMAL_PROJECT 2','top data_xz','source systemverilog "test.sv"','option profile Q3A-FOUR-STATE-DEVELOPMENT')
$project = "$root/four.q3a"
Set-Content -LiteralPath "$root/test.sv" -Value $rtl -Encoding utf8NoBOM
Set-Content -LiteralPath $project -Value $manifest -Encoding utf8NoBOM
Set-Content -LiteralPath "$root/baseline.q3a" -Value $manifest[0..2] -Encoding utf8NoBOM
function Run($Name, $Program, $Status, [int]$ExitCode, [string[]]$Command) {
    $raw = @(& $Program @Command 2> "$root/$Name.stderr.txt")
    $actual = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.json" -Encoding utf8NoBOM
    $report = $raw | ConvertFrom-Json
    if ($report.status -cne $Status -or $actual -ne $ExitCode -or $report.exit_code -ne $ExitCode) {
        throw "$Name expected $Status/$ExitCode. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)"
    }
    $report
}
function Match-Signals($Name, $Result, $Expected) {
    foreach ($entry in $Expected.GetEnumerator()) {
        $value = $Result.signals.($entry.Key)
        if ($value -cne $entry.Value) { throw "$Name $($entry.Key): expected $($entry.Value), got $value." }
    }
}
$prefix = @('dev-eval-four-state',$project)
$base = @('--input','a','x1','--input','b','01zz')
$x = Run ambiguous $dev EVALUATED 0 ($prefix + $base + @('--input','sel','x'))
Match-Signals ambiguous $x @{
    mux='0xxx'; intermediate='00x1'; masked='00xx'; preserve='zzzz'; fill='zzzz';
    padded='xxxx'; joined='x1zz'; eq='0'; strict='1'; different='0'; logical_value='1'
}
$one = Run choose-first $dev EVALUATED 0 ($prefix + $base + @('--input','sel','1'))
$zero = Run choose-second $dev EVALUATED 0 ($prefix + $base + @('--input','sel','0'))
Match-Signals choose-first $one @{mux='00x1'}
Match-Signals choose-second $zero @{mux='01zz'}
if ($one.model_sha256 -cne $zero.model_sha256 -or $x.model_sha256 -cne $one.model_sha256) {
    throw 'Model identity changed across concrete inputs.'
}
$z = Run incompatible-bitwise $dev EVALUATED 0 ($prefix + @('--input','a','11','--input','b','zz00','--input','sel','z'))
Match-Signals incompatible-bitwise $z @{mux='xxxx'; padded='xxxx'; eq='0'; strict='0'; different='1'}

$null = Run missing $dev REJECTED 2 ($prefix + $base)
$null = Run wrong-width $dev REJECTED 2 ($prefix + $base + @('--input','sel','01'))
$null = Run duplicate $dev REJECTED 2 ($prefix + $base + @('--input','sel','1','--input','sel','1'))
$null = Run unknown $dev REJECTED 2 ($prefix + $base + @('--input','sel','1','--input','other','0'))
$null = Run baseline-profile $dev REJECTED 2 @('dev-eval-four-state',"$root/baseline.q3a")
$null = Run forbidden-proof $dev UNSUPPORTED 2 @('prove',$project,'--engine','bmc','--property','p','--frames','0')
$outside = @(
    @{name='bit-type'; text=$rtl.Replace('logic sel','bit sel')},
    @{name='undriven'; text=$rtl.Replace("assign fill = 'Z;",'')},
    @{name='exponentiation'; text=$rtl.Replace("a | 4'b00z0","a ** 4'b00z0")},
    @{name='latch'; text=$rtl.Replace("assign fill = 'Z;","always_comb begin if (sel) fill = 'Z; end")}
)
foreach ($entry in $outside) {
    $name = $entry.name
    Set-Content -LiteralPath "$root/$name.sv" -Value $entry.text -Encoding utf8NoBOM
    Set-Content -LiteralPath "$root/$name.q3a" -Value ($manifest -replace 'test\.sv',"$name.sv") -Encoding utf8NoBOM
    $null = Run $name $dev REJECTED 2 (@('dev-eval-four-state',"$root/$name.q3a") + $base + @('--input','sel','0'))
}
$raw = @(& $standard --lower-project $project 2> "$root/standard.stderr.txt")
if ($LASTEXITCODE -eq 0 -or $raw -match 'semantic_profile') { throw 'Standard build admitted the four-state profile.' }
$raw = @(& $dev --lower-project "$root/baseline.q3a" 2> "$root/no-opt-in.stderr.txt")
if ($LASTEXITCODE -eq 0 -or $raw -match 'semantic_profile') { throw 'Four-state constructs accepted without the development profile.' }

$reference = Join-Path $PSScriptRoot '../../evidence/r4/phase0/B-02-counter4-fail-artifacts/bundle'
$forged = "$root/mislabeled"
Copy-Item -LiteralPath $reference -Destination $forged -Recurse
$manifestFile = "$forged/manifest.json"
$bundleManifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json -AsHashtable
$bundleManifest.profile.id = 'Q3A-FOUR-STATE-DEVELOPMENT'
$bundleManifest | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath $manifestFile -Encoding utf8NoBOM
(Get-FileHash -LiteralPath $manifestFile).Hash.ToLowerInvariant() |
    Set-Content -LiteralPath "$forged/manifest.sha256" -Encoding ascii
$raw = @(& $dev --verify-bundle $forged --require-source-model 2> "$root/bundle-profile.stderr.txt")
if ($LASTEXITCODE -eq 0 -or (Get-Content "$root/bundle-profile.stderr.txt" -Raw) -notmatch 'cannot use two-state result bundles') {
    throw 'A mislabeled two-state archive crossed the four-state profile boundary.'
}

[ordered]@{
    status = 'FOUR_STATE_COMBINATIONAL_RTL_EVALUATION_QUALIFIED'
    executable_sha256 = (Get-FileHash -LiteralPath $dev).Hash.ToLowerInvariant()
    standard_sha256 = (Get-FileHash -LiteralPath $standard).Hash.ToLowerInvariant()
    model_sha256 = $x.model_sha256
    accepted_cases = 4
    rejected_cases = 13
    reports = @(Get-ChildItem -LiteralPath $root -Filter '*.json' | Sort-Object Name | ForEach-Object {
        @{ name=$_.Name; sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
    })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: source-derived four-state evaluation, opt-in separation, and unsupported constructs.'
