; Emilli Remote Setup (REMOTE-EASY-3: one path, no choices)
;
; One page, one button: it installs Emilli Remote (our build of RustDesk 1.5.3, version 1.5.4, from branch
; easy3-windows of https://github.com/LoomNaru-Labs/emilli-remote, internal name "EmilliRemote",
; shown as "Emilli Remote" everywhere), saves our server in it and opens it. The person then
; presses "가입" (sign up) or "로그인" (sign in) in the app; PCs signed in to the same account open
; each other from "내 기기" without a PC password. Nothing here sets a PC password or asks what
; the PC is for.
;
; Command line of the installed program it drives (src/core_main.rs; administrator rights):
;   <program> --silent-install                        installs the program and its service
;   EmilliRemote.exe --config "host=...,key=...,api=..."  saves the server in the service
;   EmilliRemote.exe --option <name>                  reads a setting back
;   EmilliRemote.exe --get-id                         this PC's number (for the test only)
;
; An earlier remote program installed under the old name (the plain download of the old guide,
; or Emilli Remote Setup before this round) is removed first; this PC keeps its number, so the
; account server still knows it.
;
; Silent use, for IT and for the CI test:
;   Emilli-Remote-Setup-1.5.4.exe /VERYSILENT /SUPPRESSMSGBOXES [/IDFILE=<file>] [/LOG=<file>]
; Exit code 0 means every step worked, 10 means a step failed.
;
; Compile: ISCC.exe /DProgramDir=<folder with the program> /DProgramSha256=<its SHA-256> EmilliRemoteSetup.iss
; The CI end-to-end test compiles the same script with /DServerHost, /DServerKey and /DApiUrl
; pointing at a test server on the runner; the release build uses the defaults below.

#define AppVersion "1.5.4"
#define ProgramExe "rustdesk-1.5.4-x86_64.exe"
#define ProgramName "EmilliRemote-1.5.4-x86_64.exe"
#ifndef ServerHost
  #define ServerHost "rd.emillis.net"
#endif
#ifndef ServerKey
  ; The server's public key, as the download page publishes it.
  #define ServerKey "EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A="
#endif
#ifndef ApiUrl
  #define ApiUrl "https://rd.emillis.net"
#endif
; Empty relay: the program then uses the ID server's host for the relay.
#define ServerConfig "host=" + ServerHost + ",key=" + ServerKey + ",api=" + ApiUrl + ","

#ifndef ProgramDir
  #error Pass /DProgramDir=<folder that holds rustdesk-1.5.3-x86_64.exe from branch easy3-windows>
#endif
#ifndef ProgramSha256
  #error Pass /DProgramSha256=<SHA-256 of that file>
#endif
#if LowerCase(GetSHA256OfFile(AddBackslash(ProgramDir) + ProgramExe)) != LowerCase(ProgramSha256)
  #error The program does not match the pinned SHA-256
#endif

