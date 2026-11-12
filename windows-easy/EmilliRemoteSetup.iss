; Emilli Remote Setup
;
; A next-next Windows installer for PCs that use our RustDesk server, rd.emillis.net.
; It carries RustDesk 1.5.3 for Windows as built by LoomNaru Labs from the branch windows-153
; of https://github.com/LoomNaru-Labs/emilli-remote (upstream code with the Emilli Remote icon,
; no update check and "Emilli Remote" as the shown name; SHA-256 checked when this file is
; compiled and again on the PC before it runs) and drives RustDesk's own command line:
;   rustdesk-1.5.3-x86_64.exe --silent-install       installs RustDesk and its service
;   rustdesk.exe --config "host=...,key=...,api=..."  saves our server in the service
;   rustdesk.exe --option <name> <value>             store PC: password only, no click-accept
;   rustdesk.exe --password "<password>"             store PC: the permanent password
;   rustdesk.exe --get-id                            the ID shown on the last page
; (src/core_main.rs at RustDesk tags 1.5.0 and 1.5.3; --config, --option and --password need an
; installed RustDesk and administrator rights, so this Setup always runs as administrator.)
;
; Silent use, for IT and for the CI test:
;   Emilli-Remote-Setup-1.5.3.exe /VERYSILENT /SUPPRESSMSGBOXES /MODE=store /PWFILE=<file> [/IDFILE=<file>] [/LOG=<file>]
;   Emilli-Remote-Setup-1.5.3.exe /VERYSILENT /SUPPRESSMSGBOXES /MODE=control [/IDFILE=<file>] [/LOG=<file>]
; The password file holds the store PC password on its first line. Setup never writes the
; password to its log. Exit code 0 means every step worked, 10 means a step failed.
;
; Compile: ISCC.exe /DRustDeskDir=<folder holding rustdesk-1.5.3-x86_64.exe> EmilliRemoteSetup.iss

