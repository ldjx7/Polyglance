# Verify that the portable archive is both a current package and a compatible
# in-place update for Polyglance 0.0.4-beta.8 and earlier.
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDirectory = Split-Path -Parent $scriptDirectory
$archive = if ([IO.Path]::IsPathRooted($ArchivePath)) {
    [IO.Path]::GetFullPath($ArchivePath)
} else {
    [IO.Path]::GetFullPath((Join-Path $rootDirectory $ArchivePath))
}
if (-not (Test-Path $archive -PathType Leaf)) {
    throw "Portable update archive not found: $archive"
}

$extractDirectory = Join-Path ([IO.Path]::GetTempPath()) "Polyglance.PortableTest.$([Guid]::NewGuid().ToString('N'))"
try {
    Expand-Archive -Path $archive -DestinationPath $extractDirectory
    foreach ($requiredFile in @(
        "Polyglance.exe",
        "Polyglance.UI.exe",
        "Polyglance.dll",
        "Polyglance.deps.json",
        "Polyglance.runtimeconfig.json"
    )) {
        if (-not (Test-Path (Join-Path $extractDirectory $requiredFile) -PathType Leaf)) {
            throw "Portable update archive is missing $requiredFile."
        }
    }

    $currentHash = (Get-FileHash (Join-Path $extractDirectory "Polyglance.exe") -Algorithm SHA256).Hash
    $legacyHash = (Get-FileHash (Join-Path $extractDirectory "Polyglance.UI.exe") -Algorithm SHA256).Hash
    if ($currentHash -ne $legacyHash) {
        throw "The legacy compatibility apphost must be byte-identical to Polyglance.exe."
    }
}
finally {
    if (Test-Path $extractDirectory) {
        Remove-Item $extractDirectory -Recurse -Force
    }
}

Write-Host "Windows portable update compatibility test passed." -ForegroundColor Green
