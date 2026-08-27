# Build the per-user Polyglance Windows installer with Inno Setup.
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$')]
    [string]$Version = "0.0.0",
    [ValidatePattern('^[0-9]+$')]
    [string]$BuildNumber = "0",
    [string]$SourceDirectory = "dist/windows",
    [string]$OutputDirectory = "dist/installer"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir
$installerScript = Join-Path $rootDir "apps/windows/installer/Polyglance.iss"
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
$licenseFile = Join-Path $rootDir "LICENSE"
$setupIconFile = Join-Path $rootDir "apps/windows/src/Polyglance.UI/Resources/Polyglance.ico"

if (-not (Test-Path (Join-Path $sourceDir "Polyglance.exe") -PathType Leaf)) {
    throw "Published Windows application not found in $sourceDir. Run build-windows-app.ps1 first."
}
if (-not (Test-Path (Join-Path $sourceDir "polyglance_cabi.dll") -PathType Leaf)) {
    throw "Rust core DLL not found in $sourceDir. Run build-windows-app.ps1 first."
}
if (-not (Test-Path $installerScript -PathType Leaf)) {
    throw "Inno Setup script not found: $installerScript"
}

$isccCandidates = @()
$isccCommand = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
if ($null -ne $isccCommand) {
    $isccCandidates += $isccCommand.Source
}
if (${env:ProgramFiles(x86)}) {
    $isccCandidates += Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe"
}
if ($env:ProgramFiles) {
    $isccCandidates += Join-Path $env:ProgramFiles "Inno Setup 6/ISCC.exe"
}
if ($env:LOCALAPPDATA) {
    $isccCandidates += Join-Path $env:LOCALAPPDATA "Programs/Inno Setup 6/ISCC.exe"
}

$iscc = $isccCandidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
if (-not $iscc) {
    throw "ISCC.exe was not found. Install Inno Setup 6 or run this script on the windows-2025 GitHub runner."
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$numericVersion = ($Version -split '[-+]')[0]
$numericComponents = $numericVersion -split '\.'
$oversizedVersionComponents = @($numericComponents | Where-Object { [int64]$_ -gt 65535 })
if ([int64]$BuildNumber -gt 65535 -or $oversizedVersionComponents.Count -gt 0) {
    throw "Windows file-version components and BuildNumber must be between 0 and 65535."
}
$versionInfoVersion = "$numericVersion.$BuildNumber"
$outputBaseFilename = "Polyglance-$Version-Windows-x64-Setup"
$arguments = @(
    "/DMyAppVersion=$Version",
    "/DMyVersionInfoVersion=$versionInfoVersion",
    "/DMySourceDir=$sourceDir",
    "/DMyOutputDir=$outputDir",
    "/DMyOutputBaseFilename=$outputBaseFilename",
    "/DMyLicenseFile=$licenseFile",
    "/DMySetupIconFile=$setupIconFile",
    $installerScript
)

Write-Host "==> Compiling Windows installer with $iscc" -ForegroundColor Cyan
& $iscc @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
}

$installerPath = Join-Path $outputDir "$outputBaseFilename.exe"
if (-not (Test-Path $installerPath -PathType Leaf)) {
    throw "Installer output was not created: $installerPath"
}

Write-Host "==> Installer created: $installerPath" -ForegroundColor Green
