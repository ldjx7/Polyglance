#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyVersionInfoVersion
  #define MyVersionInfoVersion "0.0.0.0"
#endif

[Setup]
AppId=io.polyglance.windows.rust.preview
AppName=Polyglance Rust Preview
AppVersion={#MyAppVersion}
AppPublisher=ldjx
VersionInfoVersion={#MyVersionInfoVersion}
DefaultDirName={localappdata}\Programs\Polyglance Rust Preview
DefaultGroupName=Polyglance Rust Preview
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
UninstallDisplayIcon={app}\polyglance-desktop.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Polyglance Rust Preview"; Filename: "{app}\polyglance-desktop.exe"
Name: "{group}\Uninstall Polyglance Rust Preview"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\polyglance-desktop.exe"; Description: "Launch Polyglance Rust Preview"; Flags: nowait postinstall skipifsilent
