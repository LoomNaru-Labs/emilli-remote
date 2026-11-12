# Can the other side see and click Windows' system windows on a store PC (brief REMOTE-153,
# hypothesis B)? On a fresh GitHub "windows-latest" runner only: it installs software, changes
# the UAC policy, adds a local user, signs that user in over a Remote Desktop loopback, sets a new
# password for the runner's own user and locks the console. Never run it on a PC that matters.
#
#   powershell -File prompt-measure/measure-prompts.ps1 -Setup <setup.exe> -Packer <rustdesk-x.y.z-x86_64.exe> -Out <folder>
#
# One runner plays both PCs, as in the session captures: the console session is the store PC, a
# second Windows session (a throwaway user signed in through a Remote Desktop loopback) is the
# helper, who connects with the app to 127.0.0.1 (direct access). Four cases, in this order:
#   1. installed with Emilli Remote Setup (store PC mode): the service, an elevation prompt
#      ("allow this app to make changes?") raised on the store PC: does the helper's picture
#      show it, and does the helper's click on "Yes" reach it (the elevated command runs)?
#   2. not installed (the program only run, as a user does with the downloaded file): the same
#      prompt; what the helper sees (the app's message) and whether a click reaches it; the
#      store PC's connection window (its install notice).
#   3. installed again, the lock screen: does the helper see it, and can the helper sign the
#      store PC back in through the session (click, password, Enter)?
# Every result is a line "RESULT <case>: yes|no ..." in the log and in summary.txt; pictures of
# both sides are kept. The script ends without an error even when a case fails (measurement).
# Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Packer,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'

$Dir = 'C:\sc'
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$HelperUser = 'Helper'
$Wall = @(38, 84, 124)
$Peer = '127.0.0.1'
$Shots = Join-Path $Out 'shots'
$Debug = Join-Path $Out 'debug'
$Summary = New-Object System.Collections.ArrayList

function Step([string] $m) { Write-Host ("STEP {0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Note([string] $m) { Write-Host "  $m" }
function Result([string] $name, [bool] $ok, [string] $detail) {
    $line = "RESULT ${name}: $(if ($ok) { 'yes' } else { 'no' }) - $detail"
    Write-Host $line
    [void]$Summary.Add($line)
}
function Wait-Until([scriptblock] $Condition, [int] $Seconds, [int] $EveryMs = 1000) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $v = & $Condition
        if ($v) { return $v }
        Start-Sleep -Milliseconds $EveryMs
    }
    return (& $Condition)
}
function New-Secret([int] $Length) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
function Ensure-Key([string] $Path) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null } }
function Console-Shot([string] $Name) {
    try { Note "console picture $Name : $([SL]::ShotScreen((Join-Path $Shots "store-$Name.png")))" } catch { Note "console picture $Name failed: $($_.Exception.Message)" }
}

New-Item -ItemType Directory -Force -Path $Out, $Shots, $Debug, $Dir, "$Dir\bin", "$Dir\cmd", "$Dir\done", "$Dir\tmp", "$Dir\out", "$Dir\secret" | Out-Null
# The user's limited processes (the prompt's asker) write their notes here too.
icacls "$Dir\out" /grant "*S-1-5-11:(OI)(CI)M" /Q | Out-Null
$lib = Join-Path $PSScriptRoot '..\session-capture\SessionLib.cs'
Copy-Item -Force $lib "$Dir\bin\SessionLib.cs"
$agentText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\session-capture\helper-agent.ps1'))
if ($agentText -notmatch 'AddMinutes\(40\)') { throw 'helper-agent.ps1 changed: no 40-minute deadline found' }
[System.IO.File]::WriteAllText("$Dir\bin\helper-agent.ps1", ($agentText -replace 'AddMinutes\(40\)', 'AddMinutes(100)'))
Add-Type -ReferencedAssemblies System.Drawing -Path $lib
Add-Type -AssemblyName System.Drawing, System.Security
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Desk {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder buf, int len, out int needed);
    // Name of the desktop that gets the keyboard and mouse now ("Default" when signed in and no
    // prompt is up); empty when this process may not open it (the secure desktop: Winlogon).
    public static string InputDesktop() {
        IntPtr h = OpenInputDesktop(0, false, 0x0001);
        if (h == IntPtr.Zero) return "";
        StringBuilder b = new StringBuilder(256); int n;
        GetUserObjectInformation(h, 2, b, 256, out n);
        CloseDesktop(h);
        return b.ToString();
    }
}
'@

$s = [SL]::Screen()
Note "console: session $([SL]::MySession()), user $env:USERNAME, screen $($s[2])x$($s[3]), $([Environment]::OSVersion.VersionString)"
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal $me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Note "this script runs elevated: $elevated; input desktop now '$([Desk]::InputDesktop())'"

