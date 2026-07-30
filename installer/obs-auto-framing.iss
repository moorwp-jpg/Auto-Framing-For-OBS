; Public OBS Auto Framing installer. Input is the validated public release staging directory.

#define ExpectedAppVersion "0.2.0"
#define AppName "OBS Auto Framing"
#define PluginName "obs-auto-framing"
#define StableAppId "6E0D52B7-3F4C-4B5F-8F0A-8A1EA8E43E46"

#ifndef StagingRoot
  #error StagingRoot must be provided by scripts/build_installer.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be provided by scripts/build_installer.ps1
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename must be provided by scripts/build_installer.ps1
#endif
#ifndef AppVersion
  #error AppVersion must be provided by scripts/build_installer.ps1
#endif
#ifndef ReleaseChannel
  #error ReleaseChannel must be provided by scripts/build_installer.ps1
#endif
#ifndef AppPublisher
  #error AppPublisher must be provided by scripts/build_installer.ps1
#endif

[Setup]
AppId={{{#StableAppId}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} {#ReleaseChannel}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
VersionInfoTextVersion={#AppVersion} {#ReleaseChannel}
VersionInfoProductVersion={#AppVersion}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\obs-plugins\64bit\{#PluginName}.dll
DefaultDirName={code:GetInitialObsRoot}
AppendDefaultDirName=no
UsePreviousAppDir=no
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartIfNeededByRun=no
SetupLogging=yes
SetupMutex=OBS-Auto-Framing-Public-Installer-{#StableAppId}
UninstallFilesDir={app}\data\obs-plugins\{#PluginName}\installer

[Messages]
SelectDirDesc=Choose the OBS Studio Windows x64 root
SelectDirLabel3=Select the OBS Studio root that contains bin\64bit\obs64.exe. Standard, custom, portable, and prepared runtime roots are supported.

[Files]
Source: "{#StagingRoot}\obs-plugins\64bit\obs-auto-framing.dll"; DestDir: "{app}\obs-plugins\64bit"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\obs-plugins\64bit\onnxruntime.dll"; DestDir: "{app}\obs-plugins\64bit"; Flags: ignoreversion uninsneveruninstall; Check: ShouldInstallSharedRuntime
Source: "{#StagingRoot}\data\obs-plugins\obs-auto-framing\effects\crop.effect"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\effects"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\data\obs-plugins\obs-auto-framing\locale\en-US.ini"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\locale"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\models"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\docs\install.md"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\docs\troubleshooting.md"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\LICENSE"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\README.md"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\SECURITY.md"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall
Source: "{#StagingRoot}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}\data\obs-plugins\obs-auto-framing\docs"; Flags: ignoreversion uninsneveruninstall

[Code]
const
  PowerShellObsRunningResult = 10;
  ManifestFileCount = 11;
  PreviousPublicRuntimeHash = 'c707fd4b555781b0d7ac6f6d64f2e94227793f9d21283664638c21817fe5597d';

var
  SharedRuntimeExisted: Boolean;
  SharedRuntimeOriginalHash: String;
  SharedRuntimeCreatedByInstaller: Boolean;
  InstallSharedRuntime: Boolean;
  PayloadExistedBefore: array[0..10] of Boolean;
  PayloadOriginalHash: array[0..10] of String;
  PayloadCreatedByInstaller: array[0..10] of Boolean;

function ManifestPath(): String;
begin
  Result := ExpandConstant('{app}\data\obs-plugins\{#PluginName}\installer\install-manifest.ini');
end;

function ObsRootIsValid(Path: String): Boolean;
begin
  Result := FileExists(AddBackslash(Path) + 'bin\64bit\obs64.exe');
end;

function GetInitialObsRoot(Param: String): String;
var
  StandardRoot: String;
begin
  StandardRoot := ExpandConstant('{commonpf64}\obs-studio');
  if ObsRootIsValid(StandardRoot) then
    Result := StandardRoot
  else
    Result := ExpandConstant('{sd}\');
end;

function QueryObsRunning(var CheckFailed: Boolean): Boolean;
var
  ResultCode: Integer;
  PowerShellPath: String;
  Parameters: String;
begin
  CheckFailed := False;
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters :=
    '-NoProfile -NonInteractive -WindowStyle Hidden -Command ' +
    '"if (Get-Process -Name ''obs64'' -ErrorAction SilentlyContinue) { exit 10 }; exit 0"';

  if not Exec(PowerShellPath, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    CheckFailed := True;
    Result := True;
    exit;
  end;

  if ResultCode = PowerShellObsRunningResult then
    Result := True
  else if ResultCode = 0 then
    Result := False
  else
  begin
    CheckFailed := True;
    Result := True;
  end;
end;

function CommandLineIsSilent(): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount() do
  begin
    if (CompareText(ParamStr(Index), '/SILENT') = 0) or
       (CompareText(ParamStr(Index), '/VERYSILENT') = 0) then
    begin
      Result := True;
      exit;
    end;
  end;
end;

function RefuseIfObsRunning(Silent: Boolean): Boolean;
var
  CheckFailed: Boolean;
begin
  Result := QueryObsRunning(CheckFailed);
  if Result and not Silent then
  begin
    if CheckFailed then
      MsgBox(
        'Setup could not safely determine whether OBS Studio is running.' + #13#10 + #13#10 +
        'Close OBS and verify Windows PowerShell can query processes, then try again.',
        mbCriticalError, MB_OK)
    else
      MsgBox(
        'OBS Studio is running. Close OBS before installing, upgrading, repairing, or uninstalling OBS Auto Framing.',
        mbCriticalError, MB_OK);
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := not RefuseIfObsRunning(CommandLineIsSilent());
end;

function InitializeUninstall(): Boolean;
begin
  Result := not RefuseIfObsRunning(CommandLineIsSilent());
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not ObsRootIsValid(WizardDirValue()) then
  begin
    if WizardSilent() then
      Result := True
    else
    begin
      MsgBox(
        'This is not a valid OBS Studio Windows x64 root.' + #13#10 + #13#10 +
        'Select the folder that contains bin\64bit\obs64.exe. No files have been written.',
        mbCriticalError, MB_OK);
      Result := False;
    end;
  end;
end;

function ShouldInstallSharedRuntime(): Boolean;
begin
  Result := InstallSharedRuntime;
end;

procedure CaptureOwnershipBaseline(); forward;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  CheckFailed: Boolean;
  RuntimePath: String;
  ExistingHash: String;
begin
  Result := '';
  if QueryObsRunning(CheckFailed) then
  begin
    if CheckFailed then
      Result := 'Setup could not safely determine whether OBS Studio is running. Close OBS and verify Windows PowerShell process queries, then try again.'
    else
      Result := 'OBS Studio is running. Close OBS before installing, upgrading, or repairing OBS Auto Framing.';
    exit;
  end;

  if not ObsRootIsValid(WizardDirValue()) then
  begin
    Result := 'Invalid OBS root. Select the folder that contains bin\64bit\obs64.exe.';
    exit;
  end;

  RuntimePath := AddBackslash(WizardDirValue()) + 'obs-plugins\64bit\onnxruntime.dll';
  SharedRuntimeExisted := FileExists(RuntimePath);
  SharedRuntimeOriginalHash := '';
  SharedRuntimeCreatedByInstaller := not SharedRuntimeExisted;
  InstallSharedRuntime := True;
  if SharedRuntimeExisted then
  begin
    SharedRuntimeOriginalHash := Lowercase(GetSHA256OfFile(RuntimePath));
    if CompareText(SharedRuntimeOriginalHash, '{#RuntimeHash}') = 0 then
    begin
      InstallSharedRuntime := False;
      if (CompareText(GetIniString('File.1', 'CreatedByInstaller', 'false', ManifestPath()), 'true') = 0) and
         (CompareText(GetIniString('File.1', 'InstalledSHA256', '', ManifestPath()), '{#RuntimeHash}') = 0) then
      begin
        SharedRuntimeExisted := False;
        SharedRuntimeOriginalHash := '';
        SharedRuntimeCreatedByInstaller := True;
      end;
    end
    else if CompareText(SharedRuntimeOriginalHash, PreviousPublicRuntimeHash) = 0 then
    begin
      { This exact runtime shipped in the public v0.1.1 ZIP. Replacing it is the
        documented compatibility decision for the supported manual upgrade. }
      InstallSharedRuntime := True;
      SharedRuntimeCreatedByInstaller := False;
    end
    else
    begin
      Result :=
        'A different obs-plugins\64bit\onnxruntime.dll already exists in this OBS root.' + #13#10 + #13#10 +
        'For safety, setup will not replace or claim this shared runtime. Use a separate OBS root or review plugin compatibility before installing.';
    end;
  end;

  if Result = '' then
    CaptureOwnershipBaseline();
end;

function BoolText(Value: Boolean): String;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

procedure WriteManifestRecord(
  Index: Integer;
  RelativePath: String;
  InstalledHash: String;
  SharedRuntime: Boolean);
var
  Section: String;
begin
  Section := 'File.' + IntToStr(Index);

  SetIniString(Section, 'RelativePath', RelativePath, ManifestPath());
  SetIniString(Section, 'InstalledVersion', '{#AppVersion}', ManifestPath());
  SetIniString(Section, 'InstalledSHA256', InstalledHash, ManifestPath());
  SetIniString(Section, 'CreatedByInstaller', BoolText(PayloadCreatedByInstaller[Index]), ManifestPath());
  SetIniString(Section, 'ExistedBefore', BoolText(PayloadExistedBefore[Index]), ManifestPath());
  SetIniString(Section, 'OriginalSHA256', PayloadOriginalHash[Index], ManifestPath());
  SetIniString(Section, 'SharedRuntime', BoolText(SharedRuntime), ManifestPath());
end;

procedure CaptureFileBaseline(Index: Integer; RelativePath: String; SharedRuntime: Boolean);
var
  Section: String;
  TargetPath: String;
  CurrentHash: String;
  PreservePreviousOwnership: Boolean;
begin
  if SharedRuntime then
  begin
    PayloadExistedBefore[Index] := SharedRuntimeExisted;
    PayloadOriginalHash[Index] := SharedRuntimeOriginalHash;
    PayloadCreatedByInstaller[Index] := SharedRuntimeCreatedByInstaller;
    exit;
  end;

  Section := 'File.' + IntToStr(Index);
  TargetPath := AddBackslash(WizardDirValue()) + RelativePath;
  PayloadExistedBefore[Index] := FileExists(TargetPath);
  PayloadCreatedByInstaller[Index] := not PayloadExistedBefore[Index];
  if PayloadExistedBefore[Index] then
    CurrentHash := Lowercase(GetSHA256OfFile(TargetPath))
  else
    CurrentHash := '';
  PayloadOriginalHash[Index] := CurrentHash;

  PreservePreviousOwnership :=
    PayloadExistedBefore[Index] and
    (CompareText(GetIniString('Metadata', 'Complete', 'false', ManifestPath()), 'true') = 0) and
    (CompareText(GetIniString(Section, 'RelativePath', '', ManifestPath()), RelativePath) = 0) and
    (CompareText(GetIniString(Section, 'InstalledSHA256', '', ManifestPath()), CurrentHash) = 0);
  if PreservePreviousOwnership then
  begin
    PayloadCreatedByInstaller[Index] :=
      CompareText(GetIniString(Section, 'CreatedByInstaller', 'false', ManifestPath()), 'true') = 0;
    PayloadExistedBefore[Index] :=
      CompareText(GetIniString(Section, 'ExistedBefore', 'true', ManifestPath()), 'true') = 0;
    PayloadOriginalHash[Index] := GetIniString(Section, 'OriginalSHA256', '', ManifestPath());
  end;
end;

procedure CaptureOwnershipBaseline();
begin
  CaptureFileBaseline(0, 'obs-plugins\64bit\obs-auto-framing.dll', False);
  CaptureFileBaseline(1, 'obs-plugins\64bit\onnxruntime.dll', True);
  CaptureFileBaseline(2, 'data\obs-plugins\obs-auto-framing\effects\crop.effect', False);
  CaptureFileBaseline(3, 'data\obs-plugins\obs-auto-framing\locale\en-US.ini', False);
  CaptureFileBaseline(4, 'data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx', False);
  CaptureFileBaseline(5, 'data\obs-plugins\obs-auto-framing\docs\install.md', False);
  CaptureFileBaseline(6, 'data\obs-plugins\obs-auto-framing\docs\troubleshooting.md', False);
  CaptureFileBaseline(7, 'data\obs-plugins\obs-auto-framing\docs\LICENSE', False);
  CaptureFileBaseline(8, 'data\obs-plugins\obs-auto-framing\docs\README.md', False);
  CaptureFileBaseline(9, 'data\obs-plugins\obs-auto-framing\docs\SECURITY.md', False);
  CaptureFileBaseline(10, 'data\obs-plugins\obs-auto-framing\docs\THIRD_PARTY_NOTICES.md', False);
end;

procedure WriteOwnershipManifest();
begin
  ForceDirectories(ExtractFileDir(ManifestPath()));
  SetIniString('Metadata', 'SchemaVersion', '1', ManifestPath());
  SetIniString('Metadata', 'InstalledVersion', '{#AppVersion}', ManifestPath());
  SetIniString('Metadata', 'ObsRoot', WizardDirValue(), ManifestPath());
  SetIniString('Metadata', 'FileCount', IntToStr(ManifestFileCount), ManifestPath());
  SetIniString('Metadata', 'Complete', 'false', ManifestPath());
  WriteManifestRecord(0, 'obs-plugins\64bit\obs-auto-framing.dll', '{#PluginHash}', False);
  WriteManifestRecord(1, 'obs-plugins\64bit\onnxruntime.dll', '{#RuntimeHash}', True);
  WriteManifestRecord(2, 'data\obs-plugins\obs-auto-framing\effects\crop.effect', '{#EffectHash}', False);
  WriteManifestRecord(3, 'data\obs-plugins\obs-auto-framing\locale\en-US.ini', '{#LocaleHash}', False);
  WriteManifestRecord(4, 'data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx', '{#ModelHash}', False);
  WriteManifestRecord(5, 'data\obs-plugins\obs-auto-framing\docs\install.md', '{#InstallDocHash}', False);
  WriteManifestRecord(6, 'data\obs-plugins\obs-auto-framing\docs\troubleshooting.md', '{#TroubleshootingDocHash}', False);
  WriteManifestRecord(7, 'data\obs-plugins\obs-auto-framing\docs\LICENSE', '{#LicenseHash}', False);
  WriteManifestRecord(8, 'data\obs-plugins\obs-auto-framing\docs\README.md', '{#ReadmeHash}', False);
  WriteManifestRecord(9, 'data\obs-plugins\obs-auto-framing\docs\SECURITY.md', '{#SecurityHash}', False);
  WriteManifestRecord(10, 'data\obs-plugins\obs-auto-framing\docs\THIRD_PARTY_NOTICES.md', '{#NoticesHash}', False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    WriteOwnershipManifest()
  else if CurStep = ssPostInstall then
    SetIniString('Metadata', 'Complete', 'true', ManifestPath());
end;

function SafeOwnedPath(Root: String; RelativePath: String; var FullPath: String): Boolean;
var
  RootPrefix: String;
  NormalizedPath: String;
begin
  Result := False;
  if RelativePath = '' then
    exit;

  NormalizedPath := RelativePath;
  StringChangeEx(NormalizedPath, '/', '\', True);
  if (ExtractFileDrive(RelativePath) <> '') or
     (RelativePath[1] = '\') or
     (RelativePath[1] = '/') or
     (Pos(':', RelativePath) > 0) or
     (Pos('\..\', '\' + NormalizedPath + '\') > 0) then
    exit;

  RootPrefix := AddBackslash(ExpandFileName(Root));
  FullPath := ExpandFileName(RootPrefix + RelativePath);
  Result := CompareText(Copy(FullPath, 1, Length(RootPrefix)), RootPrefix) = 0;
end;

procedure RemoveOwnedFile(Index: Integer; Root: String);
var
  Section: String;
  RelativePath: String;
  InstalledHash: String;
  FullPath: String;
  CurrentHash: String;
  CreatedByInstaller: Boolean;
  SharedRuntime: Boolean;
begin
  Section := 'File.' + IntToStr(Index);
  RelativePath := GetIniString(Section, 'RelativePath', '', ManifestPath());
  InstalledHash := GetIniString(Section, 'InstalledSHA256', '', ManifestPath());
  CreatedByInstaller := CompareText(GetIniString(Section, 'CreatedByInstaller', 'false', ManifestPath()), 'true') = 0;
  SharedRuntime := CompareText(GetIniString(Section, 'SharedRuntime', 'false', ManifestPath()), 'true') = 0;

  if not SafeOwnedPath(Root, RelativePath, FullPath) then
  begin
    Log('Preserved unsafe or invalid manifest path: ' + RelativePath);
    exit;
  end;
  if not FileExists(FullPath) then
  begin
    Log('Owned file already absent: ' + FullPath);
    exit;
  end;
  if InstalledHash = '' then
  begin
    Log('Preserved file with missing installed hash: ' + FullPath);
    exit;
  end;

  CurrentHash := Lowercase(GetSHA256OfFile(FullPath));
  if CompareText(CurrentHash, InstalledHash) <> 0 then
  begin
    Log('Preserved file modified after installation: ' + FullPath);
    exit;
  end;
  if not CreatedByInstaller then
  begin
    if SharedRuntime then
      Log('Preserved pre-existing shared ONNX Runtime: ' + FullPath)
    else
      Log('Preserved file that existed before installation: ' + FullPath);
    exit;
  end;

  if DeleteFile(FullPath) then
    Log('Removed installer-owned file: ' + FullPath)
  else
    Log('Could not remove installer-owned file: ' + FullPath);
end;

procedure RemoveEmptyPluginDirectories(Root: String);
var
  PluginDataRoot: String;
begin
  PluginDataRoot := AddBackslash(Root) + 'data\obs-plugins\{#PluginName}';
  RemoveDir(PluginDataRoot + '\docs');
  RemoveDir(PluginDataRoot + '\models');
  RemoveDir(PluginDataRoot + '\locale');
  RemoveDir(PluginDataRoot + '\effects');
  RemoveDir(PluginDataRoot + '\installer');
  RemoveDir(PluginDataRoot);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Index: Integer;
  Root: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    Root := ExpandConstant('{app}');
    if not ObsRootIsValid(Root) then
    begin
      Log('Uninstall refused ownership cleanup because the recorded root is no longer a valid OBS root: ' + Root);
      exit;
    end;

    for Index := 0 to ManifestFileCount - 1 do
      RemoveOwnedFile(Index, Root);
    DeleteFile(ManifestPath());
    RemoveEmptyPluginDirectories(Root);
  end;
end;
