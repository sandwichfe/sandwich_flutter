[Setup]
AppId=395630db-c0b3-4fa0-8de3-bb6265cb1f6d
AppName=sandwichPlayer
AppVersion=1.0.0
DefaultDirName={autopf}\MediaCenter
DefaultGroupName=sandwichPlayer
OutputDir=dist
OutputBaseFilename=MediaCenter-Setup-1.0.0
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\sandwich_player.exe

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\sandwichPlayer"; Filename: "{app}\sandwich_player.exe"
Name: "{autodesktop}\sandwichPlayer"; Filename: "{app}\sandwich_player.exe"

[Run]
Filename: "{app}\sandwich_player.exe"; Description: "启动sandwichPlayer"; Flags: nowait postinstall skipifsilent
