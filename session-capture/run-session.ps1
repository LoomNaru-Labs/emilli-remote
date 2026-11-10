# Real screenshots of a connected Emilli Remote session, taken on a fresh GitHub
# "windows-latest" runner only. It installs software, adds a printer and a local user,
# switches on Remote Desktop and signs that user in, so never run it on a PC that matters.
#
#   powershell -File session-capture/run-session.ps1 -Set office -Setup <setup.exe> -Out <folder>
#
# One runner plays both PCs:
# - the store PC is the runner's own console session: Emilli Remote Setup installs there as a
#   store PC (silent, a random throwaway password), and the staged problem sits on its screen,
#   a print job stuck in the queue of a printer whose port goes nowhere;
# - the helper is a second Windows session on the same runner: a throwaway local user signed in
#   through a Remote Desktop loopback (127.0.0.2). helper-agent.ps1 runs there, opens the
#   installed app's connection to 127.0.0.1 (direct access, the store PC password) and moves
#   and clicks the real mouse over the session window.
# The two sessions have separate screens and mice, so the session window never shows itself.
# rd.emillis.net is blocked in the hosts file by the workflow; nothing reaches our server.
# Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [ValidateSet('office', 'store')] [string] $Set,
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Out,
    # The app's own language setting (Windows stays English); 'ko' adds -ko to every file name.
    [ValidateSet('en', 'ko')] [string] $Lang = 'en',
    [switch] $Record
)
$ErrorActionPreference = 'Stop'
$Tag = if ($Lang -eq 'ko') { '-ko' } else { '' }