[Setup]
AppId=EmilliRemoteSetup
AppName=Emilli Remote
AppVersion={#AppVersion}
AppVerName=Emilli Remote {#AppVersion}
AppPublisher=LoomNaru Labs Inc
AppPublisherURL=https://github.com/LoomNaru-Labs/emilli-remote
AppCopyright=LoomNaru Labs Inc. Open source, AGPL-3.0.
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=LoomNaru Labs Inc
VersionInfoDescription=Emilli Remote Setup
VersionInfoProductName=Emilli Remote
VersionInfoProductVersion={#AppVersion}
VersionInfoCopyright=LoomNaru Labs Inc. Open source, AGPL-3.0.
CreateAppDir=no
; The program registers its own entry "Emilli Remote" in Windows' installed apps; Setup adds none.
Uninstallable=no
DisableWelcomePage=yes
DisableReadyPage=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=emilli-remote.ico
WizardImageFile=setup-large.bmp,setup-large-2x.bmp
WizardSmallImageFile=setup-small.bmp,setup-small-2x.bmp
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage
CloseApplications=no
OutputDir=output
OutputBaseFilename=Emilli-Remote-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "ko"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Messages]
ko.SetupAppTitle=Emilli Remote 설치
ko.SetupWindowTitle=Emilli Remote 설치
en.SetupAppTitle=Emilli Remote Setup
en.SetupWindowTitle=Emilli Remote Setup

[Files]
Source: "{#ProgramDir}\{#ProgramExe}"; DestName: "{#ProgramName}"; Flags: dontcopy

[Run]
Filename: "{code:InstalledExePath}"; Description: "Emilli Remote 열기  /  Open Emilli Remote"; Flags: postinstall nowait runasoriginaluser skipifsilent; Check: InstallOk

[Code]
const
  ProgramName = '{#ProgramName}';
  ProgramSha256 = '{#ProgramSha256}';
  ServerConfig = '{#ServerConfig}';
  ServerHost = '{#ServerHost}';
  ApiUrl = '{#ApiUrl}';
  IpcPipe = '\\.\pipe\EmilliRemote\query';
  FailExitCode = 10;

var
  PcId: String;
  InstallError: String;

function WaitNamedPipe(Name: String; TimeOut: Cardinal): Integer;
  external 'WaitNamedPipeW@kernel32.dll stdcall';

function InstalledExe: String;
begin
  Result := ExpandConstant('{commonpf64}\EmilliRemote\EmilliRemote.exe');
end;

function InstalledExePath(Param: String): String;
begin
  Result := InstalledExe;
end;

function InstallOk: Boolean;
begin
  Result := InstallError = '';
end;

procedure Fail(const Msg: String);
begin
  if InstallError = '' then
    InstallError := Msg;
  Log('Emilli: FAILED: ' + Msg);
end;

{ Runs the installed program with Params and returns its first non-empty output line. }
function RunProgram(const Params: String; var FirstLine: String): Boolean;
var
  ResultCode, I: Integer;
  Output: TExecOutput;
begin
  Result := False;
  FirstLine := '';
  try
    Result := ExecAndCaptureOutput(InstalledExe, Params, '', SW_HIDE, ewWaitUntilTerminated,
      ResultCode, Output);
  except
    Result := False;
  end;
  if Result then
    for I := 0 to GetArrayLength(Output.StdOut) - 1 do
      if (FirstLine = '') and (Trim(Output.StdOut[I]) <> '') then
        FirstLine := Trim(Output.StdOut[I]);
end;

function IsDigits(const S: String): Boolean;
var
  I: Integer;
begin
  Result := (Length(S) >= 6) and (Length(S) <= 12);
  for I := 1 to Length(S) do
    if (S[I] < '0') or (S[I] > '9') then
      Result := False;
end;

{ Processes whose image name starts with Prefix and whose command line contains Part. }
function ProcessCount(const Prefix, Part: String): Integer;
var
  Locator, Service, Procs: Variant;
begin
  Result := 0;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    if Part = '' then
      Procs := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name LIKE ''' + Prefix + '%''')
    else
      Procs := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name LIKE ''' + Prefix +
        '%'' AND CommandLine LIKE ''%' + Part + '%''');
    Result := Procs.Count;
  except
    Log('Emilli: cannot list processes: ' + GetExceptionMessage);
  end;
end;

function InstallerStillRunning: Boolean;
begin
  Result := (ProcessCount('rustdesk', '--silent-install') + ProcessCount('EmilliRemote', '--silent-install')) > 0;
end;

function WaitForInstaller(Seconds: Integer): Boolean;
var
  I: Integer;
begin
  for I := 1 to Seconds do
  begin
    if not InstallerStillRunning then
    begin
      Log('Emilli: the program''s installer finished after about ' + IntToStr(I + 1) + ' s');
      Result := True;
      Exit;
    end;
    Sleep(1000);
  end;
  Result := not InstallerStillRunning;
end;

