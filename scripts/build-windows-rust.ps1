# Build Polyglance Windows Rust Application & CLI (Rust + Slint)
param(
    [string]$Version = "0.1.4",
    [string]$BuildNumber = "0",
    [string]$OutDirectory = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir

Set-Location $rootDir

$outDir = if (-not [string]::IsNullOrWhiteSpace($OutDirectory)) {
    $OutDirectory
} else {
    "dist/windows-rust"
}

$installerOutDir = "dist/installer"

function Remove-BuildOutputDirectory([string]$path) {
    if (-not (Test-Path $path)) {
        return
    }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 10) {
                Write-Warning "Unable to fully clear previous build output '$path': $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Stop any running instances of polyglance-desktop or polyglance-cli
foreach ($proc in @("polyglance-desktop", "polyglance-cli")) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

Remove-BuildOutputDirectory $outDir
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
if (-not (Test-Path $installerOutDir)) {
    New-Item -ItemType Directory -Path $installerOutDir -Force | Out-Null
}

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Building Polyglance Windows Rust Track        " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

# Build Rust CLI & Desktop for this Windows host. A failed build must not fall
# back to binaries left in another target directory.
Write-Host "`n==> Building Rust CLI and Desktop (Release)..." -ForegroundColor Cyan
 cargo build --release -p polyglance-cli -p polyglance-desktop
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile polyglance-cli and polyglance-desktop."
}

$cliExe = "target/release/polyglance-cli.exe"
$desktopExe = "target/release/polyglance-desktop.exe"
if (-not (Test-Path $cliExe -PathType Leaf) -or -not (Test-Path $desktopExe -PathType Leaf)) {
    throw "Compiled Rust binaries not found in target/release."
}
Copy-Item $cliExe -Destination "$outDir/polyglance-cli.exe" -Force
Copy-Item $desktopExe -Destination "$outDir/polyglance-desktop.exe" -Force

$ortDll = Join-Path $env:USERPROFILE ".nuget/packages/microsoft.ml.onnxruntime/1.20.1/runtimes/win-x64/native/onnxruntime.dll"
if (-not (Test-Path $ortDll -PathType Leaf)) {
    throw "ONNX Runtime 1.20.1 was not restored; build the existing Windows solution first."
}
Copy-Item $ortDll -Destination "$outDir/onnxruntime.dll" -Force

Copy-Item "LICENSE" -Destination "$outDir/LICENSE.txt" -Force

$portableZipPath = "$installerOutDir/Polyglance-$Version-Windows-Rust-Portable.zip"
Write-Host "`n==> Creating Portable ZIP package at $portableZipPath..." -ForegroundColor Cyan
if (Test-Path $portableZipPath) {
    Remove-Item $portableZipPath -Force
}
Compress-Archive -Path "$outDir/*" -DestinationPath $portableZipPath -Force

& "$scriptDir\build-windows-rust-installer.ps1" -Version $Version -BuildNumber $BuildNumber -SourceDirectory $outDir

$sizeMb = [math]::Round(((Get-ChildItem -Path $outDir -File | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
Write-Host "Uncompressed Rust package: $sizeMb MiB" -ForegroundColor Cyan

Write-Host "`n===============================================" -ForegroundColor Green
Write-Host " Rust Track Build Complete:                    " -ForegroundColor Green
Write-Host " Output:   $outDir                             " -ForegroundColor Green
Write-Host " Package:  $portableZipPath                    " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
