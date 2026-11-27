param(
    [string]$Compiler = 'g++',
    [switch]$UseExistingBuild
)

$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$buildScript = Join-Path $prototypeRoot 'source\source_manager\build.ps1'
$manifest = Join-Path $prototypeRoot 'generated-bit-assignment.q3a'

if (!$UseExistingBuild) {
    & $buildScript -Compiler $Compiler
}
if ((!$UseExistingBuild -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $sourcecheck)) {
    throw 'Q3AFormal sourcecheck build failed.'
}

function Get-TirValue {
    param(
        [Parameter(Mandatory = $true)]$Expression,
        [Parameter(Mandatory = $true)][hashtable]$Inputs
    )

    switch ([string]$Expression.kind) {
        'signal' {
            if (-not $Inputs.ContainsKey([string]$Expression.value)) {
                throw "The T-IR expression references unexpected signal '$($Expression.value)'."
            }
            return [long]$Inputs[[string]$Expression.value]
        }
        'select' {
            if (@($Expression.operands).Count -ne 2) {
                throw "Expected a normalized select node, got $($Expression.kind)/$($Expression.value)."
            }
            $sourceValue = Get-TirValue -Expression $Expression.operands[0] -Inputs $Inputs
            $offset = [int]$Expression.operands[1].value
            if ([string]$Expression.value -eq 'bit') {
                return (($sourceValue -shr $offset) -band 1)
            }
            if ([string]$Expression.value -eq 'part') {
                $mask = (1L -shl [int]$Expression.width) - 1
                return (($sourceValue -shr $offset) -band $mask)
            }
            throw "Unexpected normalized select kind '$($Expression.value)'."
        }
        'concatenation' {
            $value = [long]0
            foreach ($operand in $Expression.operands) {
                $part = Get-TirValue -Expression $operand -Inputs $Inputs
                $value = ($value -shl [int]$operand.width) -bor $part
            }
            return $value
        }
        default {
            throw "Unexpected T-IR expression kind '$($Expression.kind)' in generated bit-select fixture."
        }
    }
}

$lowered = & $sourcecheck --lower-project $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Complete generated bit-select assignment set did not lower: $($lowered -join [Environment]::NewLine)"
}
$model = ($lowered -join [Environment]::NewLine) | ConvertFrom-Json
$expectedTargets = @{
    y_desc = 'reverse'
    y_asc = 'identity'
    y_part = 'identity'
    y_part_asc = 'identity'
    y_genpart = 'identity'
    child_y = 'reverse'
}
$equations = @{}
foreach ($target in $expectedTargets.Keys) {
    $matches = @($model.combinational_equations | Where-Object { $_.target -eq $target })
    if ($matches.Count -ne 1 -or [int]$matches[0].target_width -ne 4) {
        throw "Expected exactly one four-bit equation for '$target'; found $($matches.Count)."
    }
    $equations[$target] = $matches[0]
}

for ($sample = 0; $sample -lt 16; $sample++) {
    $reversed = 0
    for ($bit = 0; $bit -lt 4; $bit++) {
        if (($sample -band (1 -shl $bit)) -ne 0) {
            $reversed = $reversed -bor (1 -shl (3 - $bit))
        }
    }
    $inputs = @{
        a_desc = $sample
        a_asc = $sample
        a_part = $sample
        a_part_asc = $sample
        a_genpart = $sample
        child_a = $sample
    }
    foreach ($target in $expectedTargets.Keys) {
        $actual = Get-TirValue -Expression $equations[$target].expression -Inputs $inputs
        $expected = if ($expectedTargets[$target] -eq 'reverse') { $reversed } else { $sample }
        if ($actual -ne $expected) {
            throw "Equation '$target' mismatched sample 0x$('{0:X}' -f $sample): expected 0x$('{0:X}' -f $expected), got 0x$('{0:X}' -f $actual)."
        }
    }
}

$passOutput = & $sourcecheck --bmc $manifest --property p_all_targets_match --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($passOutput -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Bit/part-select relations did not pass their one-frame SAT query: $($passOutput -join [Environment]::NewLine)"
}
$counterexample = & $sourcecheck --bmc $manifest --property p_desc_not_identity --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($counterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($counterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "The intentionally false bit-select relation did not produce a replay-validated counterexample: $($counterexample -join [Environment]::NewLine)"
}

$negativeCases = @(
    @{ Top = 'generated_bit_assignment_partial'; Manifest = 'generated-bit-assignment-partial.q3a'; Diagnostic = 'do not cover every bit' },
    @{ Top = 'generated_bit_assignment_duplicate'; Manifest = 'generated-bit-assignment-duplicate.q3a'; Diagnostic = 'multiple continuous assignments drive packed bit offset' },
    @{ Top = 'generated_bit_assignment_whole_conflict'; Manifest = 'generated-bit-assignment-whole-conflict.q3a'; Diagnostic = 'multiple continuous assignments or module drivers drive' },
    @{ Top = 'generated_bit_assignment_dynamic'; Manifest = 'generated-bit-assignment-dynamic.q3a'; Diagnostic = 'must resolve to a compile-time constant' },
    @{ Top = 'generated_bit_assignment_out_of_range'; Manifest = 'generated-bit-assignment-range.q3a'; Diagnostic = 'outside the declared packed range' },
    @{ Top = 'generated_bit_assignment_part_select'; Manifest = 'generated-bit-assignment-part-select.q3a'; Diagnostic = 'part-select direction must match the declared packed range' }
)
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            foreach ($case in $negativeCases) {
                $negativeManifest = Join-Path $prototypeRoot $case.Manifest
                $output = & $sourcecheck --lower-project $negativeManifest 2>&1
                $message = $output -join [Environment]::NewLine
                if ($LASTEXITCODE -eq 0 -or $message -notmatch [regex]::Escape($case.Diagnostic)) {
                    throw "Expected '$($case.Top)' to fail with '$($case.Diagnostic)': $message"
                }
            }
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }

