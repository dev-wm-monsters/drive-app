; scripts/windows/DriveApp.iss: Inno Setup 6 script for the Windows app.
;
; Compiled by scripts/build-windows.ps1 once per architecture; every value
; that changes per build is passed with /D on the ISCC command line:
;   /DAppVersion=0.1.0-beta.1   display version (any SemVer string)
;   /DAppVersionNumeric=0.1.0.7 four numeric parts (file version resource)
;   /DAppArch=x64 | arm64
;   /DSourceDir=<publish folder of DriveSync.App for that runtime>
;   /DAppExeName=DriveSync.App.exe
;   /DSignInstaller             only for signed builds; ISCC then also gets
;                               /Sdriveappsign=<signtool command> and signs the
;                               setup and the uninstaller with it.
;
; Per-user install: no admin rights, files go to %LOCALAPPDATA%\Programs\DriveApp
; ({autopf} in non-administrative mode), shortcuts to the user's Start Menu.
; Uninstall stops the app, then runs "<exe> --unregister" so the app removes its
; Cloud Files sync root (and Explorer navigation-pane entry) before its files go.

#ifndef AppVersion
  #error AppVersion is not defined. Build with scripts/build-windows.ps1.
#endif
#ifndef AppVersionNumeric
  #error AppVersionNumeric is not defined. Build with scripts/build-windows.ps1.
#endif
#ifndef AppArch
  #error AppArch is not defined (x64 or arm64).
#endif
#ifndef SourceDir
  #error SourceDir is not defined (the dotnet publish output folder).
#endif
#ifndef AppExeName
  #define AppExeName "DriveSync.App.exe"
#endif
#ifndef AppName
  #define AppName "DriveApp"
#endif
#define AppPublisher "WakeupMonster"

[Setup]
; Never change AppId: Windows uses it to find the installed app for upgrades
; and uninstall.
AppId={{8FDD6572-D528-49CC-879F-CA4402B6D6DE}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductVersion={#AppVersionNumeric}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableDirPage=auto
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
; Cloud Files sync roots need Windows 10 2004 (build 19041) or later.
MinVersion=10.0.19041
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
#ifdef SignInstaller
SignTool=driveappsign
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start {#AppName} when I sign in to Windows"; GroupDescription: "Startup:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"

[Registry]
; Optional run-at-login (per user). Removed again on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 1. Stop the running app: a connected sync provider cannot unregister its
;    sync root (ERROR_CLOUD_FILE_INVALID_REQUEST). Exit code ignored (the app
;    may not be running).
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM ""{#AppExeName}"""; Flags: runhidden waituntilterminated; RunOnceId: "StopApp"
; 2. Unregister the Cloud Files sync root and the Explorer entry.
Filename: "{app}\{#AppExeName}"; Parameters: "--unregister"; Flags: runhidden waituntilterminated; RunOnceId: "UnregisterSyncRoot"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
