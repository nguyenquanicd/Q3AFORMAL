#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
& "$PSScriptRoot/test_sva_liveness.ps1" -ExecutablePath $exe -OutputDirectory "$root/sva"
& "$PSScriptRoot/test_liveness_evidence.ps1" -ExecutablePath $exe -OutputDirectory "$root/direct"
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Json($Label, [int]$Code, [string[]]$Arguments) {
    $output = @(& $exe @Arguments 2> "$root/$Label.stderr.txt")
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath "$root/$Label.json" -Encoding utf8NoBOM
    if ($exitCode -ne $Code) { throw "$Label failed with $exitCode. $output $(Get-Content "$root/$Label.stderr.txt" -Raw)" }
    $output | ConvertFrom-Json
}

function Read-Packed($Layout, [int]$Packed, [string]$Name) {
    foreach ($value in $Layout) {
        if ($value.name -ceq $Name) { return $Packed -band ((1 -shl $value.width) - 1) }
        $Packed = $Packed -shr $value.width
    }
    throw "Missing packed signal: $Name"
}

function Check-Vcd($Label, $Project, $Evidence, [string[]]$Query, [bool]$Named, $Status) {
    $file = "$root/$Label.vcd"
    $verify = Invoke-Json "$Label-verify" 0 (@('dev-verify-liveness',$Project,'--evidence',$Evidence,'--vcd',$file) + $Query)
    if ($verify.status -cne $Status -or !$verify.evidence_revalidated -or $verify.vcd_sha256 -cne (Hash $file)) {
        throw "$Label VCD does not match verification status or output digest."
    }
    $trace = Invoke-Json "$Label-roundtrip" 0 @('trace','import-vcd',$file,'--q3a-roundtrip')
    if ($trace.provenance -cne 'q3a-roundtrip' -or $trace.samples.Count -ne $verify.path.Count -or
        $trace.four_state -or $trace.formal_evidence -or @($trace.signals | Where-Object type -CEQ 'event').Count -ne 1) {
        throw "$Label round-trip changed trace structure."
    }
    $diag = @{}
    $rtl = @{}
    foreach ($signal in $trace.signals) {
        if ($signal.scope[-1] -ceq '__q3a_liveness') { $diag[$signal.name] = [int]$signal.id }
        elseif ($signal.scope.Count -eq 1) { $rtl[$signal.name] = [int]$signal.id }
    }
    $last = $verify.path.Count - 1
    $loop = $verify.loop_start
    if ($diag.Count -ne 6 -or $loop -ge $last) { throw 'Missing liveness signals or closing sample.' }
    for ($index = 0; $index -le $last; ++$index) {
        $actual = @{}
        foreach ($change in $trace.samples[$index].changes) { $actual[[int]$change[0]] = [int]$change[1] }
        $sample = $verify.path[$index]
        if ($Named) {
            $request = Read-Packed $verify.input_layout $sample.input req
            $enable = Read-Packed $verify.input_layout $sample.input enable
            $expected = [int]($request -and $enable)
            $response = $expected
            if ($actual[$rtl.req] -ne $request -or $actual[$rtl.enable] -ne $enable) { throw "Named RTL input changed at $index." }
        } else {
            $request = Read-Packed $verify.input_layout $sample.input request
            $grant = Read-Packed $verify.input_layout $sample.input grant
            $pending = Read-Packed $verify.state_layout $sample.state pending
            $expected = $request
            $response = [int](($pending -or $request) -and $grant)
            if ($actual[$rtl.response] -ne $response -or $actual[$rtl.pending] -ne $pending) {
                throw "Direct RTL waveform changed at $index."
            }
        }
        if ([int]$trace.samples[$index].timestamp -ne $index -or
            $actual[$diag.request] -ne $expected -or $actual[$diag.response] -ne $response -or
            $actual[$diag.outstanding] -ne [int]$sample.waiting -or
            $actual[$diag.loop_start] -ne [int]($index -eq $loop) -or
            $actual[$diag.loop_active] -ne [int]($index -ge $loop) -or
            $actual[$diag.loop_close] -ne [int]($index -eq $last)) {
            throw "Incorrect diagnostic signal at $Label sample $index."
        }
    }
    [ordered]@{name=$Label; samples=$trace.samples.Count; loop_start=$loop; sha256=Hash $file}
}

$rtlQuery = @('--request','request','--response','response')
$waves = @(
    Check-Vcd named "$root/sva/live.q3a" "$root/sva/strict.q3live" @('--property','p_next_fail') $true VIOLATION
    Check-Vcd direct "$root/direct/source/demo.q3a" "$root/direct/bad.q3live" $rtlQuery $false VIOLATION
    Check-Vcd fair "$root/direct/source/demo.q3a" "$root/direct/valid.q3live" ($rtlQuery + @('--justice','grant')) $false NO_VIOLATION
)
$prefix = @('dev-verify-liveness',"$root/direct/source/demo.q3a",'--evidence',"$root/direct/bad.q3live")
$occupied = "$root/direct.vcd"
$oldHash = Hash $occupied
$null = Invoke-Json occupied 2 ($prefix + $rtlQuery + @('--vcd',$occupied))
if ((Hash $occupied) -cne $oldHash) { throw 'A pre-existing waveform was replaced.' }
$bad = "$root/invalid.vcd"
$null = Invoke-Json no-fair 2 (@('dev-verify-liveness',"$root/direct/source/forbid.q3a",
    '--evidence',"$root/direct/no-fair.q3live",'--justice','grant','--vcd',$bad) + $rtlQuery)
$null = Invoke-Json wrong-query 2 ($prefix + $rtlQuery + @('--justice','grant','--vcd',$bad))
$null = Invoke-Json early-export 2 (@('dev-check-liveness',"$root/direct/source/demo.q3a",'--vcd',$bad) + $rtlQuery)
if ((Test-Path -LiteralPath $bad) -or @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Filter '.q3a-live-*').Count) {
    throw 'A rejected export published or staged an artifact.'
}
$viewer = @(& $exe trace view-vcd "$root/named.vcd")
if ($LASTEXITCODE -ne 0 -or ($viewer -join "`n") -notmatch 'loop_start') { throw 'Waveform viewer lacked loop diagnostics.' }
$viewer | Set-Content -LiteralPath "$root/named.html" -Encoding utf8NoBOM

[ordered]@{
    status = 'LIVENESS_VCD_EXPORT_QUALIFIED'
    executable_sha256 = Hash $exe
    waveforms = $waves
    rejected_exports = 4
    viewer_html_sha256 = Hash "$root/named.html"
    named_suite_sha256 = Hash "$root/sva/qualification.json"
    evidence_suite_sha256 = Hash "$root/direct/qualification.json"
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: three verified liveness VCD round trips, four rejected exports and a viewer artifact.'
