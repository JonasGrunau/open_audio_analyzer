; oaa.iss — the Windows installer, and the VST3 checkbox.
;
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Built by packaging/windows/make_installer.ps1, which passes the three
; defines below. Not meant to be opened in the Inno IDE and compiled by hand:
; the paths it needs are staged first.
;
; ===========================================================================
; Why this replaced the msix
;
; An msix cannot install a plug-in. Its filesystem is virtualised and
; package-relative, so it has no way to write C:\Program Files\Common
; Files\VST3 — the one folder every VST3 host on Windows scans. It also has no
; component-selection UI of any kind, so even if it could write there it could
; not ask. Both are structural, not configuration.
;
; What the msix did have was an uninstaller in Add/Remove Programs, and Inno
; produces one of those for free.
;
; ===========================================================================
; Why the application row cannot be unticked
;
; Same reason as the macOS package: the plug-in streams what it measures to
; the application over 127.0.0.1:47822. Loopback, so they are always on one
; machine, and a plug-in installed without the application connects to nothing
; with no error a DAW would ever show. `Flags: fixed` is the greyed checkbox.
;
; ===========================================================================
; {commoncf64}, and the bundle that is a folder
;
; A Windows VST3 is a *directory* — Contents\x86_64-win\Open Audio
; Analyzer.vst3 inside Open Audio Analyzer.vst3 — not a file with a .vst3
; extension. So the [Files] entry recurses into a DestDir that is itself named
; .vst3, and `recursesubdirs createallsubdirs` are both load-bearing. Copying
; only the inner .vst3 produces something no host will load.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BundleDir
  #define BundleDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef Vst3Dir
  #define Vst3Dir "..\..\plugin\build\OaaPlugin_artefacts\Release\VST3\Open Audio Analyzer.vst3"
#endif
#ifndef LicenseFile
  #define LicenseFile "..\..\build\packaging\inno-staging\LICENSE.txt"
#endif
#ifndef OutDir
  #define OutDir "..\..\build\packaging"
#endif

[Setup]
; Never change AppId. It is what tells Windows an install is an upgrade of
; this program rather than a second copy of it, and a new one orphans every
; existing installation in Add/Remove Programs.
AppId={{FB4587C9-BFD2-46DA-9948-356ADE054467}
AppName=Open Audio Analyzer
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Open Audio Analyzer
AppPublisherURL=https://github.com/JonasGrunau/open_audio_analyzer
AppSupportURL=https://github.com/JonasGrunau/open_audio_analyzer/issues
DefaultDirName={autopf}\Open Audio Analyzer
DefaultGroupName=Open Audio Analyzer
DisableProgramGroupPage=yes
; Admin, because {commoncf64} and {autopf} are both machine-wide. A per-user
; install would put the VST3 somewhere no DAW launched by another account can
; see, which is the failure this installer exists to prevent.
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir={#OutDir}
OutputBaseFilename=Open Audio Analyzer-{#AppVersion}-windows-x64
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\OpenAudioAnalyzer.exe
LicenseFile={#LicenseFile}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Types]
Name: "full";   Description: "Application and VST3 plug-in"
Name: "custom"; Description: "Custom";                      Flags: iscustom

[Components]
Name: "app";  Description: "Open Audio Analyzer";  Types: full custom; Flags: fixed
Name: "vst3"; Description: "VST3 plug-in";         Types: full

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion; Components: app
Source: "{#LicenseFile}"; DestDir: "{app}"; DestName: "LICENSE.txt"; \
  Flags: ignoreversion; Components: app
Source: "{#Vst3Dir}\*"; DestDir: "{commoncf64}\VST3\Open Audio Analyzer.vst3"; \
  Flags: recursesubdirs createallsubdirs ignoreversion; Components: vst3

[Icons]
Name: "{autoprograms}\Open Audio Analyzer"; Filename: "{app}\OpenAudioAnalyzer.exe"
Name: "{autodesktop}\Open Audio Analyzer";  Filename: "{app}\OpenAudioAnalyzer.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; \
  GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\OpenAudioAnalyzer.exe"; Description: "Start Open Audio Analyzer"; \
  Flags: nowait postinstall skipifsilent

; Inno removes the files it installed but leaves the directories that held
; them, and an empty Open Audio Analyzer.vst3 folder in the shared VST3
; directory is something a host will still try to scan. Scoped to the
; component so that uninstalling an app-only install cannot remove a plug-in
; somebody put there by hand.
[UninstallDelete]
Type: filesandordirs; Name: "{commoncf64}\VST3\Open Audio Analyzer.vst3"; Components: vst3
