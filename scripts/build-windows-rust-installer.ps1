param(
    [string]$Version = "0.1.4",
    [string]$BuildNumber = "0",
    [string]$SourceDirectory = "dist/windows-rust",
    [string]$OutputDirectory = "dist/installer"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$sourceDir = [IO.Path]::GetFullPath((Join-Path $rootDir $SourceDirectory))
$outputDir = [IO.Path]::GetFullPath((Join-Path $rootDir $OutputDirectory))
if (-not (Test-Path (Join-Path $sourceDir "polyglance-desktop.exe") -PathType Leaf)) {
    throw "Rust desktop executable is missing."
}

$candidates = @((Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source)
if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe" }
if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles "Inno Setup 6/ISCC.exe" }
if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA "Programs/Inno Setup 6/ISCC.exe" }
$iscc = $candidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 compiler is not available." }
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$numericVersion = ($Version -split '[-+]')[0]
$versionInfo = "$numericVersion.$BuildNumber"
$outputName = "Polyglance-$Version-Windows-Rust-Setup"
$arguments = @(
    "/DMyAppVersion=$Version",
    "/DMyVersionInfoVersion=$versionInfo",
    "/DMySourceDir=$sourceDir",
    "/DMyOutputDir=$outputDir",
    "/DMyOutputBaseFilename=$outputName",
    "/DMyLicenseFile=$(Join-Path $rootDir 'LICENSE')",
    "/DMySetupIconFile=$(Join-Path $rootDir 'apps/windows/src/Polyglance.UI/Resources/Polyglance.ico')",
    (Join-Path $rootDir 'apps/windows/installer/PolyglanceRust.iss')
)
& $iscc @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $outputDir "$outputName.exe") -PathType Leaf)) {
    throw "Rust installer build failed."
}
