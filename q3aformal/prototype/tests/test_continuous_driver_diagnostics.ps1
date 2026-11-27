$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'

function Assert-DriverReject {
    param(
        [Parameter(Mandatory = $true)][string]$Manifest,
        [Parameter(Mandatory = $true)][string]$Diagnostic,
        [Parameter(Mandatory = $true)][string[]]$SourceSpans
    )

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $sourcecheck '--lower-project' (Join-Path $prototypeRoot $Manifest) 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $message = $output -join "`n"
    if ($exitCode -ne 1 -or $message -notmatch [regex]::Escape($Diagnostic) -or
        $message -match '(?m)^Q3A_(?:BMC|INDUCTION|SAT)_STATUS\b') {
        throw "Expected '$Manifest' to reject before proof with '$Diagnostic':`n$message"
    }
    foreach ($span in $SourceSpans) {
        if ($message -notmatch [regex]::Escape($span)) {
            throw "Expected source span '$span' in '$Manifest' diagnostic:`n$message"
        }
    }
}

$positive = @(& $sourcecheck '--lower-project' (Join-Path $prototypeRoot 'rtl-single-driver.q3a') 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Single-driver continuous assignment did not lower:`n$($positive -join "`n")"
}
$tir = ($positive -join "`n") | ConvertFrom-Json
$equations = @($tir.combinational_equations | Where-Object target -eq 'y')
if ($equations.Count -ne 1 -or $equations[0].target_width -ne 4 -or
    $equations[0].expression.kind -ne 'signal' -or
    $equations[0].expression.value -ne 'a' -or
    $equations[0].expression.width -ne 4) {
    throw 'The positive vector must lower one exact-width equation y = a.'
}

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$multiple = @(& $sourcecheck '--lower-project' (Join-Path $prototypeRoot 'reject-multiple-driver.q3a') 2>&1)
$multipleCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
$multipleText = $multiple -join "`n"
if ($multipleCode -ne 1 -or
    $multipleText -notmatch 'multiple continuous assignments or module drivers drive ''y''' -or
    $multipleText -notmatch 'multiple_driver_reject\.sv:6:5' -or
    $multipleText -notmatch 'multiple_driver_reject\.sv:7:5' -or
    $multipleText -match '(?m)^Q3A_(?:BMC|INDUCTION|SAT)_STATUS\b') {
    throw "Duplicate continuous drivers must be rejected before proof with both driver spans:`n$multipleText"
}

$resizeManifest = Join-Path $prototypeRoot 'continuous-assignment-resize.q3a'
$resizeOutput = @(& $sourcecheck '--lower-project' $resizeManifest 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "A legal continuous assignment requiring truncation did not lower:`n$($resizeOutput -join "`n")"
}
$resizeTir = ($resizeOutput -join "`n") | ConvertFrom-Json
$resizeEquation = @($resizeTir.combinational_equations | Where-Object target -eq 'y')
if ($resizeEquation.Count -ne 1 -or $resizeEquation[0].target_width -ne 4 -or
    $resizeEquation[0].source.line -ne 5 -or
    $resizeEquation[0].expression.kind -ne 'assignment_resize' -or
    $resizeEquation[0].expression.width -ne 4 -or
    $resizeEquation[0].expression.operands[0].width -ne 8) {
    throw 'Sized-literal assignment must preserve its 8-bit source and explicit 4-bit truncation in T-IR.'
}
$resizePass = & $sourcecheck '--bmc' $resizeManifest '--property' 'p_assignment_truncation' '--frames' 0
if ($LASTEXITCODE -ne 0 -or
    $resizePass -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $resizePass -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
    throw "Assignment-context truncation must pass its nonvacuous source property:`n$($resizePass -join "`n")"
}

Assert-DriverReject -Manifest 'reject-multiple-process-driver.q3a' `
    -Diagnostic "multiple processes drive signal 'y'" `
    -SourceSpans @('multiple_process_driver_reject.sv:7:5',
                   'multiple_process_driver_reject.sv:10:5')
Assert-DriverReject -Manifest 'reject-multiple-sequential-driver.q3a' `
    -Diagnostic "multiple processes drive state signal 'y'" `
    -SourceSpans @('multiple_sequential_driver_reject.sv:8:5',
                   'multiple_sequential_driver_reject.sv:11:5')
Assert-DriverReject -Manifest 'reject-continuous-comb-driver.q3a' `
    -Diagnostic "continuous assignment conflicts with always_comb process for 'y'" `
    -SourceSpans @('continuous_comb_driver_reject.sv:6:5',
                   'continuous_comb_driver_reject.sv:8:1')
Assert-DriverReject -Manifest 'reject-continuous-sequential-driver.q3a' `
    -Diagnostic "continuous assignment conflicts with a sequential driver for 'y'" `
    -SourceSpans @('continuous_sequential_driver_reject.sv:7:5',
                   'continuous_sequential_driver_reject.sv:9:1')
Assert-DriverReject -Manifest 'reject-selected-duplicate-driver.q3a' `
    -Diagnostic "multiple continuous assignments drive packed bit offset 1 of 'y'" `
    -SourceSpans @('selected_duplicate_driver_reject.sv:7:5',
                   'selected_duplicate_driver_reject.sv:8:5')

Write-Output 'PASS: RTL-019 checks exact-width continuous lowering, legal assignment-context truncation in T-IR and BMC, and duplicate continuous/procedural driver rejection with both source spans.'