# Sets lang in a RustDesk_local.toml (the app's own language option), keeping the rest.
function Set-AppLanguage([string] $File, [string] $Code) {
    New-Item -ItemType Directory -Force -Path (Split-Path $File) | Out-Null
    $text = if (Test-Path $File) { [System.IO.File]::ReadAllText($File) } else { '' }
    if ($text -match "(?m)^lang\s*=") { $text = $text -replace "(?m)^lang\s*=.*$", "lang = '$Code'" }
    elseif ($text -match "(?m)^\[options\]\s*$") { $text = $text -replace "(?m)^\[options\]\s*$", "[options]`nlang = '$Code'" }
    else { $text = $text.TrimEnd() + "`n`n[options]`nlang = '$Code'`n" }
    [System.IO.File]::WriteAllText($File, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$Dir = 'C:\sc'
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$HelperUser = 'Helper'
$Wall = @(38, 84, 124)
$Peer = '127.0.0.1'
$Fps = 20

$Props = @{
    office = @{
        Printer = 'Office Printer'; Port = 'OfficePrinterPort'; Root = 'C:\Office'
        Folders = @('Quotes', 'Invoices', 'Shared'); DocFolder = 'Quotes'; Doc = 'Quote_November.txt'
        Lines = @('Quote for November', '', 'Office chairs (4)          480.00', 'Desk lamps (6)             150.00',
                  'Delivery                    40.00', 'Total                      670.00', '', 'Valid until November 30')
    }
    store = @{
        Printer = 'Receipt Printer'; Port = 'ReceiptPrinterPort'; Root = 'C:\Store'
        Folders = @('Receipts', 'Menu', 'Reports'); DocFolder = 'Reports'; Doc = 'Daily_close.txt'
        Lines = @('Daily close', '', 'Card sales               1,284.50', 'Cash sales                 312.00',
                  'Refunds                    -18.00', 'Net total                1,578.50', '', 'Counted by the closing shift')
    }
}
$P = $Props[$Set]
$Shots = Join-Path $Dir 'out\shots'
$Debug = Join-Path $Out 'debug'

function Step([string] $m) { Write-Host ("STEP {0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Note([string] $m) { Write-Host "  $m" }

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

# Creates a registry key only when it is missing (New-Item -Force would empty an existing key).
function Ensure-Key([string] $Path) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Debug-Shot([string] $Name) {
    try { [SL]::ShotScreen((Join-Path $Debug "console-$Name.png")) | Out-Null } catch { Note "debug shot $Name failed: $($_.Exception.Message)" }
}

trap {
    Write-Host "FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Debug-Shot 'failure'
    Copy-Item -Force "$Shots\*.png" $Debug -ErrorAction SilentlyContinue
    Copy-Item -Force "$Dir\out\agent.log" $Debug -ErrorAction SilentlyContinue
    break
}

New-Item -ItemType Directory -Force -Path $Out, $Debug, $Dir, "$Dir\bin", "$Dir\cmd", "$Dir\done", "$Dir\tmp", "$Dir\out", $Shots, "$Dir\secret" | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'SessionLib.cs'), (Join-Path $PSScriptRoot 'helper-agent.ps1') "$Dir\bin"
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'SessionLib.cs')
Add-Type -AssemblyName System.Drawing, System.Security

$s = [SL]::Screen()
Note "console: session $([SL]::MySession()), user $env:USERNAME, screen $($s[2])x$($s[3]), $([Environment]::OSVersion.VersionString)"

# ---------------------------------------------------------------- helper commands
$script:Seq = 0
function Ask([hashtable] $C, [int] $Timeout = 60) {
    $script:Seq++
    $name = '{0:D3}-{1}.json' -f $script:Seq, $C.op
    $tmp = Join-Path $Dir "tmp\$name"
    ($C | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding ASCII
    Move-Item -Force $tmp (Join-Path $Dir "cmd\$name")
    $done = Join-Path $Dir "done\$name"
    $end = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $end) {
        if (Test-Path $done) {
            $a = Get-Content -Raw -Path $done | ConvertFrom-Json
            Note "helper $($C.op): $($a.result)"
            if (-not $a.ok) { throw "helper $($C.op) failed: $($a.result)" }
            return $a.result
        }
        Start-Sleep -Milliseconds 90
    }
    throw "the helper did not answer $name within $Timeout s"
}

# A move at a human pace to a point of the store PC's screen, through the session.
function Helper-Point([int] $X, [int] $Y, [int] $Ms = 900) {
    Ask @{ op = 'move'; rx = $X; ry = $Y; ms = $Ms } 30 | Out-Null
}
function Helper-Click([switch] $Right) {
    Ask @{ op = 'click'; right = [bool]$Right; pause = 300 } 10 | Out-Null
}
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# ---------------------------------------------------------------- 1. Emilli Remote as a store PC
Step 'Install Emilli Remote Setup as a store PC (silent, throwaway password)'
$pwFile = Join-Path $Dir 'secret\pw.txt'
[System.IO.File]::WriteAllText($pwFile, (New-Secret 20))
$setupLog = Join-Path $Debug 'setup.log'
$proc = Start-Process -FilePath $Setup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MODE=store', "/PWFILE=$pwFile", "/LOG=$setupLog")
if (-not $proc.WaitForExit(600000)) { throw 'Setup did not finish in 10 minutes' }
Note "Setup exit code $($proc.ExitCode)"
if (Test-Path $setupLog) { Select-String -Path $setupLog -SimpleMatch 'Emilli:' | ForEach-Object { Note $_.Line.Trim() } }
if ($proc.ExitCode -ne 0) { throw 'Setup failed' }

Step 'Direct access on (port 21118) and one Windows session served (no session picker)'
cmd /c "`"$Exe`" --option direct-server Y > `"$Dir\tmp\opt-set.txt`" 2>&1"
reg add 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk' /f /v share_rdp /t REG_SZ /d false | Out-Null
$listen = Wait-Until { Get-NetTCPConnection -LocalPort 21118 -State Listen -ErrorAction SilentlyContinue } 60
cmd /c "`"$Exe`" --option direct-server > `"$Dir\tmp\opt-get.txt`" 2>&1"
Note "direct-server option now '$((Get-Content -Raw "$Dir\tmp\opt-get.txt" -ErrorAction SilentlyContinue).Trim())'; listening on 21118: $([bool]$listen)"
if (-not $listen) { throw 'RustDesk does not listen on 21118' }

# ---------------------------------------------------------------- 2. the helper's Windows session
Step 'Throwaway local user, Remote Desktop on, loopback sign-in'
$helperPw = 'Hx7' + (New-Secret 21)
New-LocalUser -Name $HelperUser -Password (ConvertTo-SecureString $helperPw -AsPlainText -Force) -PasswordNeverExpires -AccountNeverExpires -Description 'Throwaway user for the session screenshots' | Out-Null
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $HelperUser
icacls $Dir /grant "${HelperUser}:(OI)(CI)M" /T /Q | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Start-Service TermService -ErrorAction SilentlyContinue
Ensure-Key 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord
Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
# Saved credentials may be used for this loopback connection (local account, NTLM only).
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
    foreach ($line in (cmd /c "qwinsta 2>nul")) {
        if ($line -match "\s$HelperUser\s+(\d+)\s+Active") { return [int]$Matches[1] }
    }
    return $null
}

function Watch-Rdp([int] $Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    $n = 0
    while ((Get-Date) -lt $end) {
        $sid = Helper-SessionId
        if ($sid -and (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid })) { return $sid }
        foreach ($w in [SL]::Windows()) {
            if ($w.Proc -eq 'mstsc' -and $w.Cls -eq '#32770') {
                Note "Remote Desktop dialog: '$($w.Title)' $([SL]::ChildTexts($w.Hwnd))"
                foreach ($b in @('Connect', 'Yes')) { if ([SL]::ClickButton($w.Hwnd, $b) -gt 0) { Note "  clicked $b" } }
            }
        }
        $n++
        if ($n % 15 -eq 0) { Debug-Shot "rdp-wait-$n" }
        Start-Sleep -Seconds 1
    }
    return $null
}

