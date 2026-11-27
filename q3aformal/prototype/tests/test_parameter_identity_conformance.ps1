$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$sourcecheck = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$inputHashes = @{}
$sourceRelativePath = 'corpus/source-model-vectors/parameter_localparam_vectors.sv'
$sourceHash = (Get-FileHash -LiteralPath (Join-Path $prototypeRoot $sourceRelativePath) -Algorithm SHA256).Hash.ToLowerInvariant()

foreach ($case in @(
    @{ Manifest = 'lower-parameters.q3a'; Width = 4 },
    @{ Manifest = 'lower-parameters-width3.q3a'; Width = 3 },
    @{ Manifest = 'lower-parameters-width32.q3a'; Width = 32 }
)) {
    $manifest = Join-Path $prototypeRoot $case.Manifest
    $width = $case.Width
    $first = (& $sourcecheck --lower-project $manifest) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not lower $($case.Manifest)." }
    $second = (& $sourcecheck --lower-project $manifest) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $first -cne $second) {
        throw "Repeated lowering was not deterministic for $($case.Manifest)."
    }
    $model = $first | ConvertFrom-Json
    $identityLines = @('Q3A_INPUT_ID 1', 'P13:Q3A-P0-R0.9.1', 'T28:parameter_localparam_vectors')
    if ($width -ne 4) {
        $overrideValue = [string]$width
        $identityLines += @('A', 'N5:WIDTH', "V$($overrideValue.Length):$overrideValue")
    }
    $identityLines += @('S', "F$($sourceRelativePath.Length):$sourceRelativePath", "H64:$sourceHash", '')
    $identityBytes = [Text.Encoding]::UTF8.GetBytes(($identityLines -join "`n"))
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($identityBytes)).ToLowerInvariant()
    if ($model.semantic_profile -ne 'Q3A-P0-R0.9.1' -or
        $model.input_sha256 -cne $expectedHash -or
        $inputHashes.ContainsKey($model.input_sha256)) {
        throw "Invalid or repeated input fingerprint for $($case.Manifest)."
    }
    $inputHashes.Add($model.input_sha256, $width)

    $parameter = @($model.parameters | Where-Object { $_.name -eq 'WIDTH' })
    $localparam = @($model.parameters | Where-Object { $_.name -eq 'DOUBLE_WIDTH' })
    if ($model.parameters.Count -ne 2 -or
        $parameter.Count -ne 1 -or $parameter[0].kind -ne 'parameter' -or
        $parameter[0].value -ne $width -or $parameter[0].width -ne 32 -or
        !$parameter[0].signed -or $parameter[0].source.line -ne 2 -or
        $localparam.Count -ne 1 -or $localparam[0].kind -ne 'localparam' -or
        $localparam[0].value -ne (2 * $width) -or $localparam[0].width -ne 32 -or
        !$localparam[0].signed -or $localparam[0].source.line -ne 8) {
        throw "Incorrect resolved constant or source mapping for $($case.Manifest)."
    }

    $inputSignal = $model.signals | Where-Object { $_.name -eq 'data_in' }
    $outputSignal = $model.signals | Where-Object { $_.name -eq 'data_twice' }
    $concat = ($model.combinational_equations | Where-Object { $_.target -eq 'data_twice' }).expression
    $comparison = ($model.combinational_equations | Where-Object { $_.target -eq 'width_is_four' }).expression
    if ($inputSignal.width -ne $width -or $outputSignal.width -ne (2 * $width) -or
        $concat.kind -ne 'concatenation' -or $concat.width -ne (2 * $width) -or
        $concat.operands.Count -ne 2 -or
        @($concat.operands | Where-Object { $_.kind -ne 'signal' -or $_.value -ne 'data_in' -or $_.width -ne $width }).Count -ne 0 -or
        $comparison.value -ne '==' -or $comparison.width -ne 1 -or
        $comparison.operands.Count -ne 2 -or $comparison.operands[0].kind -ne 'constant' -or
        [long]$comparison.operands[0].value -ne $width -or [long]$comparison.operands[1].value -ne 4) {
        throw "Incorrect dependent width or equation for $($case.Manifest)."
    }
}

'PASS: WIDTH=3/4/32 produce deterministic, distinct model inputs with resolved localparams, packed widths, and expression constants.'
