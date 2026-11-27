$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$cases = @(
    @{ manifest = 'generate-for-count0.q3a'; count = 0 },
    @{ manifest = 'generate-for-count1.q3a'; count = 1 },
    @{ manifest = 'generate-for-count3.q3a'; count = 3 }
)

foreach ($case in $cases) {
    $manifest = Join-Path $prototypeRoot $case.manifest
    $output = @(& $sourcecheck --lower-project $manifest 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$($case.manifest) failed to lower:`n$($output -join "`n")" }
    $model = ($output -join "`n") | ConvertFrom-Json

    $countParameter = @($model.parameters | Where-Object { $_.name -eq 'COUNT' })
    if ($countParameter.Count -ne 1 -or [int]$countParameter[0].value -ne $case.count) {
        throw "Resolved COUNT differs from the expected value in $($case.manifest)."
    }
    $expectedNames = @()
    for ($index = 0; $index -lt $case.count; $index++) {
        $expectedNames += "g_items[$index].present"
    }
    $actualNames = @($model.signals | Where-Object { $_.name -match '^g_items\[\d+\]\.present$' } |
        Sort-Object name | ForEach-Object { $_.name })
    if (($actualNames -join ',') -ne ($expectedNames -join ',')) {
        throw "Generated scope names for COUNT=$($case.count) differ; expected '$($expectedNames -join ',')', got '$($actualNames -join ',')'."
    }
    foreach ($signalName in $expectedNames) {
        $signal = @($model.signals | Where-Object { $_.name -eq $signalName })
        if ($signal.Count -ne 1 -or $signal[0].role -ne 'internal' -or [int]$signal[0].width -ne 1) {
            throw "Generated scoped declaration '$signalName' has incorrect type/role."
        }
    }
    $equation = @($model.combinational_equations | Where-Object { $_.target -eq 'is_one' })
    if ($equation.Count -ne 1 -or $equation[0].source.line -ne 7) {
        throw "The is_one equation or its source mapping is missing in $($case.manifest)."
    }
    $property = @($model.properties | Where-Object { $_.name -eq 'p_count_is_one' })
    if ($property.Count -ne 1 -or $property[0].kind -ne 'assert' -or
        $property[0].clock -ne 'clk' -or $property[0].source.line -ne 18) {
        throw "Count property binding or source mapping is incorrect in $($case.manifest)."
    }

    $elaboration = @(& $sourcecheck --elaborate-project $manifest 2>&1)
    $expectedSummary = "generate for path=`"for@10`" selected=1 iterations=$($case.count)"
    if ($LASTEXITCODE -ne 0 -or $elaboration -notcontains $expectedSummary) {
        throw "Elaboration did not report the exact static iteration count for $($case.manifest): $($elaboration -join "`n")"
    }

    $proof = @(& $sourcecheck --bmc $manifest --property 'p_count_is_one' --frames 0 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        $proof -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
        $proof -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
        throw "Static count assertion did not pass nonvacuously for $($case.manifest): $($proof -join "`n")"
    }
}

$negativeManifest = Join-Path $prototypeRoot 'nonterminating-gen.q3a'
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$negative = @(& $sourcecheck --elaborate-project $negativeManifest 2>&1)
$negativeExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
$diagnostic = $negative -join "`n"
if ($negativeExitCode -ne 1 -or
    $diagnostic -notmatch 'nonterminating_generate_reject\.sv:5:9: generate-for update does not advance the genvar' -or
    $diagnostic -match '(?m)^Q3A_ELABORATED\b') {
    throw "A nonadvancing genvar update must reject before elaborated output:`n$diagnostic"
}

'PASS: COUNT=0/1/3 produce exact elaboration counts and stable scope names, each count assertion passes nonvacuously, and nonadvancing update rejects at source.'
