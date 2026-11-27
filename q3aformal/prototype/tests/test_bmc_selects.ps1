$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-selects.q3a'

function Get-TirValue {
    param([Parameter(Mandatory = $true)]$Expression, [Parameter(Mandatory = $true)][hashtable]$Inputs)

    switch ([string]$Expression.kind) {
        'signal' { return [long]$Inputs[[string]$Expression.value] }
        'constant' { return [long]$Expression.value }
        'select' {
            $sourceValue = Get-TirValue -Expression $Expression.operands[0] -Inputs $Inputs
            $offset = [int](Get-TirValue -Expression $Expression.operands[1] -Inputs $Inputs)
            if ([string]$Expression.value -eq 'bit') { return (($sourceValue -shr $offset) -band 1) }
            if ([string]$Expression.value -eq 'part') {
                $mask = (1L -shl [int]$Expression.width) - 1
                return (($sourceValue -shr $offset) -band $mask)
            }
            throw "Unexpected T-IR select kind '$($Expression.value)'."
        }
        default { throw "Unexpected T-IR expression kind '$($Expression.kind)' in the independent packed-index oracle." }
    }
}

$lowered = & $executable --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) { throw "Select source did not lower: $($lowered -join "`n")" }
$model = ($lowered -join "`n") | ConvertFrom-Json
$expectedSelections = @{
    down_bit7 = @{ width = 1; line = 21; kind = 'bit'; offset = 7; input = 'down_vector'; reference_offset = 7; slice_width = 1 }
    down_bit0 = @{ width = 1; line = 22; kind = 'bit'; offset = 0; input = 'down_vector'; reference_offset = 0; slice_width = 1 }
    down_low = @{ width = 4; line = 23; kind = 'part'; offset = 0; input = 'down_vector'; reference_offset = 0; slice_width = 4 }
    down_high = @{ width = 4; line = 24; kind = 'part'; offset = 4; input = 'down_vector'; reference_offset = 4; slice_width = 4 }
    up_bit0 = @{ width = 1; line = 25; kind = 'bit'; offset = 7; input = 'up_vector'; reference_offset = 7; slice_width = 1 }
    up_bit7 = @{ width = 1; line = 26; kind = 'bit'; offset = 0; input = 'up_vector'; reference_offset = 0; slice_width = 1 }
    up_first_half = @{ width = 4; line = 27; kind = 'part'; offset = 4; input = 'up_vector'; reference_offset = 4; slice_width = 4 }
    up_second_half = @{ width = 4; line = 28; kind = 'part'; offset = 0; input = 'up_vector'; reference_offset = 0; slice_width = 4 }
    down_constant_expression_half = @{ width = 4; line = 29; kind = 'part'; offset = 0; input = 'down_vector'; reference_offset = 0; slice_width = 4 }
}
foreach ($target in $expectedSelections.Keys) {
    $expected = $expectedSelections[$target]
    $equations = @($model.combinational_equations | Where-Object { $_.target -eq $target })
    if ($equations.Count -ne 1 -or [int]$equations[0].target_width -ne $expected.width -or
        [int]$equations[0].source.line -ne $expected.line -or
        [string]$equations[0].expression.kind -ne 'select' -or
        [string]$equations[0].expression.value -ne $expected.kind -or
        [int]$equations[0].expression.operands[1].value -ne $expected.offset -or
        [string]$equations[0].expression.operands[0].value -ne $expected.input) {
        throw "T-IR select structure, normalized packed offset, or source mapping is wrong for '$target'."
    }
    $mask = (1L -shl $expected.slice_width) - 1
    for ($sample = 0; $sample -lt 256; $sample++) {
        $inputs = @{}
        $inputs[[string]$expected.input] = $sample
        $actual = Get-TirValue -Expression $equations[0].expression -Inputs $inputs
        $reference = ($sample -shr $expected.reference_offset) -band $mask
        if ($actual -ne $reference) {
            throw "Independent numeric packed-index oracle mismatch for '$target', input=0x$('{0:X2}' -f $sample): expected 0x$('{0:X}' -f $reference), got 0x$('{0:X}' -f $actual)."
        }
    }
}

foreach ($propertyName in @(
    'p_down_bit7_false',
    'p_down_low_false',
    'p_down_high_false',
    'p_up_bit0_false',
    'p_up_bit7_false',
    'p_up_first_half_false',
    'p_up_second_half_false',
    'p_down_constant_expression_half_false'
)) {
    $output = & $executable --bmc $manifest --property $propertyName --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($output -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
        -not ($output -contains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Static select BMC witness failed SAT or independent replay for ${propertyName}:`n$($output -join "`n")"
    }
}

foreach ($propertyName in @(
    'p_map_down_bit7',
    'p_map_down_bit0',
    'p_map_down_low',
    'p_map_down_high',
    'p_map_up_bit0',
    'p_map_up_bit7',
    'p_map_up_first_half',
    'p_map_up_second_half'
)) {
    $output = & $executable --bmc $manifest --property $propertyName --frames 0
    if ($LASTEXITCODE -ne 0 -or
        -not ($output -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
        -not ($output -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
        throw "Independent packed-index mapping oracle failed or was vacuous for ${propertyName}:`n$($output -join "`n")"
    }
}

foreach ($negativeCase in @(
    @{ Manifest = 'lower-out-of-range-select.q3a'; Diagnostic = 'outside the declared packed range'; SourcePattern = 'out_of_range_select_reject\.sv:\d+:\d+:' },
    @{ Manifest = 'lower-dynamic-select.q3a'; Diagnostic = 'constant expression'; SourcePattern = 'dynamic_select_reject\.sv:\d+:\d+:' },
    @{ Manifest = 'lower-reversed-part-select.q3a'; Diagnostic = 'direction must match'; SourcePattern = 'reversed_part_select_reject\.sv:\d+:\d+:' }
)) {
    $negativeManifest = Join-Path $prototypeRoot $negativeCase.Manifest
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $negativeOutput = & $executable --lower-project $negativeManifest 2>&1
    $negativeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    $negativeMessage = $negativeOutput -join "`n"
    if ($negativeExitCode -eq 0 -or
        -not $negativeMessage.Contains($negativeCase.Diagnostic) -or
        $negativeMessage -notmatch $negativeCase.SourcePattern -or
        $negativeMessage -match 'Q3A_BMC_STATUS') {
        throw "Unsupported select was not rejected with its expected diagnostic for $($negativeCase.Manifest):`n$($negativeOutput -join "`n")"
    }
}

'PASS: descending and ascending RTL selects replay correctly with independent MSB/LSB mapping checks; out-of-range, reversed-direction, and dynamic selects reject.'