# ---------------------------------------------------------------- helper commands
$script:Seq = 0
function Ask([hashtable] $C, [int] $Timeout = 60) {
    $script:Seq++
    $name = '{0:D3}-{1}.json' -f $script:Seq, $C.op
    $tmp = Join-Path $Dir "tmp\$name"
    ($C | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding ASCII
    Move-Item -Force $tmp (Join-Path $Dir "cmd\$name")
    $donePath = Join-Path $Dir "done\$name"
    $end = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $end) {
        if (Test-Path $donePath) {
            $a = Get-Content -Raw -Path $donePath | ConvertFrom-Json
            Note "helper $($C.op): $($a.result)"
            if (-not $a.ok) { throw "helper $($C.op) failed: $($a.result)" }
            return $a.result
        }
        Start-Sleep -Milliseconds 60
    }
    throw "the helper did not answer $name within $Timeout s"
}
function Helper-Shot([string] $Name) {
    try { Ask @{ op = 'screen'; dir = $Shots; name = "helper-$Name" } 30 | Out-Null } catch { Note "helper picture $Name failed: $($_.Exception.Message)" }
}
function CM-Window {
    $ids = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' } | ForEach-Object { [uint32]$_.ProcessId })
    if ($ids.Count -eq 0) { return $null }
    return [SL]::Windows() | Where-Object { $ids -contains $_.Pid -and $_.Cls -eq 'FLUTTER_RUNNER_WIN32_WINDOW' } | Select-Object -First 1
}
function RustDesk-Processes {
    Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
        "pid $($_.ProcessId) session $($_.SessionId) owner $($o.Domain)\$($o.User) args '$(($_.CommandLine -replace '^"[^"]*"\s*', '') -replace '--password\s+\S+', '--password (hidden)')'"
    }
}

# ---------------------------------------------------------------- UAC on this runner
Step 'UAC policy on this runner (before), then: ask administrators on the secure desktop'
$pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$p = Get-ItemProperty $pol
Note "EnableLUA $($p.EnableLUA); ConsentPromptBehaviorAdmin $($p.ConsentPromptBehaviorAdmin); PromptOnSecureDesktop $($p.PromptOnSecureDesktop); FilterAdministratorToken $($p.FilterAdministratorToken); DisableCAD $($p.DisableCAD)"
$UacOn = ($p.EnableLUA -eq 1)
Set-ItemProperty $pol -Name ConsentPromptBehaviorAdmin -Value 2 -Type DWord
Set-ItemProperty $pol -Name PromptOnSecureDesktop -Value 1 -Type DWord
Note "now ConsentPromptBehaviorAdmin 2 (consent on the secure desktop), PromptOnSecureDesktop 1"
if (-not $UacOn) { Note 'UAC is off on this runner (EnableLUA 0, needs a restart to change): no elevation prompt can appear' }

# The runner's own user gets no prompt (attempt 1, run 43146939371: its "limited" processes ran
# with High Mandatory Level, so Windows elevated without asking). A second administrator, "Clerk",
# is an ordinary one: its programs run with limited rights and Windows asks before elevating, as
# for the person signed in at a store PC. Clerk's program runs in this (the console) session.
$me = Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue
Note "runner user ${env:USERNAME}: SID ends with $(if ($me) { ($me.SID.Value -split '-')[-1] } else { '?' }) (500 = the built-in Administrator, which Windows never asks)"
$clerkPw = 'Ck9' + (New-Secret 17)
New-LocalUser -Name 'Clerk' -Password (ConvertTo-SecureString $clerkPw -AsPlainText -Force) -PasswordNeverExpires -AccountNeverExpires -Description 'Throwaway admin for the prompt measurement' | Out-Null
Add-LocalGroupMember -Group 'Administrators' -Member 'Clerk'
$ClerkCred = New-Object System.Management.Automation.PSCredential ("$env:COMPUTERNAME\Clerk", (ConvertTo-SecureString $clerkPw -AsPlainText -Force))
$clerkPw = $null
# Clerk's first sign-in builds its profile (slow); done now so the prompt later comes quickly.
$first = Start-Process -FilePath cmd.exe -Credential $ClerkCred -LoadUserProfile -WorkingDirectory $Dir -WindowStyle Hidden -ArgumentList @('/c', 'exit') -PassThru
Note "Clerk's profile ready: $($first.WaitForExit(180000))"

