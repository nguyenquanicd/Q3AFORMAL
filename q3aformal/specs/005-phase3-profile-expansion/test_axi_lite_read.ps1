
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
$source = Join-Path $PSScriptRoot 'axi-lite'
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$fixtureDir = (New-Item -ItemType Directory -Path "$root/fixture").FullName
$files = @('read.q3a','read_unit.sv','read_formal.sv')
foreach ($name in $files) { Copy-Item -LiteralPath "$source/$name" -Destination $fixtureDir }
$project = "$fixtureDir/read.q3a"
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
$sourceHashes = [ordered]@{}
foreach ($name in $files) { $sourceHashes[$name] = Hash "$fixtureDir/$name" }
$exeHash = Hash $exe
$checkerHash = Hash $checker

function Run-Logged([string]$Name, [string]$Program, [string[]]$Arguments) {
    $log = "$root/$Name"
    $output = @(& $Program @Arguments 2> "$log.stderr.txt")
    $code = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$log.stdout.txt" -Encoding utf8NoBOM
    [pscustomobject]@{code = $code; text = $output -join [Environment]::NewLine; error_log = "$log.stderr.txt"}
}
function Prove-Status([string]$Name, [string[]]$Arguments, [string]$Expected) {
    $run = Run-Logged $Name $exe (@('prove',$project) + $Arguments)
    $report = $run.text | ConvertFrom-Json
    if ($report.status -cne $Expected -or $report.exit_code -ne $run.code) {
        throw "$Name expected $Expected. $($run.text) $(Get-Content -LiteralPath $run.error_log -Raw)"
    }
    $report
}
function Lane([int]$Byte) {
    @('--parameter','LO',[string]($Byte*8),
        '--parameter','HI',[string]($Byte*8+7))
}
function Verify-Witness([string]$Name, [string]$Bundle) {
    $run = Run-Logged "$Name-replay" $exe @('--verify-bundle',$Bundle,'--require-source-model')
    if ($run.code -ne 0 -or $run.text -cnotmatch 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $run.text -cnotmatch 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED' -or
        $run.text -cnotmatch 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw "Source replay failed for $Name. $($run.text) $(Get-Content -LiteralPath $run.error_log -Raw)"
    }
}
$targets = @(
    @{name='reset'; property='p_reset'; lane=0},
    @{name='control-step'; property='p_control_step'; lane=0}
    foreach ($byte in 0..3) {
        @{name="byte-step-$byte"; property='p_lane_step'; lane=$byte}
        @{name="hold-$byte"; property='p_response_hold'; lane=$byte}
    }
)
$certificates = @{}
$proofs = @(foreach ($target in $targets) {
    $name = $target.name
    $property = $target.property
    $certificateDir = "$root/$name-certificate"
    $point = Lane $target.lane
    $record = Prove-Status $name ($point + @('--timeout-ms','30000','--engine','pdr','--property',$property,
        '--max-depth','8','--evidence-dir',$certificateDir)) 'PROVEN'
    $verify = Run-Logged "$name-verify" $exe (@('verify-pdr',$project) + $point +
        @('--property',$property,'--evidence-dir',$certificateDir))
    if ($verify.code -ne 0 -or $verify.text -cnotmatch 'Q3A_PDR_CERTIFICATE VERIFIED' -or
        $verify.text -cnotmatch 'Q3A_PDR_RUN_CONFIGURATION VERIFIED') {
        throw "$name did not revalidate against the exact source and parameters."
    }
    if ($record.run_configuration.parameters.LO -cne [string]($target.lane * 8) -or
        $record.run_configuration.parameters.HI -cne [string]($target.lane * 8 + 7)) {
        throw "$name did not record its byte lane."
    }
    $certificates[$name] = $record.certificate
    [ordered]@{
        case = $name
        property = $property
        lane = $target.lane
        certificate_model_sha256 = $record.certificate.model_sha256
        run_configuration_sha256 = $record.certificate.run_configuration_sha256
    }
})
$standalone = @(foreach ($name in 'control-step','byte-step-3') {
    $certificate = $certificates[$name]
    foreach ($obligation in $certificate.obligations) {
        $stem = $obligation.kind.Substring(4)
        $base = "$root/$name-certificate/$stem"
        $verified = Run-Logged "$name-standalone-$stem" $checker @('--check-drat',"$base.cnf","$base.q3adrat",
            '--model-sha256',$certificate.model_sha256,'--query-kind',$obligation.kind)
        if ($verified.code -ne 0 -or $verified.text -cnotmatch 'Q3A_PROOF_CHECK ACCEPTED' -or
            (Hash "$base.cnf") -cne $obligation.query_sha256 -or (Hash "$base.q3adrat") -cne $obligation.proof_sha256) {
            throw "The independent checker rejected $name/$stem."
        }
        [ordered]@{case = $name; obligation = $obligation}
    }
})
if ($standalone.Count -ne 6) { throw 'The two independent proof groups must have six obligations.' }

$covers = @('c_first_word','c_second_word','c_unmapped','c_stall_and_retry')
foreach ($name in $covers) {
    $bundle = "$root/$name-bundle"
    $null = Prove-Status $name @('--timeout-ms','30000','--engine','bmc','--property',$name,
        '--frames','6','--bundle-dir',$bundle) 'COVERED'
    Verify-Witness $name $bundle
}

$faults = @(
    @{name='lost-high-byte'; fault=1; lane=3; property='p_lane_step'},
    @{name='invalid-address-okay'; fault=2; lane=0; property='p_control_step'},
    @{name='dropped-response'; fault=3; lane=0; property='p_response_hold'}
)
$mutations = @(foreach ($entry in $faults) {
    $name = $entry.name
    $bundle = "$root/$name-bundle"
    $point = (Lane $entry.lane) + @('--parameter','FAULT',[string]$entry.fault)
    $null = Prove-Status $name ($point + @('--timeout-ms','30000','--engine','bmc','--property',$entry.property,
        '--frames','3','--bundle-dir',$bundle)) 'BOUNDED_FAIL'
    Verify-Witness $name $bundle
    [ordered]@{case = $name; fault = $entry.fault; property = $entry.property; lane = $entry.lane}
})
foreach ($name in $files) {
    if ((Hash "$fixtureDir/$name") -cne $sourceHashes[$name]) { throw "Input changed during qualification: $name" }
}
if ((Hash $exe) -cne $exeHash -or (Hash $checker) -cne $checkerHash) { throw 'The tested executable changed.' }
[ordered]@{
    status = 'AXI_LITE_READ_SLICE_FUNCTIONALLY_QUALIFIED'
    prototype_scope = '32-bit read-channel fixture with one outstanding response'
    executable_sha256 = $exeHash
    checker_sha256 = $checkerHash
    inputs = $sourceHashes
    source_revalidated_proofs = $proofs
    standalone_obligations = $standalone
    source_replayed_cover_goals = $covers
    source_replayed_faults = $mutations
    phase2_acceptance = 'PENDING'
    phase3_release_acceptance = 'PENDING'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
"PASS: $($proofs.Count) source-revalidated proofs, $($standalone.Count) standalone checks, $($covers.Count) replayed covers, and $($mutations.Count) detected faults."

