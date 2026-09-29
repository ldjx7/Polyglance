# Build the WPF-dependent comparison CLI into an isolated directory.
param(
    [string]$Version = "0.1.4",
    [string]$BuildNumber = "0",
    [string]$OutDirectory = "dist/windows-csharp-cli"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

if (Test-Path $OutDirectory) {
    Get-ChildItem -Path $OutDirectory -Force | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDirectory -Force | Out-Null

$numericVersion = ($Version -split '[-+]')[0]
$assemblyVersion = "$numericVersion.$BuildNumber"
& "$scriptDir\build-windows-core.ps1"

dotnet publish "apps/windows/src/Polyglance.Cli/Polyglance.Cli.csproj" `
    -c Release -r win-x64 --self-contained false `
    "-p:Version=$assemblyVersion" `
    "-p:InformationalVersion=$Version" `
    -p:IncludeSourceRevisionInInformationalVersion=false `
    -o $OutDirectory
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$OutDirectory/polyglance-csharp-cli.exe" -PathType Leaf)) {
    throw "C# CLI publish failed."
}

$coreDll = "target/release/polyglance_cabi.dll"
if (-not (Test-Path $coreDll)) {
    $coreDll = "target/x86_64-pc-windows-msvc/release/polyglance_cabi.dll"
}
if (-not (Test-Path $coreDll)) {
    throw "Rust core DLL is missing."
}
Copy-Item $coreDll -Destination $OutDirectory -Force
Write-Host "C# CLI: $OutDirectory/polyglance-csharp-cli.exe" -ForegroundColor Green