function WaitForFile(const FileName: String; Seconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := FileExists(FileName);
  for I := 1 to Seconds do
  begin
    if Result then
      Exit;
    Sleep(1000);
    Result := FileExists(FileName);
  end;
end;

function WaitForService(Seconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Seconds do
  begin
    if WaitNamedPipe(IpcPipe, 1000) <> 0 then
    begin
      Result := True;
      Exit;
    end;
    Sleep(1000);
  end;
end;

procedure SetStatus(const Text: String; Step: Integer);
begin
  WizardForm.StatusLabel.Caption := Text;
  WizardForm.FilenameLabel.Caption := '';
  WizardForm.ProgressGauge.Min := 0;
  WizardForm.ProgressGauge.Max := 5;
  WizardForm.ProgressGauge.Position := Step;
  Log('Emilli: step ' + IntToStr(Step) + ': ' + Text);
end;

{ An earlier remote program installed under the old name: keep this PC's number (its identity file
  in the service's settings), uninstall it, and end copies that were only run. }
procedure RemoveEarlierProgram;
var
  OldExe, Profile, OldCfg, NewDir, NewCfg: String;
  ResultCode, I: Integer;
begin
  OldExe := ExpandConstant('{commonpf64}\RustDesk\rustdesk.exe');
  Profile := ExpandConstant('{win}\ServiceProfiles\LocalService\AppData\Roaming');
  OldCfg := Profile + '\RustDesk\config\RustDesk.toml';
  NewDir := Profile + '\EmilliRemote\config';
  NewCfg := NewDir + '\EmilliRemote.toml';
  if FileExists(OldExe) then
  begin
    SetStatus('이전 원격 프로그램 정리 중  /  Removing the earlier remote program', 0);
    if FileExists(OldCfg) and not FileExists(NewCfg) then
    begin
      ForceDirectories(NewDir);
      Exec(ExpandConstant('{cmd}'), '/C copy /Y "' + OldCfg + '" "' + NewCfg + '"', '', SW_HIDE,
        ewWaitUntilTerminated, ResultCode);
      if FileExists(NewCfg) then
        Log('Emilli: this PC keeps its number from the earlier program')
      else
        Log('Emilli: could not copy the earlier program''s identity; this PC gets a new number');
    end;
    Exec(OldExe, '--uninstall', ExpandConstant('{sys}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
    for I := 1 to 90 do
    begin
      if not FileExists(OldExe) then
        Break;
      Sleep(1000);
    end;
    Log('Emilli: earlier program removed: ' + IntToStr(Ord(not FileExists(OldExe))));
  end
  else
    Log('Emilli: no earlier remote program installed here');
  { Copies that were only run (for example from the Downloads folder) are ended. }
  if ProcessCount('rustdesk', '') > 0 then
  begin
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM rustdesk*', '', SW_HIDE, ewWaitUntilTerminated,
      ResultCode);
    Log('Emilli: ended running copies of the earlier program (taskkill ' + IntToStr(ResultCode) + ')');
  end;
end;

procedure DoInstall;
var
  Src, Answer: String;
  ResultCode: Integer;
begin
  RemoveEarlierProgram;

  { 1. The program (our easy3-windows build), checked again before it runs. }
  SetStatus('Emilli Remote 설치 중  /  Installing Emilli Remote', 1);
  ExtractTemporaryFile(ProgramName);
  Src := ExpandConstant('{tmp}\') + ProgramName;
  if LowerCase(GetSHA256OfFile(Src)) <> LowerCase(ProgramSha256) then
  begin
    Fail('The program inside this Setup is damaged (SHA-256 mismatch).');
    Exit;
  end;
  { The file unpacks the program and starts it with the same arguments without waiting, so wait
    below for the installed copy and its service. The working folder is the system folder, so
    Setup can still remove its temporary folder at the end. }
  if not Exec(Src, '--silent-install', ExpandConstant('{sys}'), SW_HIDE, ewWaitUntilTerminated,
    ResultCode) then
  begin
    Fail('The program could not start: ' + SysErrorMessage(ResultCode));
    Exit;
  end;
  Sleep(2000);
  if not WaitForInstaller(300) then
  begin
    Fail('The program''s installer was still running after 5 minutes.');
    Exit;
  end;
  if not WaitForFile(InstalledExe, 30) then
  begin
    Fail('Emilli Remote was not installed (no ' + InstalledExe + ').');
    Exit;
  end;
  Log('Emilli: installed at ' + InstalledExe);

  { 2. The service must answer before settings can be saved in it. }
  SetStatus('Emilli Remote 서비스 기다리는 중  /  Waiting for the Emilli Remote service', 2);
  if not WaitForService(120) then
  begin
    Fail('The Emilli Remote service did not start within 2 minutes.');
    Exit;
  end;

  { 3. Our server, then read back from the service. }
  SetStatus('서버 설정 중  /  Saving the server', 3);
  if not Exec(InstalledExe, '--config "' + ServerConfig + '"', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
  begin
    Fail('Saving the server failed: ' + SysErrorMessage(ResultCode));
    Exit;
  end;
  Sleep(1000);
  RunProgram('--option custom-rendezvous-server', Answer);
  Log('Emilli: ID server now "' + Answer + '"');
  if Answer <> ServerHost then
  begin
    Fail('The server was not saved (ID server reads "' + Answer + '").');
    Exit;
  end;
  RunProgram('--option api-server', Answer);
  Log('Emilli: account server now "' + Answer + '"');
  if Answer <> ApiUrl then
  begin
    Fail('The account server was not saved (it reads "' + Answer + '").');
    Exit;
  end;

  { 4. This PC's number, for the log and the test. People never need it. }
  SetStatus('확인 중  /  Checking', 4);
  RunProgram('--get-id', Answer);
  if not IsDigits(Answer) then
  begin
    Fail('The program did not give this PC''s number ("' + Answer + '").');
    Exit;
  end;
  PcId := Answer;
  Log('Emilli: this PC''s number ' + PcId);
  SetStatus('끝  /  Done', 5);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  IdFile: String;
begin
  if CurStep = ssPostInstall then
  begin
    DoInstall;
    IdFile := ExpandConstant('{param:IDFILE|}');
    if (InstallError = '') and (IdFile <> '') then
      SaveStringToFile(IdFile, PcId, False);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpReady then
  begin
    WizardForm.PageNameLabel.Caption := 'Emilli Remote 설치  /  Emilli Remote Setup';
    WizardForm.PageDescriptionLabel.Caption := '이 PC에 Emilli Remote를 설치합니다.  /  Installs Emilli Remote on this PC.';
    WizardForm.ReadyLabel.Caption :=
      '"설치"를 누르세요. Windows가 물으면 "예"를 누릅니다.' + #13#10 +
      '설치가 끝나면 Emilli Remote가 열립니다. 처음이면 "가입", 계정이 있으면 "로그인"을 누르세요. ' +
      '같은 계정으로 로그인한 PC끼리는 "내 기기"에서 한 번 눌러 열 수 있습니다.' + #13#10 + #13#10 +
      'Press "Install". If Windows asks, press "Yes". Emilli Remote then opens: press "Sign up" the ' +
      'first time, or "Sign in" if you have an account. PCs signed in to the same account open each ' +
      'other from "My devices" with one click.' + #13#10 + #13#10 +
      '오픈 소스 (AGPL-3.0)  /  Open source: github.com/LoomNaru-Labs/emilli-remote';
    WizardForm.AdjustLabelHeight(WizardForm.ReadyLabel);
    WizardForm.ReadyMemo.Visible := False;
  end
  else if CurPageID = wpFinished then
  begin
    if InstallError = '' then
    begin
      WizardForm.FinishedHeadingLabel.Caption := '설치가 끝났습니다' + #13#10 + 'Setup is done';
      WizardForm.FinishedLabel.Caption :=
        '열리는 Emilli Remote 창에서 처음이면 "가입", 계정이 있으면 "로그인"을 누르세요.' + #13#10 +
        'In the Emilli Remote window that opens, press "Sign up" the first time, or "Sign in".';
    end
    else
    begin
      WizardForm.FinishedHeadingLabel.Caption := '설치가 끝나지 않았습니다' + #13#10 + 'Setup did not finish';
      WizardForm.FinishedLabel.Caption :=
        '이 화면을 사진 찍어 Emilli 담당자에게 보내 주세요.' + #13#10 +
        'Take a photo of this screen and send it to your Emilli contact.' + #13#10 + #13#10 + InstallError;
    end;
    WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if InstallError <> '' then
    Result := FailExitCode
  else
    Result := 0;
end;
