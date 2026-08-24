# Build Polyglance Windows Application (.NET 9 WPF + Rust Core)
param(
    [string]$Version = "0.0.0",
    [string]$BuildNumber = "0"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir

Set-Location $rootDir

$outDir = "dist/windows"
$installerOutDir = "dist/installer"

# Local builds must not leave a running executable locking the publish output.
foreach ($processName in @("Polyglance.UI", "Polyglance")) {
    Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Keep only artifacts created by this build invocation.
if (Test-Path $outDir) {
    Remove-Item $outDir -Recurse -Force
}
if (Test-Path $installerOutDir) {
    Remove-Item $installerOutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Building Polyglance Windows Client     " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. Build Rust Core DLL
& "$scriptDir\build-windows-core.ps1"

# 2. Publish .NET 9 WPF App
Write-Host "`n==> Publishing WPF application (.NET 9)..." -ForegroundColor Cyan
$numericVersion = ($Version -split '[-+]')[0]
$assemblyVersion = "$numericVersion.$BuildNumber"
dotnet publish apps/windows/src/Polyglance.UI/Polyglance.UI.csproj `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:Version=$assemblyVersion `
    -p:InformationalVersion=$Version `
    -o $outDir

# 3. Copy Rust DLL to output directory
$dllSource = "target/release/polyglance_cabi.dll"
if (-not (Test-Path $dllSource)) {
    $dllSource = "target/x86_64-pc-windows-msvc/release/polyglance_cabi.dll"
}

if (Test-Path $dllSource) {
    Copy-Item $dllSource -Destination $outDir -Force
    Write-Host "==> Copied polyglance_cabi.dll to $outDir" -ForegroundColor Green
}

# 4. Include redistribution and portable-use documentation in every package.
Copy-Item "LICENSE" -Destination "$outDir/LICENSE.txt" -Force
Copy-Item "apps/windows/README-PORTABLE.txt" -Destination "$outDir/README-PORTABLE.txt" -Force

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Build Complete: $outDir\Polyglance.UI.exe " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
