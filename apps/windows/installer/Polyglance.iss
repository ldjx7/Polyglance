#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyVersionInfoVersion
  #define MyVersionInfoVersion "0.0.0.0"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\..\dist\windows"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\..\dist\installer"
#endif
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "Polyglance-0.0.0-Windows-x64-Setup"
#endif
#ifndef MyLicenseFile
  #define MyLicenseFile "..\..\..\LICENSE"
#endif
#ifndef MySetupIconFile
  #define MySetupIconFile "..\src\Polyglance.UI\Resources\Polyglance.ico"
#endif

[Setup]
AppId=io.polyglance.windows
AppName=Polyglance
AppVersion={#MyAppVersion}
AppVerName=Polyglance {#MyAppVersion}
AppPublisher=ldjx
AppPublisherURL=https://github.com/ldjx7/Polyglance
AppSupportURL=https://github.com/ldjx7/Polyglance/issues
AppUpdatesURL=https://github.com/ldjx7/Polyglance/releases
VersionInfoVersion={#MyVersionInfoVersion}
VersionInfoCompany=ldjx
VersionInfoDescription=Polyglance Installer
VersionInfoProductName=Polyglance
VersionInfoProductVersion={#MyVersionInfoVersion}
DefaultDirName={localappdata}\Programs\Polyglance
DefaultGroupName=Polyglance
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
SetupIconFile={#MySetupIconFile}
LicenseFile={#MyLicenseFile}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes
UninstallDisplayName=Polyglance
UninstallDisplayIcon={app}\Polyglance.UI.exe
AppMutex=Polyglance_SingleInstance_Mutex
CloseApplications=yes
RestartApplications=no
AllowNoIcons=yes
AllowUNCPath=no
AllowRootDirectory=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[CustomMessages]
english.AdditionalShortcuts=Additional shortcuts:
english.CreateDesktopIcon=Create a desktop shortcut
english.LaunchProgram=Launch Polyglance
chinesesimplified.AdditionalShortcuts=附加快捷方式：
chinesesimplified.CreateDesktopIcon=创建桌面快捷方式
chinesesimplified.LaunchProgram=启动 Polyglance

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalShortcuts}"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Polyglance"; Filename: "{app}\Polyglance.UI.exe"; WorkingDir: "{app}"
Name: "{group}\Uninstall Polyglance"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Polyglance"; Filename: "{app}\Polyglance.UI.exe"; WorkingDir: "{app}"; Tasks: desktopicon

; The application owns this per-user value when launch-at-login is enabled.
; Setup does not create it, but uninstall removes a stale entry safely.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Polyglance"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Polyglance.UI.exe"; Description: "{cm:LaunchProgram}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