$mstsc = Start-Process -FilePath mstsc.exe -ArgumentList @('/v:127.0.0.2', '/w:2560', '/h:1440') -PassThru
$sid = Watch-Rdp 120
if (-not $sid) {
    Note 'no session with saved credentials; second way: Network Level Authentication off and the password in the connection file'
    Debug-Shot 'rdp-first-way-failed'
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
if (-not $sid) { Debug-Shot 'rdp-failed'; qwinsta; throw 'the helper session did not start' }
Note "helper session $sid is signed in"
cmd /c "qwinsta 2>nul" | ForEach-Object { Note $_ }
Start-Sleep -Seconds 8
foreach ($w in [SL]::Windows()) {
    if ($w.Proc -eq 'mstsc' -and $w.Cls -eq 'TscShellContainerClass') {
        [SL]::Place($w.Hwnd, -3200, 60, 1400, 900)
        [SL]::HideFromTaskbar($w.Hwnd)
        Note "Remote Desktop client window moved off the store PC's screen: $([SL]::Info($w.Hwnd))"
    }
}

Step 'Start the helper agent in the helper session'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bin\helper-agent.ps1`" -Dir `"$Dir`""
$pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$HelperUser" -LogonType Interactive -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'EmilliSessionHelper' -Action $act -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName 'EmilliSessionHelper'
Ask @{ op = 'hello' } 90 | Out-Null

# ---------------------------------------------------------------- 3. the staged problem on the store PC
Step "Stage the problem on the store PC ($Set set)"
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value ''
Set-ItemProperty 'HKCU:\Control Panel\Colors' -Name Background -Value ($Wall -join ' ')
[SL]::PlainDesktop($Wall[0], $Wall[1], $Wall[2])
Note "desktop icons hidden: $([SL]::HideDesktopIcons())"
Ensure-Key 'HKCU:\Software\Microsoft\Notepad'
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name iPointSize -Value 160 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name lfFaceName -Value 'Consolas'
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name StatusBar -Value 0 -Type DWord

foreach ($f in $P.Folders) { New-Item -ItemType Directory -Force -Path (Join-Path $P.Root $f) | Out-Null }
$docPath = Join-Path (Join-Path $P.Root $P.DocFolder) $P.Doc
[System.IO.File]::WriteAllText($docPath, (($P.Lines -join "`r`n") + "`r`n"))

Set-Service -Name Spooler -StartupType Automatic
Start-Service -Name Spooler
$driver = $null
foreach ($d in @('Generic / Text Only', 'Microsoft Software Printer Driver', 'Microsoft Print To PDF', 'Microsoft XPS Document Writer v4', 'Microsoft PS Class Driver')) {
    try {
        if (-not (Get-PrinterDriver -Name $d -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $d }
        $driver = $d; break
    } catch { Note "driver '$d' not available: $($_.Exception.Message)" }
}
if (-not $driver) { throw 'no printer driver' }
# A port that goes nowhere: nothing listens on 127.0.0.1:9, so every attempt fails at once.
Add-PrinterPort -Name $P.Port -PrinterHostAddress '127.0.0.1' -PortNumber 9
Add-Printer -Name $P.Printer -DriverName $driver -PortName $P.Port
Note "printer '$($P.Printer)' on port $($P.Port), driver '$driver'"

$pd = New-Object System.Drawing.Printing.PrintDocument
$pd.PrinterSettings.PrinterName = $P.Printer
$pd.DocumentName = $P.Doc
$pd.PrintController = New-Object System.Drawing.Printing.StandardPrintController
$font = New-Object System.Drawing.Font('Consolas', 11)
$lines = $P.Lines
$pd.add_PrintPage({
    param($sender, $e)
    $y = 100
    foreach ($l in $lines) { $e.Graphics.DrawString($l, $font, [System.Drawing.Brushes]::Black, 100, $y); $y += 24 }
    $e.HasMorePages = $false
})
$pd.Print()
$job = Wait-Until { Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue } 30
Start-Sleep -Seconds 12
$job = Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue
if (-not $job) { throw 'the print job did not stay in the queue' }
Note "queue: $(@($job).Count) job(s); '$($job[0].DocumentName)' status '$($job[0].JobStatus)'"

# A runner leftover: Windows' Performance Options window with its paging file notice.
Get-Process -Name SystemPropertiesPerformance -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath notepad.exe -ArgumentList "`"$docPath`""
Start-Process -FilePath explorer.exe -ArgumentList "`"$($P.Root)`""
Start-Process -FilePath rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /o /n `"$($P.Printer)`""
$leaf = Split-Path $P.Root -Leaf
$found = Wait-Until {
    $ws = [SL]::Windows()
    $n = $ws | Where-Object { $_.Proc -eq 'notepad' } | Select-Object -First 1
    $e = $ws | Where-Object { $_.Cls -eq 'CabinetWClass' -and $_.Title -like "*$leaf*" } | Select-Object -First 1
    $q = $ws | Where-Object { $_.Title -like "$($P.Printer)*" -and $_.Proc -eq 'rundll32' } | Select-Object -First 1
    if ($n -and $e -and $q) { return @($n, $e, $q) }
} 60
if (-not $found) { [SL]::Windows() | ForEach-Object { Note "$_" }; throw 'the staged windows did not open' }
$Notepad, $Explorer, $Queue = $found
Start-Sleep -Seconds 2
[SL]::Place($Explorer.Hwnd, 70, 640, 860, 360)
[SL]::Place($Notepad.Hwnd, 70, 90, 860, 520)
[SL]::Place($Queue.Hwnd, 980, 90, 880, 400)
# The runner's own console windows: out of sight and off the taskbar.
foreach ($w in [SL]::Windows()) {
    if ($w.Cls -in @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS') -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        [SL]::Show($w.Hwnd, 6); [SL]::HideFromTaskbar($w.Hwnd); Note "runner window hidden: $w"
    }
}
[SL]::Front($Notepad.Hwnd); Start-Sleep -Milliseconds 400
[SL]::Front($Queue.Hwnd); Start-Sleep -Seconds 2
Debug-Shot 'staged'
[SL]::Windows() | ForEach-Object { Note "console window: $_" }

if ($Lang -ne 'en') {
    Step "The app's own language set to '$Lang' on both PCs (Windows stays English)"
    Set-AppLanguage (Join-Path $env:APPDATA 'RustDesk\config\RustDesk_local.toml') $Lang
    Ask @{ op = 'lang'; lang = $Lang } 20 | Out-Null
}

# ---------------------------------------------------------------- 4. the connection
Step 'The helper connects to the store PC (127.0.0.1, direct access, store PC password)'
Ask @{ op = 'connect'; exe = $Exe; peer = $Peer; seconds = 45 } 120 | Out-Null
$cm = Wait-Until { Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' } } 40
Note "connection manager on the store PC: $([bool]$cm)"
Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | ForEach-Object {
    $args0 = ($_.CommandLine -replace '--password\s+\S+', '--password (hidden)')
    Note "rustdesk.exe pid $($_.ProcessId) session $($_.SessionId): $args0"
}
Start-Sleep -Seconds 3
Ask @{ op = 'tidy' } 20 | Out-Null
# The session view fits the remote screen to the window, so a window whose picture area is
# exactly 1920 pixels wide (visible frame 1920; 7 invisible border pixels on each side) shows
# the store PC's 1920x1080 screen at 1:1.
# Below the 30-pixel tab bar the picture area is centred; 4 spare pixels keep the fit at 1:1.
# Two pixels wider first, which shows the picture's last column too if the window keeps 1:1;
# otherwise back to the width that is known to keep 1:1.
foreach ($extra in @(16, 14)) {
    Ask @{ op = 'place'; x = 300; y = 60; w = ($s[2] + $extra); h = ($s[3] + 41) } 20 | Out-Null
    Start-Sleep -Seconds 2
    $loc = Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 30
    $m = [regex]::Match($loc, 'wallpaper box (\d+),(\d+) to (\d+),(\d+)')
    $bw = if ($m.Success) { [int]$m.Groups[3].Value - [int]$m.Groups[1].Value + 1 } else { 0 }
    Note "window width +${extra}: picture $bw pixels wide"
    if ($bw -eq $s[2]) { break }
}
Ask @{ op = 'screen'; dir = $Shots; name = 'debug-helper-after-place' } 20 | Out-Null
Copy-Item -Force "$Shots\debug-helper-after-place.png" $Debug -ErrorAction SilentlyContinue

# Calibration through the session itself: the helper's pointer goes to two points of the
# picture and the store PC reports where its own pointer landed. This also shows in the log
# that the helper's mouse moves the store PC's pointer.
Step 'Calibrate the picture with real pointer moves through the session'
$obs = @()
foreach ($pt in @(@(420, 300), @(1560, 860), @(960, 540))) {
    $res = Ask @{ op = 'move'; rx = $pt[0]; ry = $pt[1]; ms = 500 } 30
    Start-Sleep -Milliseconds 900
    $c = [SL]::Cursor()
    $m = [regex]::Match($res, 'helper screen (-?\d+),(-?\d+)')
    $obs += , @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, $c[0], $c[1])
    Note "helper pointer at $($m.Groups[1].Value),$($m.Groups[2].Value) -> store PC pointer at $($c[0]),$($c[1])"
}
$dx = $obs[1][2] - $obs[0][2]; $dy = $obs[1][3] - $obs[0][3]
if ([Math]::Abs($dx) -lt 100 -or [Math]::Abs($dy) -lt 100) { throw "the store PC pointer did not follow the helper's mouse ($dx, $dy)" }
$sx = ($obs[1][0] - $obs[0][0]) / [double]$dx
$sy = ($obs[1][1] - $obs[0][1]) / [double]$dy
$left = $obs[0][0] - $obs[0][2] * $sx
$top = $obs[0][1] - $obs[0][3] * $sy
Note ("measured: picture at {0:N1},{1:N1}, scale {2:N4} across, {3:N4} down" -f $left, $top, $sx, $sy)
Ask @{ op = 'calib'; left = $left; top = $top; scale = $sx } 20 | Out-Null
Helper-Point 960 540 400
Start-Sleep -Milliseconds 900
$c = [SL]::Cursor()
Note "check: asked 960,540 -> store PC pointer at $($c[0]),$($c[1])"

# ---------------------------------------------------------------- 5. pictures and the fix
$base = "session-$Set"
# The runner's own Windows notices (such as the temporary paging file message) are closed;
# they are not part of the staged scene.
Get-Process -Name SystemPropertiesPerformance -ErrorAction SilentlyContinue | ForEach-Object { Note "runner leftover closed: $($_.ProcessName)"; $_ | Stop-Process -Force }
foreach ($w in [SL]::Windows()) {
    if ($w.Cls -eq '#32770' -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        $texts = [SL]::ChildTexts($w.Hwnd)
        Note "dialog on the store PC: $w $texts"
        if ($texts -match 'paging file') { Note "  closed: $([SL]::ClickButton($w.Hwnd, 'OK'))" }
    }
}
foreach ($w in [SL]::Windows()) {
    if ($w.Proc -like 'rustdesk*' -and $w.Width -gt 50) { Note "Emilli Remote window on the store PC: $w" }
}
[SL]::Front($Queue.Hwnd)
Start-Sleep -Seconds 2
Helper-Point 1500 760 700
Start-Sleep -Seconds 2
Ask @{ op = 'shot'; dir = $Shots; name = "$base-01-controller-problem$Tag"; screen = $true } 30 | Out-Null
Note "controlled screen: $([SL]::ShotScreen((Join-Path $Shots "$base-03-controlled-screen$Tag.png")))"
Note "queue before the fix: $(@(Get-PrintJob -PrinterName $P.Printer).Count) job(s), status '$((Get-PrintJob -PrinterName $P.Printer)[0].JobStatus)'"

Step 'The helper cancels the stuck job through the session (real mouse input)'
$recHelper = Join-Path $Shots "rec-$base-controller"
$recStore = Join-Path $Shots "rec-$base-controlled"
if ($Record) {
    [SL]::RecordStart(0, 0, $s[2], $s[3], $Fps, $recStore)
    Ask @{ op = 'rec-start'; dir = $recHelper; fps = $Fps } 20 | Out-Null
    Start-Sleep -Milliseconds 600
}
$markA = Now-Ms
# The job row: the first row of the queue's list, just under its column headers.
$lv = [SL]::ChildRect($Queue.Hwnd, 'SysListView32')
$hd = [SL]::ChildRect($Queue.Hwnd, 'SysHeader32')
if (-not $lv -or -not $hd) { throw "the queue's list was not found: $([SL]::ChildTexts($Queue.Hwnd))" }
Note "queue list at $($lv -join ','), column headers at $($hd -join ',')"
Helper-Point ($lv[0] + 90) ($hd[3] + 11) 1100
Helper-Click -Right
$menuTexts = ''
$mi = Wait-Until { [SL]::MenuItemRect('Cancel', [ref]$menuTexts) } 8 250
Note "menu on the store PC: $menuTexts"
if (-not $mi) { Debug-Shot 'menu-missing'; throw 'the job menu did not open on the store PC' }
Helper-Point ($mi[0] + 30) ([int](($mi[1] + $mi[3]) / 2)) 600
Helper-Click
$dlgText = ''
$yes = Wait-Until { [SL]::DialogButtonRect('Yes', [ref]$dlgText) } 8 250
Note "dialog on the store PC: $dlgText"
if (-not $yes) { Debug-Shot 'confirm-missing'; throw 'the confirmation did not appear on the store PC' }
Helper-Point ([int](($yes[0] + $yes[2]) / 2)) ([int](($yes[1] + $yes[3]) / 2)) 700
Helper-Click
# The helper goes back to the document while Windows clears the queue (a job that is printing
# takes a few seconds to delete).
$nr = [SL]::Info($Notepad.Hwnd)
Helper-Point ($nr.Left + 420) ($nr.Top + 300) 900
Helper-Click
$empty = Wait-Until { -not (Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue) } 40 400
Note "queue after the fix: $(@(Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue).Count) job(s)"
if (-not $empty) { throw 'the job did not go away' }
Start-Sleep -Milliseconds 1000
$markB = Now-Ms
Ask @{ op = 'shot'; dir = $Shots; name = "$base-02-controller-fixed$Tag"; screen = $true } 30 | Out-Null
Note "controlled screen after the fix: $([SL]::ShotScreen((Join-Path $Shots "$base-03-controlled-screen-fixed$Tag.png")))"
Note "fix from the first move to the fixed state: $($markB - $markA) ms"
if ($Record) {
    Start-Sleep -Milliseconds 600
    Ask @{ op = 'rec-stop' } 120 | Out-Null
    Note "store PC recording: $([SL]::RecordStop())"
}

# Extra: the store PC's connection panel opened from its taskbar button, as staff would see it.
Step 'Extra: the connection panel on the store PC, opened from its taskbar button'
$cmWin = $null
if ($cm) {
    $cmPid = [uint32](@($cm)[0].ProcessId)
    $cmWin = [SL]::Windows() | Where-Object { $_.Pid -eq $cmPid -and $_.Width -gt 50 } | Select-Object -First 1
}
if ($cmWin) {
    Note "panel before: $cmWin"
    [SL]::Show($cmWin.Hwnd, 9); [SL]::Front($cmWin.Hwnd)
    Start-Sleep -Seconds 2
    Note "panel after: $([SL]::Info($cmWin.Hwnd))"
    Note "controlled screen with the panel: $([SL]::ShotScreen((Join-Path $Shots "$base-06-controlled-screen-panel$Tag.png")))"
    Start-Sleep -Milliseconds 800
    Ask @{ op = 'shot'; dir = $Shots; name = "$base-06-controller-panel$Tag" } 30 | Out-Null
} else { Note 'no connection panel window found on the store PC' }

if ($Record) {
Step 'Lossless videos of the recordings (FFV1)'
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) {
    choco install ffmpeg -y --no-progress --limit-output | Out-Null
    $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    if (-not $ff -and (Test-Path 'C:\ProgramData\chocolatey\bin\ffmpeg.exe')) { $ff = 'C:\ProgramData\chocolatey\bin\ffmpeg.exe' }
}
foreach ($rec in @(@($recHelper, "$base-05-fix-controller"), @($recStore, "$base-05-fix-controlled"))) {
    $times = @(Import-Csv (Join-Path $rec[0] 'frames.csv'))
    $n = $times.Count
    $span = if ($n -gt 1) { [int]$times[$n - 1].ms - [int]$times[0].ms } else { 0 }
    Note "$($rec[1]): $n frames over $span ms ($([Math]::Round(($n - 1) * 1000.0 / [Math]::Max(1, $span), 1)) fps measured)"
    # Cut to the fix: half a second before the first move until half a second after the
    # fixed state (wall-clock marks mapped onto this recording's own frame times).
    $start = [int64](Get-Content (Join-Path $rec[0] 'start.txt'))
    $cutFrom = $markA - $start - 500; $cutTo = $markB - $start + 500
    $sel = @($times | Where-Object { [int64]$_.ms -ge $cutFrom -and [int64]$_.ms -le $cutTo })
    if ($sel.Count -lt 2) { $sel = $times }
    $first = [int]$sel[0].frame; $count = $sel.Count; $last = $first + $count - 1
    Note "$($rec[1]): kept frames $first to $last ($count frames over $([int64]$sel[$count - 1].ms - [int64]$sel[0].ms) ms)"
    if ($ff) {
        # Each frame keeps its real capture time (concat list with durations), written out at a
        # constant $Fps fps, so the video plays at real speed even when a grab came late.
        $list = @('ffconcat version 1.0')
        for ($i = 0; $i -lt $sel.Count; $i++) {
            $dur = if ($i + 1 -lt $sel.Count) { ([int64]$sel[$i + 1].ms - [int64]$sel[$i].ms) / 1000.0 } else { 1.0 / $Fps }
            $list += ("file 'frame-{0:D5}.png'" -f [int]$sel[$i].frame)
            $list += ('duration {0}' -f $dur.ToString([Globalization.CultureInfo]::InvariantCulture))
        }
        $list += ("file 'frame-{0:D5}.png'" -f [int]$sel[$sel.Count - 1].frame)
        $listPath = Join-Path $rec[0] 'list.ffconcat'
        Set-Content -Path $listPath -Value $list -Encoding ASCII
        $mkv = Join-Path $Shots "$($rec[1]).mkv"
        cmd /c "`"$ff`" -hide_banner -loglevel error -y -f concat -safe 0 -i `"$listPath`" -fps_mode cfr -r $Fps -c:v ffv1 -level 3 -pix_fmt bgr0 `"$mkv`" 2>&1" | ForEach-Object { Note "ffmpeg: $_" }
        if (Test-Path $mkv) { Note "video $($rec[1]).mkv $((Get-Item $mkv).Length) bytes, real time $(([int64]$sel[$sel.Count - 1].ms - [int64]$sel[0].ms + 50) / 1000.0) s" }
    }
    # Sample frames for checking the video by eye (debug folder only).
    foreach ($k in @($first, [int](($first + $last) / 2), $last)) {
        Copy-Item -Force (Join-Path $rec[0] ('frame-{0:D5}.png' -f $k)) (Join-Path $Debug ('{0}-frame-{1:D5}.png' -f $rec[1], $k)) -ErrorAction SilentlyContinue
    }
    $sel | Export-Csv -NoTypeInformation -Path (Join-Path $Shots "$($rec[1])-frames.csv")
}
}

# ---------------------------------------------------------------- 6. evidence and clean-up
Step 'Session evidence from the logs (short lines)'
$pattern = 'direct access|Connection opened|onnection closed|Logged|[Ll]ogin|authoriz|handle_peer_info|peer info'
$roots = @("$SvcRoot\log", 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\log',
           "$env:APPDATA\RustDesk\log", "C:\Users\$HelperUser\AppData\Roaming\RustDesk\log")
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.log' | ForEach-Object {
        Note "log file $($_.FullName) ($($_.Length) bytes)"
        $hits = Select-String -Path $_.FullName -Pattern $pattern | Where-Object { $_.Line -notmatch 'ipc connection closed' } | Select-Object -First 12
        foreach ($h in $hits) {
            $line = $h.Line -replace '[A-Za-z0-9+/]{40,}={0,2}', '(long value hidden)'
            if ($line.Length -gt 240) { $line = $line.Substring(0, 240) + ' ...' }
            Note "  $line"
        }
    }
}
Get-Content -Path "$Dir\out\agent.log" -ErrorAction SilentlyContinue | ForEach-Object { Note "agent: $_" }

Ask @{ op = 'quit' } 20 | Out-Null
Copy-Item -Force "$Shots\*.png", "$Shots\*.mkv", "$Shots\*.csv" $Out -ErrorAction SilentlyContinue
Copy-Item -Force "$Dir\out\agent.log" $Debug -ErrorAction SilentlyContinue
Remove-Item -Force -Recurse "$Dir\secret" -ErrorAction SilentlyContinue
cmdkey "/delete:TERMSRV/127.0.0.2" | Out-Null
cmd /c "logoff $sid 2>nul"
Start-Sleep -Seconds 5
Remove-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue
Note "throwaway user removed: $(-not (Get-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue))"
Get-ChildItem $Out -Filter '*.png' | ForEach-Object { Note "saved $($_.Name) ($($_.Length) bytes)" }
Write-Host "RESULT session pictures for the $Set set saved"
