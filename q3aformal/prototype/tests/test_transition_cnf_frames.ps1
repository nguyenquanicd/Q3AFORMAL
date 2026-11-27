$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'lower-multi-process.q3a'
$cnfPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-transition-frame-' + [guid]::NewGuid().ToString('N') + '.cnf')

try {
    $cnfText = & $executable --transition-cnf $manifest --frames 1
    if ($LASTEXITCODE -ne 0) {
        throw "Transition-CNF command must encode one frame edge:`n$($cnfText -join "`n")"
    }
    $cnfText | Set-Content -LiteralPath $cnfPath -Encoding Ascii

    $signalVariables = @{}
    foreach ($line in $cnfText) {
        if ($line -match '^c q3a_signal frame=(\d+) name=([^ ]+) bit=(\d+) var=(\d+)$') {
            $signalVariables["$($matches[1])|$($matches[2])|$($matches[3])"] =
                [int]$matches[4]
        }
    }

    function Signal-Literal([int]$frame, [string]$name, [bool]$value) {
        $key = "$frame|$name|0"
        if (-not $signalVariables.ContainsKey($key)) {
            throw "CNF output is missing signal mapping for frame=$frame name=$name"
        }
        $variable = [int]$signalVariables[$key]
        return $(if ($value) { $variable } else { -$variable })
    }

    function Solve-With([int[]]$assumptions) {
        $arguments = @('--sat-dimacs', $cnfPath)
        foreach ($literal in $assumptions) {
            $arguments += @('--assume', [string]$literal)
        }
        $output = & $executable @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "SAT query returned exit ${LASTEXITCODE}:`n$($output -join "`n")"
        }
        $statusLine = @($output | Where-Object { $_ -match '^Q3A_SAT_STATUS ' })[0]
        if ($null -eq $statusLine) { throw 'SAT query output lacks Q3A_SAT_STATUS' }
        return ($statusLine -replace '^Q3A_SAT_STATUS ', '')
    }

    $legal = @(
        (Signal-Literal 0 'rst' $false),
        (Signal-Literal 0 'new_a' $true),
        (Signal-Literal 0 'a_q' $false),
        (Signal-Literal 0 'b_q' $true),
        (Signal-Literal 1 'a_q' $true),
        (Signal-Literal 1 'b_q' $false)
    )
    if ((Solve-With $legal) -ne 'SAT') {
        throw 'The valid simultaneous pre-edge transition must be SAT'
    }

    $wrongBNext = $legal[0..4] + (Signal-Literal 1 'b_q' $true)
    if ((Solve-With $wrongBNext) -ne 'UNSAT') {
        throw 'b_q next state must use the old a_q value from frame 0'
    }

    $reset = @(
        (Signal-Literal 0 'rst' $true),
        (Signal-Literal 0 'new_a' $true),
        (Signal-Literal 0 'a_q' $true),
        (Signal-Literal 0 'b_q' $true),
        (Signal-Literal 1 'a_q' $false),
        (Signal-Literal 1 'b_q' $false)
    )
    if ((Solve-With $reset) -ne 'SAT') {
        throw 'Synchronous reset must set both next-state values to zero'
    }
    $wrongResetA = $reset[0..4] + (Signal-Literal 1 'a_q' $true)
    if ((Solve-With $wrongResetA) -ne 'UNSAT') {
        throw 'Synchronous reset must override the a_q next-state assignment'
    }

    $handshakeManifest = Join-Path $prototypeRoot 'lower-handshake1.q3a'
    $handshakeCnF = & $executable --transition-cnf $handshakeManifest --frames 1
    if ($LASTEXITCODE -ne 0) {
        throw "Handshake transition model should encode combinational and history logic:`n$($handshakeCnF -join "`n")"
    }
    $handshakeCnF | Set-Content -LiteralPath $cnfPath -Encoding Ascii
    $signalVariables.Clear()
    foreach ($line in $handshakeCnF) {
        if ($line -match '^c q3a_signal frame=(\d+) name=([^ ]+) bit=(\d+) var=(\d+)$') {
            $signalVariables["$($matches[1])|$($matches[2])|$($matches[3])"] =
                [int]$matches[4]
        }
    }

    $combinationalWrong = @(
        (Signal-Literal 0 'full' $true),
        (Signal-Literal 0 'out_ready' $false),
        (Signal-Literal 0 'in_ready' $true)
    )
    if ((Solve-With $combinationalWrong) -ne 'UNSAT') {
        throw 'The combinational in_ready equation must hold in every sample frame'
    }

    $handshakeTir = & $executable --lower-project $handshakeManifest | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Handshake T-IR should lower for history-state check' }
    foreach ($guardSignal in $handshakeTir.history_guards[0].state_chain) {
        if ((Solve-With @((Signal-Literal 0 $guardSignal $true))) -ne 'UNSAT') {
            throw "Generated history-valid state '$guardSignal' must start false"
        }
    }

    'PASS: transition CNF preserves simultaneous state updates, reset priority, combinational equations, and false-initialized $past validity.'
} finally {
    if (Test-Path -LiteralPath $cnfPath) {
        Remove-Item -LiteralPath $cnfPath -Force
    }
}
