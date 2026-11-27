
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DevelopmentExecutable,
    [Parameter(Mandatory)][string]$StandardExecutable,
    [Parameter(Mandatory)][string]$TraceEvidence,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$dev = (Resolve-Path -LiteralPath $DevelopmentExecutable).Path
$standard = (Resolve-Path -LiteralPath $StandardExecutable).Path
$traceRoot = (Resolve-Path -LiteralPath $TraceEvidence).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Run([string]$Name, [string]$Executable, [string[]]$Arguments, [int]$Exit, [string]$Status) {
    $raw = @(& $Executable @Arguments 2> "$root/$Name.stderr.txt")
    $code = $LASTEXITCODE
    $raw | Set-Content -LiteralPath "$root/$Name.stdout.txt" -Encoding utf8NoBOM
    if ($code -ne $Exit) { throw "$Name exited $code. $raw $(Get-Content "$root/$Name.stderr.txt" -Raw)" }
    if ($Status -and ($raw | ConvertFrom-Json).status -cne $Status) {
        throw "$Name did not report $Status. $raw"
    }
}
$cases = @(
    @{name='read'; controls=@('re','ra')},
    @{name='both'; controls=@('re','ra','we','wa')},
    @{name='pending'; controls=@('re','ra')}
)
$rows = @(foreach ($case in $cases) {
    $name = $case.name
    $trace = "$traceRoot/$name.q3t"
    $project = "$traceRoot/$name.q3a"
    $traceHash = Hash $trace
    $session = "$root/$name session.json"
    $command = @('dev-gui-memory-range',$project,'--property','p_ok','--trace',$trace,'--max-cells','3',
        '--test-session',$session)
    Run $name $dev $command 0 DEBUG_SESSION_VERIFIED
    $state = Get-Content -LiteralPath $session -Raw | ConvertFrom-Json
    $group = @($state.groups | Where-Object { $_[0] -ceq 'Invalid access controls' })
    if ($state.key -cne "q3a-debug:$($traceHash):memory-range" -or $state.trace -cne "$name.q3t" -or
        $state.frame -ne 0 -or $state.markers.Count -ne 1 -or $state.markers[0] -ne 0 -or
        $group.Count -ne 1 -or ($group[0][1] -join ',') -cne ($case.controls -join ',') -or
        $state.source.file -cne "$name.sv" -or (Hash $trace) -cne $traceHash) {
        throw "Native session $name lost its cursor, source identity or invalid-access control signals."
    }
    [ordered]@{name=$name; trace_sha256=$traceHash; session_sha256=Hash $session; controls=$case.controls}
})
$rejectedSession = "$root/rejected session.json"
$bad = @('dev-gui-memory-range',"$traceRoot/read.q3a",'--property','p_other',
    '--trace',"$traceRoot/read.q3t",'--max-cells','3','--test-session',$rejectedSession)
Run different-property $dev $bad 2 REJECTED
Run foreign-trace $dev ($bad -creplace '^p_other$','p_ok' -creplace 'read\.q3t$','both.q3t') 2 REJECTED
Run standard-gate $standard ($bad -creplace '^p_other$','p_ok') 2 ''
if (Test-Path -LiteralPath $rejectedSession) { throw 'A rejected trace opened a native session.' }
[ordered]@{
    status = 'NATIVE_MEMORY_RANGE_VIEWER_QUALIFIED'
    executable_sha256 = Hash $dev
    standard_sha256 = Hash $standard
    native_sessions = $rows
    rejected_before_gui = @('different property','foreign trace','standard build')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/qualification.json" -Encoding utf8NoBOM
'PASS: native read, simultaneous-access and provisional memory-range sessions verified.'

