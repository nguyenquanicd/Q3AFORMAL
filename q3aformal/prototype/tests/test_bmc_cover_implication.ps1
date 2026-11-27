$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-cover-implication.q3a'

foreach ($case in @(
    @{ Property = 'c_overlapped'; Frames = 0 },
    @{ Property = 'c_nonoverlapped'; Frames = 1 },
    @{ Property = 'c_sequence_antecedent'; Frames = 3 }
)) {
    $output = & $executable --bmc $manifest `
        --property $case.Property --frames $case.Frames
    if ($LASTEXITCODE -ne 0 -or
        -not ($output -contains 'Q3A_BMC_STATUS COVERED') -or
        -not ($output -contains 'Q3A_BMC_COVER_RESULT WITNESS_FOUND') -or
        -not ($output -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Implication cover failed or produced an invalid witness for $($case.Property):`n$($output -join "`n")"
    }
}

foreach ($case in @(
    @{ Property = 'c_overlapped_range'; Frames = 0 },
    @{ Property = 'c_nonoverlapped_range'; Frames = 1 }
)) {
    $output = @(& $executable --bmc $manifest --property $case.Property --frames $case.Frames)
    if ($LASTEXITCODE -ne 0 -or $output -notcontains 'Q3A_BMC_STATUS COVERED' -or
        $output -notcontains 'Q3A_BMC_COVER_SCOPE BOUNDED boundary_limited=yes' -or
        $output -notcontains "Q3A_BMC_COVER_WITNESS frame=$($case.Frames)" -or
        $output -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
        throw "A short completed path did not cover $($case.Property):`n$($output -join "`n")"
    }
}

$noCompletedPath = @(& $executable --bmc $manifest --property c_nonoverlapped_minimum_two --frames 1)
if ($LASTEXITCODE -ne 0 -or $noCompletedPath -notcontains 'Q3A_BMC_STATUS UNKNOWN' -or
    $noCompletedPath -notcontains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND') {
    throw "An unfinished minimum-length path counted as a hit:`n$($noCompletedPath -join "`n")"
}

$boundary = & $executable --bmc $manifest `
    --property c_nonoverlapped --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($boundary -contains 'Q3A_BMC_STATUS UNKNOWN') -or
    -not ($boundary -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND') -or
    -not ($boundary -contains 'Q3A_BMC_COVER_SCOPE BOUNDED boundary_limited=yes')) {
    throw "An incomplete non-overlapped implication cover must remain a bounded miss:`n$($boundary -join "`n")"
}

$wideRepeat = @(& $executable --bmc $manifest --property c_wide_repeat --frames 256)
$statistics = @($wideRepeat | Where-Object { $_ -match '^Q3A_BMC_STATS ' })
if ($LASTEXITCODE -ne 0 -or $wideRepeat -notcontains 'Q3A_BMC_STATUS COVERED' -or
    $wideRepeat -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or $statistics.Count -ne 1 -or
    !($statistics[0] -match '^Q3A_BMC_STATS variables=(\d+) clauses=(\d+)')) {
    throw "The wide repetition did not finish with checked evidence:`n$($wideRepeat -join "`n")"
}
if ([long]$Matches[1] -gt 40000 -or [long]$Matches[2] -gt 120000) {
    throw "Wide repetition rebuilt too many clauses for shared prefixes: $($statistics[0])"
}

$converged = @(& $executable --bmc $manifest --property c_converging_repeat_paths --frames 300)
if ($LASTEXITCODE -ne 0 -or $converged -notcontains 'Q3A_BMC_STATUS COVERED' -or
    $converged -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "Converging sequence paths exceeded the evaluation budget or changed the result:`n$($converged -join "`n")"
}

'PASS: completed cover matches replay, including a 256-sample repetition range and a 300-transition window with converging repetition paths.'
