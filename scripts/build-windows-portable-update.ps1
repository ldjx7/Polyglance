# Package the Windows portable/update archive.
#
# Polyglance 0.0.4-beta.8 and earlier restart Polyglance.UI.exe after an
# in-place update. Keep a byte-identical compatibility apphost in the archive
# so those versions can cross the beta.9 executable rename safely.
param(
    [string]$SourceDirectory = "dist/windows",
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir
$sourceDir = if ([IO.Path]::IsPathRooted($SourceDirectory)) {
    [IO.Path]::GetFullPath($SourceDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $rootDir $SourceDirectory))
}
$archivePath = if ([IO.Path]::IsPathRooted($DestinationPath)) {
    [IO.Path]::GetFullPath($DestinationPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $rootDir $DestinationPath))
}

$launcher = Join-Path $sourceDir "Polyglance.exe"
$assembly = Join-Path $sourceDir "Polyglance.dll"
if (-not (Test-Path $launcher -PathType Leaf) -or -not (Test-Path $assembly -PathType Leaf)) {
    throw "Published Windows application is incomplete in $sourceDir."
}

$archiveDirectory = Split-Path -Parent $archivePath
New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
if (Test-Path $archivePath) {
    Remove-Item $archivePath -Force
}

$stageDirectory = Join-Path ([IO.Path]::GetTempPath()) "Polyglance.Portable.$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $stageDirectory -Force | Out-Null
    Copy-Item (Join-Path $sourceDir "*") -Destination $stageDirectory -Recurse -Force
    Copy-Item $launcher -Destination (Join-Path $stageDirectory "Polyglance.UI.exe") -Force
    Compress-Archive -Path (Join-Path $stageDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal
}
finally {
    if (Test-Path $stageDirectory) {
        Remove-Item $stageDirectory -Recurse -Force
    }
}

Write-Host "==> Portable update archive created: $archivePath" -ForegroundColor Green