#define AppVersion "1.5.3"
#define RustDeskExe "rustdesk-1.5.3-x86_64.exe"
#define RustDeskSha256 "396a7f9fd91f4800a5cd491eeec3ef30bae08f58a75786eff2e685c80bd0dfab"
; The values the download page publishes: ID server, empty relay (RustDesk then uses the
; ID server's host), API server for login, and the server's public key.
#define ServerConfig "host=rd.emillis.net,key=EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A=,api=https://rd.emillis.net,"

#ifndef RustDeskDir
  #error Pass /DRustDeskDir=<folder that holds rustdesk-1.5.3-x86_64.exe from branch windows-153>
#endif
#if LowerCase(GetSHA256OfFile(AddBackslash(RustDeskDir) + RustDeskExe)) != RustDeskSha256
  #error The RustDesk installer does not match the pinned SHA-256
#endif

[Setup]
AppId=EmilliRemoteSetup
AppName=Emilli Remote
AppVersion={#AppVersion}
AppVerName=Emilli Remote {#AppVersion}
AppPublisher=LoomNaru Labs Inc
AppPublisherURL=https://github.com/LoomNaru-Labs/emilli-remote
AppCopyright=Contains RustDesk {#AppVersion}, AGPL-3.0, by Purslane Tech Pte. Ltd. and the RustDesk contributors
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=LoomNaru Labs Inc
VersionInfoDescription=Emilli Remote Setup (RustDesk {#AppVersion} by LoomNaru Labs for rd.emillis.net)
VersionInfoProductName=Emilli Remote
VersionInfoProductVersion={#AppVersion}
CreateAppDir=no
Uninstallable=no
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
; The Emilli Remote icon and pictures (deploy/rustdesk-icons/make_icon_set.py in rustdesk-apps).
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

[Files]
Source: "{#RustDeskDir}\{#RustDeskExe}"; Flags: dontcopy

[Code]
const
  RustDeskExe = '{#RustDeskExe}';
  RustDeskSha256 = '{#RustDeskSha256}';
  ServerConfig = '{#ServerConfig}';
  IpcPipe = '\\.\pipe\RustDesk\query';
  FailExitCode = 10;

var
  ChoicePage: TWizardPage;
  StoreRadio, ControlRadio: TNewRadioButton;
  PasswordPage: TInputQueryWizardPage;
  IdLabel, NextStepLabel, NoteLabel: TNewStaticText;
  CopyButton: TNewButton;
  StoreMode: Boolean;
  StorePassword: String;
  RustDeskId: String;
  InstallError: String;

function WaitNamedPipe(Name: String; TimeOut: Cardinal): Integer;
  external 'WaitNamedPipeW@kernel32.dll stdcall';

function InstalledExe: String;
begin
  Result := ExpandConstant('{commonpf64}\RustDesk\rustdesk.exe');
end;

procedure Fail(const Msg: String);
begin
  if InstallError = '' then
    InstallError := Msg;
  Log('Emilli: FAILED: ' + Msg);
end;

{ Runs the installed RustDesk with Params and returns its first non-empty output line.
  Nothing here logs Params, so the password never reaches the log. }
function RunRustDesk(const Params: String; var FirstLine: String): Boolean;
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

{ 123456789 -> 123 456 789, as RustDesk shows it. }
function GroupedId(const S: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    if (I > 1) and ((Length(S) - I + 1) mod 3 = 0) then
      Result := Result + ' ';
    Result := Result + S[I];
  end;
end;

{ Store PC passwords are passed in double quotes on RustDesk's command line, so a double
  quote or a backslash could change what RustDesk receives. }
function PasswordProblem(const Pw, Again: String): String;
begin
  Result := '';
  if Pw <> Again then
    Result := '두 비밀번호가 다릅니다.' + #13#10 + 'The two passwords differ.'
  else if Length(Pw) < 8 then
    Result := '8자 이상으로 정해 주세요.' + #13#10 + 'Use at least 8 characters.'
  else if Length(Pw) > 64 then
    Result := '64자 이하로 정해 주세요.' + #13#10 + 'Use at most 64 characters.'
  else if (Pos('"', Pw) > 0) or (Pos('\', Pw) > 0) then
    Result := '큰따옴표(")와 역슬래시(\)는 쓸 수 없습니다.' + #13#10 + 'Do not use " or \.'
  else if Trim(Pw) <> Pw then
    Result := '앞뒤에 빈칸을 넣지 마세요.' + #13#10 + 'No spaces at the start or end.';
end;

{ True while the RustDesk app that the packer started is still installing. }
function InstallerStillRunning: Boolean;
var
  Locator, Service, Procs: Variant;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Procs := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name LIKE ''rustdesk%'' ' +
      'AND CommandLine LIKE ''%--silent-install%''');
    Result := Procs.Count > 0;
  except
    Log('Emilli: cannot list processes: ' + GetExceptionMessage);
  end;
end;

function WaitForInstaller(Seconds: Integer): Boolean;
var
  I: Integer;
begin
  for I := 1 to Seconds do
  begin
    if not InstallerStillRunning then
    begin
      Log('Emilli: RustDesk installer finished after about ' + IntToStr(I + 1) + ' s');
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
  WizardForm.ProgressGauge.Max := 6;
  WizardForm.ProgressGauge.Position := Step;
  Log('Emilli: step ' + IntToStr(Step) + ': ' + Text);
end;

procedure DoInstall;
var
  Src, Answer: String;
  ResultCode, PwTries: Integer;
begin
  { 1. The RustDesk installer (our windows-153 build), checked again before it runs. }
  SetStatus('RustDesk 설치 중  /  Installing RustDesk', 1);
  ExtractTemporaryFile(RustDeskExe);
  Src := ExpandConstant('{tmp}\') + RustDeskExe;
  if LowerCase(GetSHA256OfFile(Src)) <> RustDeskSha256 then
  begin
    Fail('The RustDesk installer inside this Setup is damaged (SHA-256 mismatch).');
    Exit;
  end;
  { The file is RustDesk's packer (libs/portable): it unpacks the app and starts it
    with the same arguments without waiting, so wait below for the installed copy and its
    service. The working folder is the system folder, not Setup's temporary folder, so Setup
    can still remove its temporary folder at the end. }
  if not Exec(Src, '--silent-install', ExpandConstant('{sys}'), SW_HIDE, ewWaitUntilTerminated,
    ResultCode) then
  begin
    Fail('RustDesk could not start: ' + SysErrorMessage(ResultCode));
    Exit;
  end;
  Sleep(2000);
  if not WaitForInstaller(300) then
  begin
    Fail('The RustDesk installer was still running after 5 minutes.');
    Exit;
  end;
  if not WaitForFile(InstalledExe, 30) then
  begin
    Fail('RustDesk was not installed (no ' + InstalledExe + ').');
    Exit;
  end;
  Log('Emilli: RustDesk installed at ' + InstalledExe);

  { 2. The RustDesk service must answer before settings can be saved in it. }
  SetStatus('RustDesk 서비스 기다리는 중  /  Waiting for the RustDesk service', 2);
  if not WaitForService(120) then
  begin
    Fail('The RustDesk service did not start within 2 minutes.');
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
  RunRustDesk('--option custom-rendezvous-server', Answer);
  Log('Emilli: ID server now "' + Answer + '"');
  if Answer <> 'rd.emillis.net' then
  begin
    Fail('The server was not saved (ID server reads "' + Answer + '").');
    Exit;
  end;
  RunRustDesk('--option api-server', Answer);
  Log('Emilli: API server now "' + Answer + '"');
  if Answer <> 'https://rd.emillis.net' then
  begin
    Fail('The login server was not saved (API server reads "' + Answer + '").');
    Exit;
  end;

  { 4. Store PC: accept connections by password only, and the permanent password. }
  if StoreMode then
  begin
    SetStatus('매장 PC 비밀번호 설정 중  /  Setting the store PC password', 4);
    Exec(InstalledExe, '--option verification-method use-permanent-password', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    Exec(InstalledExe, '--option approve-mode password', '', SW_HIDE, ewWaitUntilTerminated,
      ResultCode);
    { RustDesk 1.5.1+ sets the password in the service and then copies the service's settings
      into this user's settings (src/ipc.rs, sync_security_config_from_server). In REMOTE-153
      run 43150734804, a reinstall after the app had run without installing, only that copy
      failed. Try three times; when only the copy failed, the service has the password, which
      is the one connections are checked against. }
    PwTries := 0;
    repeat
      PwTries := PwTries + 1;
      RunRustDesk('--password "' + StorePassword + '"', Answer);
      if Answer <> 'Done!' then
      begin
        Log('Emilli: setting the password, try ' + IntToStr(PwTries) + ': RustDesk said "' + Answer + '"');
        if PwTries < 3 then
          Sleep(2000);
      end;
    until (Answer = 'Done!') or (PwTries >= 3);
    if (Answer <> 'Done!') and (Pos('Host security update succeeded', Answer) = 1) then
    begin
      Log('Emilli: the service has the store PC password; only this user''s copy of the settings was not refreshed');
      Answer := 'Done!';
    end;
    if Answer <> 'Done!' then
    begin
      Fail('The store PC password was not set (RustDesk said "' + Answer + '").');
      Exit;
    end;
    Log('Emilli: store PC password set');
    RunRustDesk('--option verification-method', Answer);
    Log('Emilli: verification-method now "' + Answer + '"');
    if Answer <> 'use-permanent-password' then
    begin
      Fail('The password mode was not saved.');
      Exit;
    end;
  end;

  { 5. The ID for the last page. }
  SetStatus('ID 확인 중  /  Reading the ID', 5);
  RunRustDesk('--get-id', Answer);
  if not IsDigits(Answer) then
  begin
    Fail('RustDesk did not give an ID ("' + Answer + '").');
    Exit;
  end;
  RustDeskId := Answer;
  Log('Emilli: ID ' + RustDeskId);
  SetStatus('끝  /  Done', 6);
  Log('Emilli: done, mode ' + ExpandConstant('{param:MODE|wizard}'));
end;

procedure CopyIdClick(Sender: TObject);
var
  ResultCode: Integer;
begin
  if Exec(ExpandConstant('{cmd}'), '/C echo|set /p="' + RustDeskId + '"|clip', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
    CopyButton.Caption := '복사됨  /  Copied'
  else
    CopyButton.Caption := '복사 안 됨  /  Not copied';
end;

function AddHint(Page: TWizardPage; const Text: String; Top: Integer): TNewStaticText;
begin
  Result := TNewStaticText.Create(Page);
  Result.Parent := Page.Surface;
  Result.Left := ScaleX(18);
  Result.Top := Top;
  Result.Width := Page.SurfaceWidth - ScaleX(18);
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Caption := Text;
  WizardForm.AdjustLabelHeight(Result);
end;

function AddRadio(Page: TWizardPage; const Text: String; Top: Integer): TNewRadioButton;
begin
  Result := TNewRadioButton.Create(Page);
  Result.Parent := Page.Surface;
  Result.Left := 0;
  Result.Top := Top;
  Result.Width := Page.SurfaceWidth;
  Result.Height := ScaleY(22);
  Result.Font.Style := [fsBold];
  Result.Caption := Text;
end;

procedure InitializeWizard;
var
  Hint, Footer: TNewStaticText;
  Y: Integer;
begin
  ChoicePage := CreateCustomPage(wpWelcome, 'Emilli 원격 설치  /  Emilli Remote Setup',
    '이 PC를 어떻게 쓰나요?  /  How will this PC be used?');

  StoreRadio := AddRadio(ChoicePage, '이 PC를 원격으로 받기 (매장 PC)', 0);
  Hint := AddHint(ChoicePage,
    'Let others reach this PC (store PC). 다음 화면에서 매장 PC 비밀번호를 정합니다. ' +
    '이 PC에서는 로그인하지 않습니다. You set a store PC password next; nobody logs in on this PC.',
    StoreRadio.Top + StoreRadio.Height);
  Y := Hint.Top + Hint.Height + ScaleY(14);

  ControlRadio := AddRadio(ChoicePage, '다른 PC를 조종하기', Y);
  Hint := AddHint(ChoicePage,
    'Control other PCs. 설치 뒤 내 계정으로 로그인합니다. You log in with your own account after setup.',
    ControlRadio.Top + ControlRadio.Height);
  Y := Hint.Top + Hint.Height + ScaleY(22);

  Footer := TNewStaticText.Create(ChoicePage);
  Footer.Parent := ChoicePage.Surface;
  Footer.Left := 0;
  Footer.Top := Y;
  Footer.Width := ChoicePage.SurfaceWidth;
  Footer.AutoSize := False;
  Footer.WordWrap := True;
  Footer.Caption :=
    'Emilli 원격(RustDesk {#AppVersion} 기반)을 설치하고 Emilli 서버(rd.emillis.net)에 연결합니다. ' +
    '이 PC에 RustDesk가 이미 있으면 다시 설치하고 이 서버로 바꿉니다.' + #13#10 +
    'Installs Emilli Remote (based on RustDesk {#AppVersion}) and connects it to the Emilli server ' +
    '(rd.emillis.net). A RustDesk already on this PC is reinstalled and switched to this server. ' +
    'Open source (AGPL-3.0): github.com/LoomNaru-Labs/emilli-remote';
  WizardForm.AdjustLabelHeight(Footer);

  PasswordPage := CreateInputQueryPage(ChoicePage.ID,
    '매장 PC 비밀번호  /  Store PC password',
    '원격으로 이 PC에 들어올 때 쓰는 비밀번호입니다.  /  The password used to reach this PC.',
    '8자 이상, 계정 비밀번호와 다르게 정하세요. 큰따옴표와 역슬래시는 쓸 수 없습니다.' + #13#10 +
    'At least 8 characters, different from any account password. No " or \.');
  PasswordPage.Add('비밀번호  /  Password:', True);
  PasswordPage.Add('한 번 더  /  Again:', True);

  IdLabel := TNewStaticText.Create(WizardForm);
  IdLabel.Parent := WizardForm.FinishedPage;
  IdLabel.Font.Size := 26;
  IdLabel.Font.Style := [fsBold];
  IdLabel.Visible := False;

  CopyButton := TNewButton.Create(WizardForm);
  CopyButton.Parent := WizardForm.FinishedPage;
  CopyButton.Caption := '복사  /  Copy';
  CopyButton.Width := ScaleX(110);
  CopyButton.Height := ScaleY(26);
  CopyButton.OnClick := @CopyIdClick;
  CopyButton.Visible := False;

  NextStepLabel := TNewStaticText.Create(WizardForm);
  NextStepLabel.Parent := WizardForm.FinishedPage;
  NextStepLabel.AutoSize := False;
  NextStepLabel.WordWrap := True;
  NextStepLabel.Font.Style := [fsBold];
  NextStepLabel.Visible := False;

  NoteLabel := TNewStaticText.Create(WizardForm);
  NoteLabel.Parent := WizardForm.FinishedPage;
  NoteLabel.AutoSize := False;
  NoteLabel.WordWrap := True;
  NoteLabel.Visible := False;
end;

function InitializeSetup: Boolean;
var
  Mode, PwFile: String;
  Lines: TArrayOfString;
begin
  Result := True;
  if WizardSilent then
  begin
    Mode := LowerCase(ExpandConstant('{param:MODE|}'));
    if (Mode <> 'store') and (Mode <> 'control') then
    begin
      Log('Emilli: silent Setup needs /MODE=store or /MODE=control');
      Result := False;
      Exit;
    end;
    StoreMode := Mode = 'store';
    if StoreMode then
    begin
      PwFile := ExpandConstant('{param:PWFILE|}');
      if (PwFile = '') or not LoadStringsFromFile(PwFile, Lines) or (GetArrayLength(Lines) = 0) then
      begin
        Log('Emilli: silent store Setup needs /PWFILE=<file with the password>');
        Result := False;
        Exit;
      end;
      StorePassword := Lines[0];
      if PasswordProblem(StorePassword, StorePassword) <> '' then
      begin
        Log('Emilli: the password in /PWFILE breaks the password rules');
        Result := False;
        Exit;
      end;
    end;
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = PasswordPage.ID) and not StoreRadio.Checked;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Problem: String;
begin
  Result := True;
  { Setup "clicks" Next on silent installs too; the mode and password then come from
    /MODE and /PWFILE, read in InitializeSetup. }
  if WizardSilent then
    Exit;
  if CurPageID = ChoicePage.ID then
  begin
    if not StoreRadio.Checked and not ControlRadio.Checked then
    begin
      MsgBox('둘 중 하나를 골라 주세요.' + #13#10 + 'Choose one of the two.', mbInformation, MB_OK);
      Result := False;
      Exit;
    end;
    StoreMode := StoreRadio.Checked;
  end
  else if CurPageID = PasswordPage.ID then
  begin
    Problem := PasswordProblem(PasswordPage.Values[0], PasswordPage.Values[1]);
    if Problem <> '' then
    begin
      MsgBox(Problem, mbError, MB_OK);
      Result := False;
      Exit;
    end;
    StorePassword := PasswordPage.Values[0];
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  IdFile: String;
begin
  if CurStep = ssPostInstall then
  begin
    DoInstall;
    StorePassword := '';
    if not WizardSilent then
    begin
      PasswordPage.Values[0] := '';
      PasswordPage.Values[1] := '';
    end;
    IdFile := ExpandConstant('{param:IDFILE|}');
    if (InstallError = '') and (IdFile <> '') then
      SaveStringToFile(IdFile, RustDeskId, False);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Y, W: Integer;
begin
  if CurPageID <> wpFinished then
    Exit;
  W := WizardForm.FinishedLabel.Width;
  if InstallError = '' then
  begin
    WizardForm.FinishedHeadingLabel.Caption := '설치가 끝났습니다' + #13#10 + 'Setup is done';
    WizardForm.FinishedLabel.Caption := '이 PC의 ID  /  This PC''s ID';
  end
  else
  begin
    WizardForm.FinishedHeadingLabel.Caption := '설치가 끝나지 않았습니다' + #13#10 + 'Setup did not finish';
    WizardForm.FinishedLabel.Caption :=
      '이 화면을 사진 찍어 Emilli 담당자에게 보내 주세요.' + #13#10 +
      'Take a photo of this screen and send it to your Emilli contact.' + #13#10 + #13#10 + InstallError;
  end;
  WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  if InstallError <> '' then
    Exit;

  Y := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + ScaleY(6);
  IdLabel.Left := WizardForm.FinishedLabel.Left;
  IdLabel.Top := Y;
  IdLabel.Caption := GroupedId(RustDeskId);
  IdLabel.Visible := True;

  CopyButton.Left := WizardForm.FinishedLabel.Left;
  CopyButton.Top := IdLabel.Top + IdLabel.Height + ScaleY(6);
  CopyButton.Visible := True;

  NextStepLabel.Left := WizardForm.FinishedLabel.Left;
  NextStepLabel.Top := CopyButton.Top + CopyButton.Height + ScaleY(18);
  NextStepLabel.Width := W;
  if StoreMode then
    NextStepLabel.Caption := '이 ID를 매장 이름과 함께 Emilli 담당자에게 보내 주세요.' + #13#10 +
      'Send this ID with the store name to your Emilli contact.'
  else
    NextStepLabel.Caption := '바탕화면의 RustDesk를 열고 내 계정으로 로그인하세요.' + #13#10 +
      'Open RustDesk from the desktop and log in with your account.';
  WizardForm.AdjustLabelHeight(NextStepLabel);
  NextStepLabel.Visible := True;

  NoteLabel.Left := WizardForm.FinishedLabel.Left;
  NoteLabel.Top := NextStepLabel.Top + NextStepLabel.Height + ScaleY(12);
  NoteLabel.Width := W;
  if StoreMode then
    NoteLabel.Caption := '이 PC에서는 RustDesk에 로그인하지 마세요.' + #13#10 +
      'Do not log in to RustDesk on this PC.'
  else
    NoteLabel.Caption := '계정이 없으면 받은 초대 링크로 먼저 만드세요.' + #13#10 +
      'No account yet? Make one with your invite link first.';
  WizardForm.AdjustLabelHeight(NoteLabel);
  NoteLabel.Visible := True;
end;

function GetCustomSetupExitCode: Integer;
begin
  if InstallError <> '' then
    Result := FailExitCode
  else
    Result := 0;
end;
