# Build the Polyglance MSIX package using MakeAppx.
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$')]
    [string]$Version = "0.0.8",
    [ValidatePattern('^[0-9]+$')]
    [string]$BuildNumber = "1",
    [string]$SourceDirectory = "dist/windows",
    [string]$OutputDirectory = "dist/installer"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir
$manifestSource = Join-Path $rootDir "apps/windows/Polyglance.Package/Package.appxmanifest"
$imagesSource = Join-Path $rootDir "apps/windows/Polyglance.Package/Images"

$sourceDir = if ([IO.Path]::IsPathRooted($SourceDirectory)) {
    [IO.Path]::GetFullPath($SourceDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $rootDir $SourceDirectory))
}

$outputDir = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $rootDir $OutputDirectory))
}

if (-not (Test-Path (Join-Path $sourceDir "Polyglance.exe") -PathType Leaf)) {
    throw "Published Windows application not found in $sourceDir. Run build-windows-app.ps1 first."
}
if (-not (Test-Path $manifestSource -PathType Leaf)) {
    throw "Package manifest template not found: $manifestSource"
}

# Resolve 4-part numeric version: Major.Minor.Build.Revision
$numericVersion = ($Version -split '[-+]')[0]
$parts = $numericVersion -split '\.'
$major = if ($parts.Length -ge 1) { $parts[0] } else { "0" }
$minor = if ($parts.Length -ge 2) { $parts[1] } else { "0" }
$build = if ($parts.Length -ge 3) { $parts[2] } else { "0" }
$revision = $BuildNumber
$fourPartVersion = "$major.$minor.$build.$revision"

Write-Host "Configuring MSIX version: $fourPartVersion (from $Version-$BuildNumber)"

# Find MakeAppx.exe
$makeAppxCandidates = @()
$makeAppxCommand = Get-Command "makeappx.exe" -ErrorAction SilentlyContinue
if ($null -ne $makeAppxCommand) {
    $makeAppxCandidates += $makeAppxCommand.Source
}

$kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
if (Test-Path $kitsRoot) {
    Get-ChildItem -Path $kitsRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $x64Path = Join-Path $_.FullName "x64\makeappx.exe"
        if (Test-Path $x64Path -PathType Leaf) {
            $makeAppxCandidates += $x64Path
        }
    }
}

$makeAppx = $makeAppxCandidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
if (-not $makeAppx) {
    throw "makeappx.exe was not found. Please install the Windows 10/11 SDK or run in a developer prompt."
}

Write-Host "Using MakeAppx: $makeAppx"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$destinationMsix = Join-Path $outputDir "Polyglance-$Version-Windows-x64.msix"

$tempStagingDir = Join-Path ([IO.Path]::GetTempPath()) "Polyglance_MSIX_Staging_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempStagingDir -Force | Out-Null

try {
    Write-Host "Staging app files to $tempStagingDir..."
    Copy-Item -Path (Join-Path $sourceDir "*") -Destination $tempStagingDir -Recurse -Force

    # Copy package images
    $stagingImagesDir = Join-Path $tempStagingDir "Images"
    New-Item -ItemType Directory -Path $stagingImagesDir -Force | Out-Null
    if (Test-Path $imagesSource) {
        Copy-Item -Path (Join-Path $imagesSource "*") -Destination $stagingImagesDir -Recurse -Force
    }

    # Generate AppxManifest.xml with dynamic version
    $manifestXml = [xml](Get-Content -Path $manifestSource -Raw -Encoding UTF8)
    $manifestXml.Package.Identity.Version = $fourPartVersion
    $manifestXml.Save((Join-Path $tempStagingDir "AppxManifest.xml"))

    Write-Host "Packing MSIX package: $destinationMsix"
    & $makeAppx pack /d "$tempStagingDir" /p "$destinationMsix" /nv /o
    if ($LASTEXITCODE -ne 0) {
        throw "makeappx pack failed with exit code $LASTEXITCODE"
    }

    Write-Host "Successfully generated: $destinationMsix"
}
finally {
    if (Test-Path $tempStagingDir) {
        Remove-Item -Path $tempStagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
