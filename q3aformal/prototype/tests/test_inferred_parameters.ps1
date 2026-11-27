$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tool = Join-Path $prototypeRoot 'bin/q3aformal-sourcecheck.exe'
$defaultManifest = Join-Path $prototypeRoot 'rtl-inferred-parameters.q3a'
$overrideManifest = Join-Path $prototypeRoot 'rtl-inferred-parameters-override.q3a'
$highUInt64 = [bigint]::Parse('9223372036854775808')
$maxUInt64 = [bigint]::Parse('18446744073709551615')

$hashes = foreach ($case in @(
    @{ Manifest = $defaultManifest; InferredWidth = 3; InferredSigned = $false },
    @{ Manifest = $overrideManifest; InferredWidth = 5; InferredSigned = $true }
)) {
    $text = @(& $tool --lower-project $case.Manifest)
    if ($LASTEXITCODE -ne 0) { throw "Could not lower $($case.Manifest)." }
    $model = ($text -join "`n") | ConvertFrom-Json
    $expected = @(
        @{ Name = 'WIDTH'; Value = 4; Width = $case.InferredWidth; Signed = $case.InferredSigned },
        @{ Name = 'HEADER_BASE'; Value = 4; Width = 3; Signed = $false; Kind = 'localparam' },
        @{ Name = 'BODY_ALIAS'; Value = 3; Width = 3; Signed = $false; Kind = 'localparam' },
        @{ Name = 'MODULAR'; Value = 1; Width = 3; Signed = $false },
        @{ Name = 'NEGATIVE'; Value = -1; Width = 3; Signed = $true },
        @{ Name = 'WIDER'; Value = 2147483648; Width = 33; Signed = $true },
        @{ Name = 'HIGH_U64'; Value = $highUInt64; Width = 64; Signed = $false },
        @{ Name = 'MAX_U64'; Value = $maxUInt64; Width = 64; Signed = $false },
        @{ Name = 'PACKED_BITS'; Value = 29; Width = 5; Signed = $false },
        @{ Name = 'PACKED_EXTENDED'; Value = 29; Width = 8; Signed = $false },
        @{ Name = 'PACKED_SUM'; Value = 1; Width = 4; Signed = $false },
        @{ Name = 'NEGATIVE_WIDE'; Value = -1; Width = 64; Signed = $true },
        @{ Name = 'MIN_SIGNED_WIDE'; Value = [long]::MinValue; Width = 64; Signed = $true },
        @{ Name = 'WRAP_U64'; Value = 0; Width = 64; Signed = $false },
        @{ Name = 'u_wide.VALUE'; Value = $maxUInt64; Width = 64; Signed = $false },
        @{ Name = 'u_default.LANES'; Value = 3; Width = 3; Signed = $false },
        @{ Name = 'u_default.LIMIT'; Value = 3; Width = 3; Signed = $false; Kind = 'parameter' },
        @{ Name = 'u_override.LANES'; Value = 4; Width = $case.InferredWidth; Signed = $case.InferredSigned },
        @{ Name = 'u_override.BASE'; Value = 4; Width = $case.InferredWidth; Signed = $case.InferredSigned; Kind = 'localparam' },
        @{ Name = 'u_override.LIMIT'; Value = 4; Width = $case.InferredWidth; Signed = $case.InferredSigned; Kind = 'parameter' },
        @{ Name = 'u_body_positional.BASE'; Value = 3; Width = 3; Signed = $false; Kind = 'localparam' },
        @{ Name = 'u_body_positional.LIMIT'; Value = 4; Width = 3; Signed = $false; Kind = 'parameter' },
        @{ Name = 'u_required.REQUIRED_WIDTH'; Value = 2; Width = 3; Signed = $false; Kind = 'localparam' },
        @{ Name = 'u_required.MASK'; Value = 3; Width = 2; Signed = $false }
    )
    foreach ($decl in $expected) {
        $parameter = @($model.parameters | Where-Object name -EQ $decl.Name)
        if ($parameter.Count -ne 1 -or $parameter[0].value -ne $decl.Value -or
            $parameter[0].width -ne $decl.Width -or $parameter[0].signed -ne $decl.Signed -or
            ($decl.Kind -and $parameter[0].kind -ne $decl.Kind)) {
            throw "Incorrect inferred constant $($decl.Name) in $($case.Manifest)."
        }
    }

    foreach ($property in @('p_expected', 'p_unsigned64')) {
        $output = @(& $tool --bmc $case.Manifest --property $property --frames 0)
        if ($LASTEXITCODE -ne 0 -or $output -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
            $output -notcontains 'Q3A_BMC_VACUITY NONVACUOUS') {
            throw "Explicit reference $property did not hold for $($case.Manifest).`n$($output -join "`n")"
        }
    }
    $model.input_sha256
}
if (@($hashes | Select-Object -Unique).Count -ne 2) {
    throw 'The override changed the inferred type without changing the input identity.'
}

$failure = @(& $tool --bmc $defaultManifest --property p_wrong --frames 0)
if ($LASTEXITCODE -ne 0 -or $failure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $failure -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "The nonwrapping reference must produce a replayed failure.`n$($failure -join "`n")"
}

foreach ($invalid in @(
    @{ File = 'rtl-inferred-parameters-local-override.q3a'; Message = 'override names no parameter.*BODY_ALIAS' },
    @{ File = 'rtl-inferred-parameters-concat-width-reject.q3a'; Message = 'constant concatenation width exceeds the 64-bit implementation limit' },
    @{ File = 'rtl-inferred-parameters-concat-unsized-reject.q3a'; Message = 'unsized decimal concatenation member requires an explicit width' }
)) {
    $rejection = @(& $tool --lower-project (Join-Path $prototypeRoot $invalid.File) 2>&1)
    if ($LASTEXITCODE -ne 1 -or !(($rejection -join "`n") -match $invalid.Message)) {
        throw "Expected source rejection for $($invalid.File).`n$($rejection -join "`n")"
    }
}

$binRoot = Join-Path $prototypeRoot 'bin'
$bundle = Join-Path $binRoot ('q3a-u64-replay-' + [guid]::NewGuid().ToString('N'))
try {
    $unsignedFailure = @(& $tool --bmc $defaultManifest --property p_wrong_unsigned64 --frames 0 --bundle-dir $bundle)
    if ($LASTEXITCODE -ne 0 -or $unsignedFailure -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
        $unsignedFailure -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
        !($unsignedFailure -match 'name=wide_value width=64 value=0xffffffffffffffff$')) {
        throw "The unsigned 64-bit witness did not preserve its exact bits.`n$($unsignedFailure -join "`n")"
    }
    $reopened = @(& $tool --verify-bundle $bundle)
    if ($LASTEXITCODE -ne 0 -or $reopened -notcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        $reopened -notcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        !($reopened -match '^Q3A_BUNDLE_TRACE_REPLAY VALIDATED ')) {
        throw "The unsigned 64-bit bundle did not revalidate.`n$($reopened -join "`n")"
    }
} finally {
    if (Test-Path -LiteralPath $bundle) {
        $resolved = (Resolve-Path -LiteralPath $bundle).ProviderPath
        $binPrefix = [IO.Path]::GetFullPath($binRoot).TrimEnd('\') + '\'
        if (!$resolved.StartsWith($binPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^q3a-u64-replay-[0-9a-f]{32}$') {
            throw "Invalid test cleanup path $resolved."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

'PASS: inferred constants, nested packed concatenations and unsigned 64-bit values remain exact in model JSON, bounded queries, replay and reopened bundles. Invalid concatenations reject.'
