# Smoke-test a Polyglance installer using an isolated installation directory.
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath
)

$ErrorActionPreference = "Stop"

$installer = [IO.Path]::GetFullPath($InstallerPath)
if (-not (Test-Path $installer -PathType Leaf)) {
    throw "Installer not found: $installer"
}

$existingInstallKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\io.polyglance.windows_is1",
    "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\io.polyglance.windows_is1"
)
if ($existingInstallKeys | Where-Object { Test-Path $_ }) {
    throw "A per-user Polyglance installation already exists. Refusing to overwrite its uninstall registration during a smoke test."
}

$testId = [Guid]::NewGuid().ToString("N")
$installDir = Join-Path ([IO.Path]::GetTempPath()) "Polyglance-Installer-Smoke-$testId"
$configDir = Join-Path $env:APPDATA "Polyglance"
$userDataSentinel = Join-Path $configDir "installer-smoke-user-data-$testId.txt"
$localConfigDir = Join-Path $env:LOCALAPPDATA "Polyglance"
$localUserDataSentinel = Join-Path $localConfigDir "installer-smoke-user-data-$testId.txt"
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "Polyglance"
$runKey = Get-Item -Path $runKeyPath -ErrorAction SilentlyContinue
$previousRunValueExists = $null -ne $runKey -and $runKey.Property -contains $runValueName
$previousRunValue = if ($previousRunValueExists) {
    Get-ItemPropertyValue -Path $runKeyPath -Name $runValueName
} else {
    $null
}

try {
    $installArguments = @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/SP-",
        "/MERGETASKS=!desktopicon",
        "/DIR=`"$installDir`""
    )
    $installProcess = Start-Process -FilePath $installer -ArgumentList $installArguments -Wait -PassThru
    if ($installProcess.ExitCode -ne 0) {
        throw "Installer returned exit code $($installProcess.ExitCode)."
    }

    $installedExecutable = Join-Path $installDir "Polyglance.exe"
    $uninstaller = Join-Path $installDir "unins000.exe"
    $installedLicense = Join-Path $installDir "LICENSE.txt"
    $portableReadme = Join-Path $installDir "README-PORTABLE.txt"
    if (-not (Test-Path $installedExecutable -PathType Leaf)) {
        throw "Installed executable was not created."
    }
    if (-not (Test-Path $uninstaller -PathType Leaf)) {
        throw "Uninstaller was not created."
    }
    if (-not (Test-Path $installedLicense -PathType Leaf)) {
        throw "Installed package did not include the MIT license."
    }
    if (-not (Test-Path $portableReadme -PathType Leaf)) {
        throw "Installed package did not include the portable-use instructions."
    }

    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content -Path $userDataSentinel -Value "preserve-on-uninstall" -NoNewline
    New-Item -ItemType Directory -Path $localConfigDir -Force | Out-Null
    Set-Content -Path $localUserDataSentinel -Value "preserve-on-uninstall" -NoNewline
    New-Item -Path $runKeyPath -Force | Out-Null
    Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value "`"$installedExecutable`" --autostart"

    $uninstallArguments = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
    $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList $uninstallArguments -Wait -PassThru
    if ($uninstallProcess.ExitCode -ne 0) {
        throw "Uninstaller returned exit code $($uninstallProcess.ExitCode)."
    }

    # Inno Setup may briefly leave its self-deleting uninstaller process alive
    # after the parent process exits. Wait only for the isolated test install.
    $uninstallDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((Test-Path $installedExecutable) -and [DateTime]::UtcNow -lt $uninstallDeadline) {
        Start-Sleep -Milliseconds 250
    }

    if (Test-Path $installedExecutable) {
        throw "Uninstall left the main executable behind."
    }
    if (Get-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue) {
        throw "Uninstall left the Polyglance launch-at-login registry value behind."
    }
    if (-not (Test-Path $userDataSentinel -PathType Leaf)) {
        throw "Uninstall removed roaming user configuration data."
    }
    if (-not (Test-Path $localUserDataSentinel -PathType Leaf)) {
        throw "Uninstall removed local credential or cache data."
    }

    Write-Host "Windows installer install/uninstall smoke test passed." -ForegroundColor Green
}
finally {
    if ($previousRunValueExists) {
        New-Item -Path $runKeyPath -Force | Out-Null
        Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $previousRunValue
    } else {
        Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    }

    Remove-Item -Path $userDataSentinel -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $localUserDataSentinel -Force -ErrorAction SilentlyContinue
    if (Test-Path $installDir) {
        Remove-Item -Path $installDir -Recurse -Force
    }
}