$instanceManifest = Join-Path $prototypeRoot 'generated-instance-output-bit.q3a'
$instanceLowered = & $sourcecheck --lower-project $instanceManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Generated child output bit-selects did not lower: $($instanceLowered -join [Environment]::NewLine)"
}
$instanceModel = ($instanceLowered -join [Environment]::NewLine) | ConvertFrom-Json
$instanceEquations = @($instanceModel.combinational_equations | Where-Object { $_.target -eq 'y' })
if ($instanceEquations.Count -ne 1 -or [int]$instanceEquations[0].target_width -ne 4) {
    throw "Expected one full-width equation for generated child output bus y; found $($instanceEquations.Count)."
}
$instancePass = & $sourcecheck --bmc $instanceManifest --property p_output_map --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($instancePass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Generated child output mapping did not pass its SAT query: $($instancePass -join [Environment]::NewLine)"
}
$ascendingInstanceManifest = Join-Path $prototypeRoot 'generated-instance-output-bit-ascending.q3a'
$ascendingInstanceLowered = & $sourcecheck --lower-project $ascendingInstanceManifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Ascending-range generated child output bit-selects did not lower: $($ascendingInstanceLowered -join [Environment]::NewLine)"
}
$ascendingInstanceModel = ($ascendingInstanceLowered -join [Environment]::NewLine) | ConvertFrom-Json
$ascendingInstanceEquations = @($ascendingInstanceModel.combinational_equations | Where-Object { $_.target -eq 'y' })
if ($ascendingInstanceEquations.Count -ne 1 -or [int]$ascendingInstanceEquations[0].target_width -ne 4) {
    throw "Expected one full-width equation for ascending generated child output bus y; found $($ascendingInstanceEquations.Count)."
}
$ascendingInstancePass = & $sourcecheck --bmc $ascendingInstanceManifest --property p_output_map_ascending --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($ascendingInstancePass -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Ascending-range generated child output mapping did not pass its SAT query: $($ascendingInstancePass -join [Environment]::NewLine)"
}
$instanceCounterexample = & $sourcecheck --bmc $instanceManifest --property p_output_wrong --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($instanceCounterexample -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($instanceCounterexample -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "The false generated child output relation did not produce a replay-validated counterexample: $($instanceCounterexample -join [Environment]::NewLine)"
}

$instanceNegativeCases = @(
    @{ Manifest = 'generated-instance-output-bit-partial.q3a'; Diagnostic = 'do not cover every bit' },
    @{ Manifest = 'generated-instance-output-bit-duplicate.q3a'; Diagnostic = 'multiple child output connections drive' },
    @{ Manifest = 'generated-instance-output-bit-whole-conflict.q3a'; Diagnostic = 'whole-signal driver conflicts with child output bit-select' },
    @{ Manifest = 'generated-instance-output-bit-dynamic.q3a'; Diagnostic = 'must resolve to a compile-time constant' },
    @{ Manifest = 'generated-instance-output-bit-range.q3a'; Diagnostic = 'outside the declared packed range' },
    @{ Manifest = 'generated-instance-output-part-select.q3a'; Diagnostic = 'exact widths are required' }
)
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            foreach ($case in $instanceNegativeCases) {
                $negativeManifest = Join-Path $prototypeRoot $case.Manifest
                $output = & $sourcecheck --lower-project $negativeManifest 2>&1
                $message = $output -join [Environment]::NewLine
                if ($LASTEXITCODE -eq 0 -or $message -notmatch [regex]::Escape($case.Diagnostic)) {
                    throw "Expected generated output connection case '$($case.Manifest)' to fail with '$($case.Diagnostic)': $message"
                }
            }
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }

'PASS: assignment and generated scalar child output bit-selects preserve ascending/descending ordering; SAT/replay checks the bus relations, and incomplete, duplicate, conflicting, dynamic, out-of-range, and unsupported connections fail closed.'