# The elevation prompt: Clerk's program (limited rights) asks to run cmd.exe as administrator; if
# the prompt is answered "Yes", the elevated command writes its groups (with "High Mandatory
# Level") to a file.
function Raise-Prompt([string] $Tag) {
    $mark = "$Dir\out\elevated-$Tag.txt"
    Remove-Item -Force $mark -ErrorAction SilentlyContinue
    $cmd = "whoami /groups | Out-File -Encoding ascii $Dir\out\limited-$Tag.txt; Start-Process -FilePath cmd.exe -ArgumentList '/c whoami /groups > $mark' -Verb RunAs"
    Start-Process -FilePath powershell.exe -Credential $ClerkCred -LoadUserProfile -WorkingDirectory $Dir -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    $up = Wait-Until { Get-Process -Name consent -ErrorAction SilentlyContinue } 25 300
    $lim = Get-Content "$Dir\out\limited-$Tag.txt" -ErrorAction SilentlyContinue | Select-String 'Mandatory Level'
    Note "the asking process: $(($lim | ForEach-Object { $_.Line.Trim() -replace '\s+', ' ' }) -join '; ')"
    Note "consent.exe running: $([bool]$up); input desktop as this script sees it: '$([Desk]::InputDesktop())'"
    return [bool]$up
}
function Close-Prompt {
    if (Get-Process -Name consent -ErrorAction SilentlyContinue) {
        try { Stop-Process -Name consent -Force; Note 'consent.exe ended by the script' } catch { Note "could not end consent.exe: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
}

# Finds the prompt in the helper's view of the store PC and clicks "Yes" there (through the
# session). Returns a description; the proof of the click is the elevated command's file.
function Click-Yes {
    $pic = Ask @{ op = 'picture' } 20
    if ($pic -notmatch 'picture (-?\d+),(-?\d+) (\d+)x(\d+)') { return 'no picture' }
    $px = [int]$Matches[1]; $py = [int]$Matches[2]; $pw = [int]$Matches[3]; $ph = [int]$Matches[4]
    # The dialog: the widest group of columns with many light pixels in the picture.
    $g = Ask @{ op = 'clusters'; kind = 'bright'; min = 60 } 20
    $boxes = @($g -split ' / ' | Where-Object { $_ } | ForEach-Object { $v = $_ -split ','; [pscustomobject]@{ l = [int]$v[0]; t = [int]$v[1]; r = [int]$v[2]; b = [int]$v[3]; n = [int]$v[4] } } | Where-Object { ($_.r - $_.l) -ge 250 })
    if ($boxes.Count -eq 0) { return "no light dialog in the picture ($g)" }
    $d = $boxes | Sort-Object { $_.r - $_.l } -Descending | Select-Object -First 1
    Note "dialog in the helper's view: $($d.l),$($d.t) to $($d.r),$($d.b)"
    # Windows 11 marks "No" with the accent blue (the safe default); "Yes" is the light button of
    # the same size to its left (attempt 3, run 43150734804: a click on the accent button
    # cancelled the prompt).
    $lowY = [int]($d.t + ($d.b - $d.t) * 0.55)
    $a = Ask @{ op = 'clusters'; kind = 'accent'; min = 8; x = $d.l; y = $lowY; w = ($d.r - $d.l + 1); h = ($d.b - $lowY + 1) } 20
    $acc = @($a -split ' / ' | Where-Object { $_ } | ForEach-Object { $v = $_ -split ','; [pscustomobject]@{ l = [int]$v[0]; t = [int]$v[1]; r = [int]$v[2]; b = [int]$v[3]; n = [int]$v[4] } } | Where-Object { ($_.r - $_.l) -ge 40 })
    if ($acc.Count -gt 0) {
        $no = $acc | Sort-Object n -Descending | Select-Object -First 1
        $cx = [int]($no.l - 14 - ($no.r - $no.l) / 2); $cy = [int](($no.t + $no.b) / 2)
        Ask @{ op = 'click-xy'; x = $cx; y = $cy; ms = 500 } 20 | Out-Null
        return "accent button (No) $($no.l),$($no.t) to $($no.r),$($no.b); clicked Yes to its left at $cx,$cy"
    }
    # No accent colour: Yes is the left one of the two buttons along the dialog's bottom.
    $cx = [int]($d.l + ($d.r - $d.l) * 0.28); $cy = [int]($d.b - 32)
    Ask @{ op = 'click-xy'; x = $cx; y = $cy; ms = 500 } 20 | Out-Null
    return "no accent button ($a); clicked the left button place $cx,$cy"
}

$pwFile = Join-Path $Dir 'secret\pw.txt'
[System.IO.File]::WriteAllText($pwFile, (New-Secret 10))

function Install-Store([string] $Tag) {
    Step "Install Emilli Remote Setup as a store PC ($Tag)"
    $setupLog = Join-Path $Debug "setup-$Tag.log"
    $proc = Start-Process -FilePath $Setup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MODE=store', "/PWFILE=$pwFile", "/LOG=$setupLog")
    if (-not $proc.WaitForExit(600000)) { throw 'Setup did not finish in 10 minutes' }
    Note "Setup exit code $($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) { throw 'Setup failed' }
    cmd /c "`"$Exe`" --option direct-server Y > nul 2>&1"
    reg add 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk' /f /v share_rdp /t REG_SZ /d false | Out-Null
    $listen = Wait-Until { Get-NetTCPConnection -LocalPort 21118 -State Listen -ErrorAction SilentlyContinue } 60
    if (-not $listen) { throw 'RustDesk does not listen on 21118' }
    $svc = Get-Service -Name RustDesk -ErrorAction SilentlyContinue
    $wmi = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
    Note "service: $($svc.Status), start $($svc.StartType), account $($wmi.StartName), path $($wmi.PathName)"
    RustDesk-Processes | ForEach-Object { Note $_ }
    $server = Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--server*' -and $_.SessionId -eq [SL]::MySession() }
    $sowner = if ($server) { (Invoke-CimMethod -InputObject ($server | Select-Object -First 1) -MethodName GetOwner).User } else { '' }
    Result "$Tag service" ($svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic' -and $wmi.StartName -eq 'LocalSystem' -and $sowner -eq 'SYSTEM') "service $($svc.Status) / $($svc.StartType) as $($wmi.StartName); the store PC's screen process (--server) in this session runs as '$sowner'"
}
function Uninstall-All {
    Step 'Uninstall'
    if (Test-Path $Exe) {
        $u = Start-Process -FilePath $Exe -ArgumentList '--uninstall' -PassThru
        $u.WaitForExit(120000) | Out-Null
    }
    Wait-Until { -not (Get-Service -Name RustDesk -ErrorAction SilentlyContinue) } 90 2000 | Out-Null
    Get-Process -Name rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Note "service gone: $(-not (Get-Service -Name RustDesk -ErrorAction SilentlyContinue)); program folder gone: $(-not (Test-Path $Exe))"
}

function Connect-Helper([string] $Tag, [bool] $WithPassword, [string] $HelperExe) {
    if ($WithPassword) { Ask @{ op = 'connect'; exe = $HelperExe; peer = $Peer; seconds = 40 } 120 | Out-Null }
    else {
        Ask @{ op = 'connect-nopw'; exe = $HelperExe; peer = $Peer; seconds = 40 } 120 | Out-Null
    }
    Ask @{ op = 'place'; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 20 | Out-Null
    $loc = $null
    for ($i = 0; $i -lt 60 -and -not $loc; $i++) {
        # Accept at most twice: once accepted, the window's blue buttons are others (Install).
        if (-not $WithPassword -and ($i -eq 3 -or $i -eq 30)) { Accept-OnStore | Out-Null }
        $r = Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 20
        # Only the whole picture counts (attempt 3 took an 840-pixel patch at scale 0.35 for it).
        $px = if ($r -match '\((\d+) px\)') { [int]$Matches[1] } else { 0 }
        if ($r -match 'picture at (\d+),(\d+) scale ([0-9.]+)' -and [double]$Matches[3] -ge 0.9 -and $px -ge 200000) { $loc = @([int]$Matches[1], [int]$Matches[2], [double]$Matches[3]) }
        else { Start-Sleep -Milliseconds 700 }
    }
    if (-not $loc) { Helper-Shot "$Tag-not-located"; throw "the store PC picture was not found in the session window ($Tag)" }
    Note "the helper sees the store PC: picture at $($loc[0]),$($loc[1]) scale $($loc[2])"
    $w = CM-Window
    if ($w -and $WithPassword) { [SL]::Show($w.Hwnd, 6) }
}
# The not-installed app asks on the store PC to accept the connection: its connection window
# shows Accept (the app's blue) and Dismiss; the store PC "clicks" Accept here.
function Accept-OnStore {
    $w = CM-Window
    if (-not $w) { return 'no connection window yet' }
    $c = [SL]::Clip($w.Hwnd)
    # Only the bottom row (Accept and Cancel): attempt 5 (run 43151715909) took the blue
    # permission icons above it for the button.
    $g = @([SL]::Clusters($c[0], $c[1] + [int]($c[3] * 0.84), $c[2], [int]($c[3] * 0.16), 'blue', 10) | Where-Object { ($_[2] - $_[0]) -ge 40 -and ($_[3] - $_[1]) -le 60 })
    if ($g.Count -eq 0) { return 'no blue button in the connection window' }
    $b = $g | Sort-Object { $_[4] } -Descending | Select-Object -First 1
    [SL]::Glide([int](($b[0] + $b[2]) / 2), [int](($b[1] + $b[3]) / 2), 300); Start-Sleep -Milliseconds 150; [SL]::Click($false)
    Note "clicked the blue button $($b -join ',') in the store PC's connection window"
    return 'clicked'
}

trap {
    Write-Host "STOPPED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Console-Shot 'stopped'
    Helper-Shot 'stopped'
    [void]$Summary.Add("STOPPED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    $Summary | Set-Content -Path (Join-Path $Out 'summary.txt') -Encoding ASCII
    Copy-Item -Force "$Dir\out\*" $Debug -ErrorAction SilentlyContinue
    Write-Host 'RESULT prompt measurement stopped early (see summary.txt)'
    exit 0
}

# ---------------------------------------------------------------- the helper's Windows session
Install-Store 'installed'

Step 'Throwaway local user, Remote Desktop on, loopback sign-in'
$helperPw = 'Hx7' + (New-Secret 21)
New-LocalUser -Name $HelperUser -Password (ConvertTo-SecureString $helperPw -AsPlainText -Force) -PasswordNeverExpires -AccountNeverExpires -Description 'Throwaway user for the prompt measurement' | Out-Null
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $HelperUser
icacls $Dir /grant "${HelperUser}:(OI)(CI)M" /T /Q | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Start-Service TermService -ErrorAction SilentlyContinue
Ensure-Key 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord
Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
$cd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
Ensure-Key $cd
foreach ($pair in @(@('AllowSavedCredentials', 'ConcatenateDefaults_AllowSaved'), @('AllowSavedCredentialsWhenNTLMOnly', 'ConcatenateDefaults_AllowSavedNTLMOnly'))) {
    Set-ItemProperty $cd -Name $pair[0] -Value 1 -Type DWord
    Set-ItemProperty $cd -Name $pair[1] -Value 1 -Type DWord
    Ensure-Key "$cd\$($pair[0])"
    Set-ItemProperty "$cd\$($pair[0])" -Name '1' -Value 'TERMSRV/*'
}
$tsc = 'HKCU:\Software\Microsoft\Terminal Server Client'
Ensure-Key $tsc
Set-ItemProperty $tsc -Name AuthenticationLevelOverride -Value 0 -Type DWord
Set-ItemProperty $tsc -Name RemoteDesktop_SuppressWhenMinimized -Value 2 -Type DWord
cmdkey "/generic:TERMSRV/127.0.0.2" "/user:$env:COMPUTERNAME\$HelperUser" "/pass:$helperPw" | Out-Null
function Helper-SessionId {
    foreach ($line in (cmd /c "qwinsta 2>nul")) { if ($line -match "\s$HelperUser\s+(\d+)\s+Active") { return [int]$Matches[1] } }
    return $null
}
function Watch-Rdp([int] $Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $sid = Helper-SessionId
        if ($sid -and (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid })) { return $sid }
        foreach ($w in [SL]::Windows()) {
            if ($w.Proc -eq 'mstsc' -and $w.Cls -eq '#32770') {
                Note "Remote Desktop dialog: '$($w.Title)' $([SL]::ChildTexts($w.Hwnd))"
                foreach ($b in @('Connect', 'Yes')) { if ([SL]::ClickButton($w.Hwnd, $b) -gt 0) { Note "  clicked $b" } }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}
Start-Process -FilePath mstsc.exe -ArgumentList @('/v:127.0.0.2', '/w:2560', '/h:1440') | Out-Null
$sid = Watch-Rdp 120
if (-not $sid) {
    Note 'no session with saved credentials; second way: Network Level Authentication off and the password in the connection file'
    Get-Process mstsc -ErrorAction SilentlyContinue | Stop-Process -Force
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0
    $blob = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::Unicode.GetBytes($helperPw), $null, 'CurrentUser')
    $rdp = @(
        'full address:s:127.0.0.2', "username:s:$env:COMPUTERNAME\$HelperUser",
        ('password 51:b:' + (($blob | ForEach-Object { $_.ToString('X2') }) -join '')),
        'enablecredsspsupport:i:0', 'authentication level:i:0', 'prompt for credentials:i:0',
        'desktopwidth:i:2560', 'desktopheight:i:1440', 'screen mode id:i:1', 'session bpp:i:32'
    )
    Set-Content -Path "$Dir\secret\helper.rdp" -Value $rdp -Encoding Unicode
    Start-Process -FilePath mstsc.exe -ArgumentList @("$Dir\secret\helper.rdp") | Out-Null
    $sid = Watch-Rdp 150
}
$helperPw = $null
if (-not $sid) { Console-Shot 'rdp-failed'; throw 'the helper session did not start' }
Note "helper session $sid is signed in"
Start-Sleep -Seconds 8
foreach ($w in [SL]::Windows()) {
    if ($w.Proc -eq 'mstsc' -and $w.Cls -eq 'TscShellContainerClass') {
        [SL]::Place($w.Hwnd, -3200, 60, 1400, 900)
        [SL]::HideFromTaskbar($w.Hwnd)
    }
}
Step 'Start the helper agent in the helper session'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bin\helper-agent.ps1`" -Dir `"$Dir`""
$pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$HelperUser" -LogonType Interactive -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'EmilliPromptHelper' -Action $act -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName 'EmilliPromptHelper'
Ask @{ op = 'hello' } 90 | Out-Null
Ask @{ op = 'rec-cursor'; on = $false } 10 | Out-Null
Ask @{ op = 'lang'; lang = 'ko' } 10 | Out-Null
# The helper uses its own copy of the program (as a controller PC has), so it stays when the
# store PC's installed one is removed for case 2.
$HelperExe = "$Dir\bin\helper-rustdesk.exe"
Copy-Item -Force $Packer $HelperExe
icacls $HelperExe /grant "${HelperUser}:RX" /Q | Out-Null

Step 'Store PC: plain desktop, no icons, its windows minimized'
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Seconds 1
[SL]::PlainDesktop($Wall[0], $Wall[1], $Wall[2])
Note "desktop icon lists hidden: $([SL]::HideDesktopIcons())"
[SL]::Glide($s[2] - 12, 12, 300)
Console-Shot 'desktop'

# ---------------------------------------------------------------- case 1: installed, elevation prompt
Step 'Case 1: installed (store PC mode), an elevation prompt on the store PC'
try {
    Connect-Helper 'installed' $true $HelperExe
    Start-Sleep -Seconds 4
    Ask @{ op = 'keep' } 20 | Out-Null
    Helper-Shot 'installed-before'
    if (-not $UacOn) { throw 'UAC is off on this runner' }
    $up = Raise-Prompt 'installed'
    Result 'installed prompt raised' $up 'consent.exe (Windows asking for administrator permission) is running on the store PC'
    Start-Sleep -Seconds 3
    $ch = Ask @{ op = 'changed'; tol = 24 } 20
    Helper-Shot 'installed-prompt'
    $pm = if ($ch -match 'changed (\d+)/1000') { [int]$Matches[1] } else { 0 }
    $dlg = Ask @{ op = 'clusters'; kind = 'bright'; min = 60 } 20
    $hasDialog = [bool]($dlg -split ' / ' | Where-Object { $_ } | Where-Object { $v = $_ -split ','; ([int]$v[2] - [int]$v[0]) -ge 250 })
    Result 'installed prompt visible to the helper' ($up -and $pm -ge 300 -and $hasDialog) "the helper's picture changed in $pm/1000 of its pixels (the dimmed screen) and shows a light dialog: $hasDialog ($dlg)"
    $how = Click-Yes
    Note $how
    $mark = "$Dir\out\elevated-installed.txt"
    $ran = Wait-Until { (Test-Path $mark) -and (Select-String -Path $mark -Pattern 'High Mandatory Level' -Quiet) } 20 500
    Start-Sleep -Seconds 1
    Helper-Shot 'installed-after-click'
    Result 'installed click reaches the prompt' ($up -and [bool]$ran) "$how; the elevated command ran (its groups show High Mandatory Level): $([bool]$ran); consent.exe still running: $([bool](Get-Process -Name consent -ErrorAction SilentlyContinue))"
} catch { Note "case 1 failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; [void]$Summary.Add("CASE 1 FAILED: $($_.Exception.Message)") }
Close-Prompt
try { Ask @{ op = 'close-remote' } 30 | Out-Null } catch { }
Start-Sleep -Seconds 3

# ---------------------------------------------------------------- case 2: not installed
Step 'Case 2: the program only run (not installed), the same prompt'
try {
    Uninstall-All
    # What a person gets by double-clicking the downloaded program: the same file the Setup
    # carries, run by Clerk, an ordinary administrator whose programs have limited rights until
    # Windows asks (attempt 3 ran it as the runner's built-in Administrator, which is never
    # asked, and the store PC password from case 1 was still in that user's settings). Direct
    # access on for the loopback test, in Clerk's own settings file (as Settings > Security
    # writes it); the rest at the app's defaults (the store PC accepts with a click).
    $clerkSid = (Get-LocalUser -Name 'Clerk').SID.Value
    $clerkHome = (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $clerkSid }).LocalPath
    Note "Clerk's profile: $clerkHome"
    $ucfg = Join-Path $clerkHome 'AppData\Roaming\RustDesk\config'
    New-Item -ItemType Directory -Force -Path $ucfg | Out-Null
    $f2 = Join-Path $ucfg 'RustDesk2.toml'
    $t2 = if (Test-Path $f2) { [System.IO.File]::ReadAllText($f2) } else { '' }
    if ($t2 -notmatch '(?m)^\[options\]') { $t2 = $t2.TrimEnd() + "`n`n[options]`n" }
    $t2 = $t2 -replace "(?m)^direct-server\s*=.*\r?\n", ''
    $t2 = $t2 -replace "(?m)^\[options\]\s*$", "[options]`ndirect-server = 'Y'"
    [System.IO.File]::WriteAllText($f2, $t2, (New-Object System.Text.UTF8Encoding($false)))
    $portable = "$Dir\bin\Emilli-Remote-portable.exe"
    Copy-Item -Force $Packer $portable
    Start-Process -FilePath $portable -Credential $ClerkCred -LoadUserProfile -WorkingDirectory $Dir | Out-Null
    $listen = Wait-Until { Get-NetTCPConnection -LocalPort 21118 -State Listen -ErrorAction SilentlyContinue } 90 1000
    RustDesk-Processes | ForEach-Object { Note $_ }
    Note "not installed: service present $([bool](Get-Service -Name RustDesk -ErrorAction SilentlyContinue)); listening on 21118: $([bool]$listen)"
    if (-not $listen) { Console-Shot 'portable-not-listening'; throw 'the not-installed program does not listen on 21118' }
    Start-Sleep -Seconds 5
    Console-Shot 'portable-started'
    Connect-Helper 'portable' $false $HelperExe
    Start-Sleep -Seconds 5
    Console-Shot 'portable-connected'
    $cm = CM-Window
    Note "store PC connection window: $cm"
    Ask @{ op = 'keep' } 20 | Out-Null
    Helper-Shot 'portable-before'
    if (-not $UacOn) { throw 'UAC is off on this runner' }
    $up = Raise-Prompt 'portable'
    Result 'portable prompt raised' $up 'consent.exe is running on the store PC'
    Start-Sleep -Seconds 4
    $ch = Ask @{ op = 'changed'; tol = 24 } 20
    Helper-Shot 'portable-prompt'
    $pm = if ($ch -match 'changed (\d+)/1000') { [int]$Matches[1] } else { 0 }
    Result 'portable prompt visible to the helper' ($pm -ge 300) "the helper's picture changed in $pm/1000 of its pixels while the prompt is up (frozen picture: 0 to a few)"
    # No click is aimed here: the helper's picture does not show the prompt, and the app's own
    # message covers the middle of the session window.
    Start-Sleep -Seconds 4
    $mark = "$Dir\out\elevated-portable.txt"
    Result 'portable prompt answered from the helper side' ([bool](Test-Path $mark)) 'nothing on the helper side can reach it; the elevated command did not run unless someone at the store PC answers'
    Close-Prompt
    Start-Sleep -Seconds 3
    Helper-Shot 'portable-after-prompt'
    Console-Shot 'portable-connection-window'
    if ($cm) { try { Note "connection window picture: $([SL]::ShotWindow($cm.Hwnd, (Join-Path $Shots 'store-portable-cm-window.png')))" } catch { } }
} catch { Note "case 2 failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; [void]$Summary.Add("CASE 2 FAILED: $($_.Exception.Message)") }
Close-Prompt
try { Ask @{ op = 'close-remote' } 30 | Out-Null } catch { }
Start-Sleep -Seconds 2
Get-Process -Name rustdesk -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq [SL]::MySession() } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ---------------------------------------------------------------- case 3: installed, lock screen
Step 'Case 3: installed again, the lock screen'
try {
    Install-Store 'reinstalled'
    # The runner's user gets a password only the helper types (sign-in through the session),
    # and no Ctrl+Alt+Del is asked before it (the policy many store PCs have too).
    $winPw = 'Wq5' + (New-Secret 17)
    net user $env:USERNAME $winPw | Out-Null
    [System.IO.File]::WriteAllText("$Dir\secret\winpw.txt", $winPw)
    $winPw = $null
    Set-ItemProperty $pol -Name DisableCAD -Value 1 -Type DWord
    Connect-Helper 'lock' $true $HelperExe
    Start-Sleep -Seconds 4
    Ask @{ op = 'keep' } 20 | Out-Null
    Helper-Shot 'lock-before'
    Note "input desktop before: '$([Desk]::InputDesktop())'"
    rundll32.exe user32.dll,LockWorkStation
    $locked = Wait-Until { (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) -and ([Desk]::InputDesktop() -ne 'Default') } 20 500
    Note "LogonUI running: $([bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)); input desktop '$([Desk]::InputDesktop())'"
    Result 'lock screen shown on the store PC' ([bool]$locked) 'the console is locked (LogonUI, the input desktop is no longer Default)'
    Start-Sleep -Seconds 4
    $ch = Ask @{ op = 'changed'; tol = 24 } 20
    Helper-Shot 'lock-visible'
    $pm = if ($ch -match 'changed (\d+)/1000') { [int]$Matches[1] } else { 0 }
    Result 'lock screen visible to the helper' ([bool]$locked -and $pm -ge 300) "the helper's picture changed in $pm/1000 of its pixels"
    # Sign in through the session: a click lifts the lock curtain, then the password and Enter.
    $pic = Ask @{ op = 'picture' } 20
    if ($pic -match 'picture (-?\d+),(-?\d+) (\d+)x(\d+)') {
        $cx = [int]$Matches[1] + [int]([int]$Matches[3] / 2); $cy = [int]$Matches[2] + [int]([int]$Matches[4] / 2)
        Ask @{ op = 'click-xy'; x = $cx; y = $cy; ms = 400 } 20 | Out-Null
        Start-Sleep -Seconds 3
        Helper-Shot 'lock-password-field'
        Ask @{ op = 'type-file'; file = 'winpw.txt'; ms = 80; enter = $false } 30 | Out-Null
        Start-Sleep -Milliseconds 700
        Helper-Shot 'lock-password-typed'
        Ask @{ op = 'key'; vk = 13 } 20 | Out-Null
        Start-Sleep -Milliseconds 1500
        Helper-Shot 'lock-just-after-password'
    }
    $back = Wait-Until { [Desk]::InputDesktop() -eq 'Default' -and -not (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) } 25 500
    Start-Sleep -Seconds 3
    Helper-Shot 'lock-after-sign-in'
    Console-Shot 'after-sign-in'
    Result 'signed in through the session' ([bool]$back) "input desktop '$([Desk]::InputDesktop())'; LogonUI running: $([bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue))"
    # The session toolbar opened (its arrow at the top middle of the session window), for a
    # picture of the codec badge next to the Display menu (windows-153-ui 9d026df).
    $pic = Ask @{ op = 'picture' } 20
    if ($pic -match 'picture (-?\d+),(-?\d+) (\d+)x(\d+)') {
        $ax = [int]$Matches[1] + [int]([int]$Matches[3] / 2) + 19; $ay = [int]$Matches[2] + 8
        Ask @{ op = 'click-xy'; x = $ax; y = $ay; ms = 400 } 20 | Out-Null
        Start-Sleep -Milliseconds 1500
        Helper-Shot 'toolbar-codec-badge'
    }
} catch { Note "case 3 failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; [void]$Summary.Add("CASE 3 FAILED: $($_.Exception.Message)") }
try { Ask @{ op = 'close-remote' } 30 | Out-Null } catch { }

# ---------------------------------------------------------------- the end
Step 'Logs and clean-up'
foreach ($root in @('C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log', 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\log', "$env:APPDATA\RustDesk\log")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.log' | ForEach-Object {
        $hits = Select-String -Path $_.FullName -Pattern 'uac|UAC|desktop|Desktop|secure|elevat|portable|privilege' | Select-Object -Last 40
        foreach ($h in $hits) {
            $line = $h.Line -replace '[A-Za-z0-9+/]{40,}={0,2}', '(long value hidden)'
            if ($line.Length -gt 220) { $line = $line.Substring(0, 220) + ' ...' }
            Note "log $($_.Name): $line"
        }
    }
}
$Summary | Set-Content -Path (Join-Path $Out 'summary.txt') -Encoding ASCII
Get-Content (Join-Path $Out 'summary.txt') | ForEach-Object { Note $_ }
Copy-Item -Force "$Dir\out\*" $Debug -ErrorAction SilentlyContinue
try { Ask @{ op = 'quit' } 20 | Out-Null } catch { }
Remove-Item -Force -Recurse "$Dir\secret" -ErrorAction SilentlyContinue
cmdkey "/delete:TERMSRV/127.0.0.2" | Out-Null
Write-Host "RESULT prompt measurement finished: $($Summary.Count) lines in summary.txt"
exit 0
