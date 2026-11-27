#requires -Version 7.0
param([Parameter(Mandatory)][string]$Archive)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packager = Join-Path $repo 'scripts/package_windows.ps1'
$original = (Resolve-Path -LiteralPath $Archive).ProviderPath
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('q3a-package-regression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function Check-Mutation([string]$Name, [scriptblock]$Mutate, [string]$ExpectedError) {
    $copy = Join-Path $scratch "$Name.zip"
    Copy-Item -LiteralPath $original -Destination $copy
    $zip = [IO.Compression.ZipFile]::Open($copy, [IO.Compression.ZipArchiveMode]::Update)
    try { & $Mutate $zip } finally { $zip.Dispose() }
    try {
        & $packager -Archive $copy -VerifyOnly | Out-Null
    } catch {
        if ($_.Exception.Message -like $ExpectedError) { return }
        throw
    }
    throw "Verifier accepted mutation $Name."
}

try {
    $digest = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant()
    $verified = & $packager -Archive $original -VerifyOnly | ConvertFrom-Json
    if ($verified.status -cne 'INVENTORY_AND_HASHES_VERIFIED' -or $verified.sha256 -cne $digest) {
        throw 'Could not verify the original ZIP.'
    }

    Check-Mutation 'modified-content' {
        param($zip)
        $content = $zip.GetEntry('README.md').Open()
        try {
            $first = $content.ReadByte()
            $content.Position = 0
            $content.WriteByte([byte]($first -bxor 1))
        } finally { $content.Dispose() }
    } 'Package digest mismatch*'
    Check-Mutation 'duplicate-member' {
        param($zip)
        $extra = $zip.CreateEntry('README.md').Open()
        try { $extra.WriteByte(42) } finally { $extra.Dispose() }
    } 'Unexpected, unsafe, empty, or duplicate ZIP member.'
    Check-Mutation 'escaping-member' {
        param($zip)
        $extra = $zip.CreateEntry('../outside.txt').Open()
        try { $extra.WriteByte(42) } finally { $extra.Dispose() }
    } 'Unexpected, unsafe, empty, or duplicate ZIP member.'
    Check-Mutation 'symlink-member' {
        param($zip)
        $zip.GetEntry('README.md').ExternalAttributes = -1610612736
    } 'Unexpected, unsafe, empty, or duplicate ZIP member.'
    Check-Mutation 'missing-member' {
        param($zip)
        $zip.GetEntry('README.md').Delete()
    } 'Package is missing required members*'

    if ($verified.schema -ceq 'Q3AFORMAL-WINDOWS-PACKAGE-2') {
        Check-Mutation 'missing-batch-plan' {
            param($zip)
            $zip.GetEntry('prototype/batch-pipeline.q3b').Delete()
        } 'Package is missing required members*'
        Check-Mutation 'manifest-version-downgrade' {
            param($zip)
            $entry = $zip.GetEntry('package-manifest.json').Open()
            try {
                $reader = [IO.StreamReader]::new($entry, [Text.Encoding]::UTF8, $true, 4096, $true)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $bytes = [Text.Encoding]::UTF8.GetBytes(
                    $text.Replace('Q3AFORMAL-WINDOWS-PACKAGE-2', 'Q3AFORMAL-WINDOWS-PACKAGE-1'))
                $entry.Position = 0
                $entry.SetLength(0)
                $entry.Write($bytes, 0, $bytes.Length)
            } finally { $entry.Dispose() }
        } 'Package is missing required members*'
    }

    if ($verified.schema -ceq 'Q3AFORMAL-WINDOWS-PACKAGE-3') {
        Check-Mutation 'missing-four-state-manifest' {
            param($zip)
            $zip.GetEntry('prototype/four-state-cover.q3a').Delete()
        } 'Package is missing required members*'
        Check-Mutation 'missing-four-state-rtl' {
            param($zip)
            $zip.GetEntry('prototype/corpus/source-model-vectors/four_state_cover.sv').Delete()
        } 'Package is missing required members*'
        Check-Mutation 'missing-four-state-capability' {
            param($zip)
            $entry = $zip.GetEntry('package-manifest.json').Open()
            try {
                $reader = [IO.StreamReader]::new($entry, [Text.Encoding]::UTF8, $true, 4096, $true)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $bytes = [Text.Encoding]::UTF8.GetBytes($text.Replace('-DQ3A_ENABLE_DEVELOPMENT_FOUR_STATE', ''))
                $entry.Position = 0
                $entry.SetLength(0)
                $entry.Write($bytes, 0, $bytes.Length)
            } finally { $entry.Dispose() }
        } 'The four-state package roster requires the four-state build capability.'
    }

    if ($verified.channel -ceq 'development-preview') {
        Check-Mutation 'development-channel-downgrade' {
            param($zip)
            $entry = $zip.GetEntry('package-manifest.json').Open()
            try {
                $reader = [IO.StreamReader]::new($entry, [Text.Encoding]::UTF8, $true, 4096, $true)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $bytes = [Text.Encoding]::UTF8.GetBytes($text.Replace('"development-preview"', '"internal-candidate"'))
                $entry.Position = 0
                $entry.SetLength(0)
                $entry.Write($bytes, 0, $bytes.Length)
            } finally { $entry.Dispose() }
        } 'Package channel does not match the build configuration.'
    }

    if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
        throw 'Verification changed the original archive.'
    }
    "PASS: verified $($verified.files) payload hashes and rejected the altered $($verified.schema) archives."
} finally {
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ($resolved -eq $scratch -and (Split-Path -Leaf $scratch) -like 'q3a-package-regression-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
