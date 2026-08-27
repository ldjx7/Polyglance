#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
release_workflow="$repository_root/.github/workflows/release-windows.yml"
ci_workflow="$repository_root/.github/workflows/windows-ci.yml"
installer_script="$repository_root/apps/windows/installer/Polyglance.iss"
installer_chinese_messages="$repository_root/apps/windows/installer/Languages/ChineseSimplified.isl"
build_installer_script="$repository_root/scripts/build-windows-installer.ps1"
test_installer_script="$repository_root/scripts/test-windows-installer.ps1"
build_app_script="$repository_root/scripts/build-windows-app.ps1"
recording_toolbar="$repository_root/apps/windows/src/Polyglance.UI/Views/ScreenRecordingWindow.xaml"
portable_readme="$repository_root/apps/windows/README-PORTABLE.txt"

function require_pattern() {
    local file="$1"
    local pattern="$2"
    if ! rg --quiet --fixed-strings -- "$pattern" "$file"; then
        print -u2 "Missing Windows packaging contract in ${file:t}: $pattern"
        return 1
    fi
}

[[ -f "$release_workflow" ]]
[[ -f "$ci_workflow" ]]
[[ -f "$installer_script" ]]
[[ -f "$installer_chinese_messages" ]]
[[ -f "$build_installer_script" ]]
[[ -f "$test_installer_script" ]]
[[ -f "$recording_toolbar" ]]
[[ -f "$portable_readme" ]]

require_pattern "$installer_script" "AppId=io.polyglance.windows"
require_pattern "$installer_script" "PrivilegesRequired=lowest"
require_pattern "$installer_script" 'DefaultDirName={localappdata}\Programs\Polyglance'
require_pattern "$installer_script" "Uninstallable=yes"
require_pattern "$installer_script" "AppMutex=Polyglance_SingleInstance_Mutex"
require_pattern "$installer_script" "CloseApplications=yes"
require_pattern "$installer_script" "uninsdeletevalue"
require_pattern "$installer_script" 'VersionInfoProductVersion={#MyVersionInfoVersion}'
require_pattern "$installer_script" 'MessagesFile: "Languages\ChineseSimplified.isl"'
require_pattern "$installer_script" '[Tasks]'
require_pattern "$installer_script" '[Icons]'
require_pattern "$installer_script" '[Run]'

if rg --quiet --fixed-strings 'Type: filesandordirs; Name: "{app}"' "$installer_script" \
    || rg --quiet --fixed-strings '{userappdata}\Polyglance' "$installer_script" \
    || rg --quiet --fixed-strings '{localappdata}\Polyglance\credentials.dat' "$installer_script"; then
    print -u2 "The uninstaller must not recursively delete the install directory or user configuration."
    exit 1
fi

require_pattern "$build_installer_script" "ISCC.exe"
require_pattern "$build_installer_script" "Polyglance.iss"
require_pattern "$build_installer_script" "MyAppVersion"
require_pattern "$build_installer_script" "MyVersionInfoVersion"
require_pattern "$build_installer_script" "IsPathRooted"
require_pattern "$build_installer_script" '$env:LOCALAPPDATA'

require_pattern "$build_app_script" 'LICENSE.txt'
require_pattern "$build_app_script" 'README-PORTABLE.txt'
require_pattern "$build_app_script" 'Stop-Process'
require_pattern "$build_app_script" 'Polyglance.UI'
require_pattern "$build_app_script" 'dist/installer'
require_pattern "$build_app_script" 'Remove-BuildOutputDirectory $outDir'
require_pattern "$build_app_script" 'IncludeSourceRevisionInInformationalVersion=false'

require_pattern "$recording_toolbar" 'x:Key="RecordingComboBoxStyle"'
require_pattern "$recording_toolbar" 'Style="{StaticResource RecordingComboBoxStyle}"'
require_pattern "$recording_toolbar" 'Width="710"'

require_pattern "$test_installer_script" "/VERYSILENT"
require_pattern "$test_installer_script" "unins000.exe"
require_pattern "$test_installer_script" "installer-smoke-user-data"
require_pattern "$test_installer_script" '$env:LOCALAPPDATA'
require_pattern "$test_installer_script" 'CurrentVersion\Run'
require_pattern "$test_installer_script" 'io.polyglance.windows_is1'
require_pattern "$test_installer_script" 'Refusing to overwrite its uninstall registration'

require_pattern "$ci_workflow" "build-windows-installer.ps1"
require_pattern "$ci_workflow" "test-windows-installer.ps1"
require_pattern "$ci_workflow" "build-windows-core.ps1"
require_pattern "$ci_workflow" 'target\release'

require_pattern "$release_workflow" 'Polyglance-$version-Windows-x64-Portable.zip'
require_pattern "$release_workflow" 'Polyglance-$version-Windows-x64-Setup.exe'
require_pattern "$release_workflow" "build-windows-installer.ps1"
require_pattern "$release_workflow" "test-windows-installer.ps1"
require_pattern "$release_workflow" 'SETUP_NAME:'
require_pattern "$release_workflow" '$env:SETUP_NAME'
require_pattern "$release_workflow" '<sparkle:shortVersionString>$version</sparkle:shortVersionString>'
require_pattern "$release_workflow" '<sparkle:version>$buildVersion</sparkle:version>'
require_pattern "$release_workflow" "build-windows-core.ps1"
require_pattern "$release_workflow" 'target\release'
require_pattern "$release_workflow" '--draft=false'
require_pattern "$release_workflow" 'workflow_dispatch:'
require_pattern "$release_workflow" 'release_tag:'
require_pattern "$release_workflow" 'RELEASE_TAG:'

native_build_line="$(rg -n --fixed-strings 'build-windows-core.ps1' "$release_workflow" | head -1 | cut -d: -f1)"
windows_test_line="$(rg -n --fixed-strings 'dotnet test apps/windows/Polyglance.sln' "$release_workflow" | head -1 | cut -d: -f1)"
if (( native_build_line >= windows_test_line )); then
    print -u2 "The Windows native DLL must be built before the .NET test suite runs."
    exit 1
fi

print "Windows release and installer contract passed"
