# Build Polyglance Windows Application (.NET 9 WPF + Rust Core)
param(
    [string]$Version = "0.0.0",
    [string]$BuildNumber = "0",
    $SelfContained = $true,
    [string]$OutDirectory = "",
    $SingleFile = $null,
    $ExcludeOcrModels = $null,
    $ExcludeTranslation = $null
)

$isSelfContained = $true
if ($PSBoundParameters.ContainsKey('SelfContained')) {
    $val = "$($PSBoundParameters['SelfContained'])".ToLower().Trim()
    if ($val -eq 'false' -or $val -eq '0') {
        $isSelfContained = $false
    }
}
$SelfContained = $isSelfContained

$SingleFile = (-not $SelfContained)
if ($PSBoundParameters.ContainsKey('SingleFile')) {
    $val = "$($PSBoundParameters['SingleFile'])".ToLower().Trim()
    $SingleFile = ($val -ne 'false' -and $val -ne '0')
}

$ExcludeOcrModels = (-not $SelfContained)
if ($PSBoundParameters.ContainsKey('ExcludeOcrModels')) {
    $val = "$($PSBoundParameters['ExcludeOcrModels'])".ToLower().Trim()
    $ExcludeOcrModels = ($val -ne 'false' -and $val -ne '0')
}

if ($PSBoundParameters.ContainsKey('ExcludeTranslation')) {
    $val = "$($PSBoundParameters['ExcludeTranslation'])".ToLower().Trim()
    $ExcludeTranslation = ($val -ne 'false' -and $val -ne '0')
} else {
    $ExcludeTranslation = (-not $SelfContained)
}

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir

Set-Location $rootDir

$outDir = if (-not [string]::IsNullOrWhiteSpace($OutDirectory)) {
    $OutDirectory
} elseif ($SelfContained) {
    "dist/windows"
} else {
    "dist/windows-cli"
}

$installerOutDir = "dist/installer"

function Remove-BuildOutputDirectory([string]$path) {
    if (-not (Test-Path $path)) {
        return
    }

    # Defender/Explorer can hold a just-created runtime DLL briefly even after
    # Polyglance itself has exited. Retrying keeps each local build clean without
    # falling back to stale files from a previous publish.
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

# Local builds must not leave a running executable locking the publish output.
foreach ($processName in @("Polyglance.UI", "Polyglance", "polyglance")) {
    Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Keep only artifacts created by this build invocation.
Remove-BuildOutputDirectory $outDir
if ($SelfContained -and [string]::IsNullOrWhiteSpace($OutDirectory)) {
    Remove-BuildOutputDirectory $installerOutDir
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
$selfContainedArg = if ($SelfContained) { "true" } else { "false" }

$extraPublishArgs = @()
if ($SingleFile) {
    $extraPublishArgs += "-p:PublishSingleFile=true"
    $extraPublishArgs += "-p:IncludeNativeLibrariesForSelfExtract=true"
    if ($SelfContained) {
        $extraPublishArgs += "-p:EnableCompressionInSingleFile=true"
    } else {
        $extraPublishArgs += "-p:DebugType=none"
        $extraPublishArgs += "-p:DebugSymbols=false"
    }
} else {
    $extraPublishArgs += "-p:PublishSingleFile=false"
}

if ($ExcludeOcrModels) {
    $extraPublishArgs += "-p:ExcludeOcrModels=true"
    $extraPublishArgs += "-p:PolyglanceCliBuild=true"
}

if ($ExcludeTranslation) {
    $extraPublishArgs += "-p:ExcludeTranslation=true"
}

$publishCommand = @(
    "apps/windows/src/Polyglance.UI/Polyglance.UI.csproj",
    "-c", "Release",
    "-r", "win-x64",
    "--self-contained", $selfContainedArg,
    "-p:Version=$assemblyVersion",
    "-p:InformationalVersion=$Version",
    "-p:IncludeSourceRevisionInInformationalVersion=false",
    "-o", $outDir
) + $extraPublishArgs

dotnet publish @publishCommand
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$outDir/Polyglance.exe" -PathType Leaf)) {
    throw "Windows application publish did not create $outDir/Polyglance.exe."
}

if ($ExcludeOcrModels) {
    Remove-Item "$outDir/onnxruntime*.dll", "$outDir/onnxruntime*.lib", "$outDir/Microsoft.ML.OnnxRuntime.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item "$outDir/models" -Recurse -Force -ErrorAction SilentlyContinue
}

if ($SingleFile) {
    Remove-Item "$outDir/*.pdb" -Force -ErrorAction SilentlyContinue
}

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

$finalExeName = "Polyglance.exe"
if (-not $SelfContained) {
    if (Test-Path "$outDir/Polyglance.exe") {
        Move-Item "$outDir/Polyglance.exe" "$outDir/polyglance.exe" -Force
        $finalExeName = "polyglance.exe"
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Build Complete: $outDir\$finalExeName " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
