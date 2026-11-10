# The connected-session take for the Emilli Remote manual and ads (brief REMOTE-SESSION-CAPTURE,
# addendum 1), on a fresh GitHub "windows-latest" runner only. It installs software, adds printers
# and a local user, switches on Remote Desktop and signs that user in, so never run it on a PC
# that matters.
#
#   powershell -File session-capture/run-take.ps1 -Set office -Setup <setup.exe> -Out <folder>
#
# One runner plays both PCs (see run-session.ps1 for the set-up): the console session is the
# store PC with the problem on screen (a document stuck on an old printer whose port goes
# nowhere), a second Windows session is the helper. The take, recorded on both screens: the
# helper's app main window, the address typed, Connect clicked, the password typed, the store
# PC's desktop in the session window, then with the real mouse through the session: the stuck
# job cancelled, the document printed again on the printer that works. Stills come from the
# recorded frames; the error screen is taken before the session, the good ending after it.
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

# The printer that works: a raw port to the stand-in printer (printer-sink.ps1) on 127.0.0.1:9100.
Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'printer-sink.ps1'))
$sinkUp = Wait-Until { Get-NetTCPConnection -LocalPort 9100 -State Listen -ErrorAction SilentlyContinue } 20
Note "stand-in printer listening on 9100: $([bool]$sinkUp)"
Add-PrinterPort -Name $P.Port -PrinterHostAddress '127.0.0.1' -PortNumber 9100
Add-Printer -Name $P.Printer -DriverName $driver -PortName $P.Port
Set-Printer -Name $P.Printer -KeepPrintedJobs $true

# The old printer, still the default, so the document went there: its port points at an address
# where nothing answers, so Windows retries and after about 20 s reports the job as an error
# (probe run 42792253200: 'Error, Printing' on the job, 'Error' on the printer).
$Old = "Old $($P.Printer)"
$oldPort = "Old$($P.Port)"
Add-PrinterPort -Name $oldPort -PrinterHostAddress '127.0.0.1' -PortNumber 9
Add-Printer -Name $Old -DriverName $driver -PortName $oldPort
Get-CimInstance Win32_Printer -Filter "Name='$Old'" | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null
Note "printers: '$($P.Printer)' on $($P.Port) (stand-in printer), '$Old' on $oldPort (default), driver '$driver'"

function Print-Doc([string] $Printer) {
    $pd = New-Object System.Drawing.Printing.PrintDocument
    $pd.PrinterSettings.PrinterName = $Printer
    $pd.DocumentName = $P.Doc
    $pd.PrintController = New-Object System.Drawing.Printing.StandardPrintController
    $script:PrintFont = New-Object System.Drawing.Font('Consolas', 11)
    $pd.add_PrintPage({
        param($sender, $ev)
        $y = 100
        foreach ($l in $P.Lines) { $ev.Graphics.DrawString($l, $script:PrintFont, [System.Drawing.Brushes]::Black, 100, $y); $y += 24 }
        $ev.HasMorePages = $false
    })
    $pd.Print()
}
Print-Doc $Old
$errJob = Wait-Until { $j = Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue; if ($j -and ("$($j[0].JobStatus)" -match 'Error')) { $j } } 90 2000
if (-not $errJob) {
    # Not seen in the probe; the job is then paused instead, which the brief also allows.
    $j = Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue
    if ($j) { Suspend-PrintJob -PrinterName $Old -ID $j[0].Id; Start-Sleep -Seconds 2 }
}
$j = Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue
if (-not $j) { throw 'no stuck job on the old printer' }
$StuckStatus = "$($j[0].JobStatus)"
Note "stuck job on '$Old': '$($j[0].DocumentName)' status '$StuckStatus'"

Get-Process -Name SystemPropertiesPerformance -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath notepad.exe -ArgumentList "`"$docPath`""
Start-Process -FilePath explorer.exe -ArgumentList "`"$($P.Root)`""
Start-Process -FilePath rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /o /n `"$Old`""
Start-Process -FilePath rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /o /n `"$($P.Printer)`""
$leaf = Split-Path $P.Root -Leaf
$found = Wait-Until {
    $ws = [SL]::Windows()
    $wn = $ws | Where-Object { $_.Proc -eq 'notepad' } | Select-Object -First 1
    $we = $ws | Where-Object { $_.Cls -eq 'CabinetWClass' -and $_.Title -like "*$leaf*" } | Select-Object -First 1
    $wo = $ws | Where-Object { $_.Proc -eq 'rundll32' -and $_.Title -like "$Old*" } | Select-Object -First 1
    $wg = $ws | Where-Object { $_.Proc -eq 'rundll32' -and $_.Title -like "$($P.Printer)*" } | Select-Object -First 1
    if ($wn -and $we -and $wo -and $wg) { return @($wn, $we, $wo, $wg) }
} 60
if (-not $found) { [SL]::Windows() | ForEach-Object { Note "$_" }; throw 'the staged windows did not open' }
$Notepad, $Explorer, $OldQueue, $Queue = $found
Start-Sleep -Seconds 2
[SL]::Place($Explorer.Hwnd, 40, 610, 760, 390)
[SL]::Place($Notepad.Hwnd, 40, 60, 760, 520)
[SL]::Place($Queue.Hwnd, 1000, 700, 900, 320)
# The old printer's queue in front of the document, over a third of the screen, its Status column
# wide enough for Windows' whole 'Error - Printing'.
[SL]::Place($OldQueue.Hwnd, 560, 90, 1300, 560)
$oqList = [SL]::ChildHandle($OldQueue.Hwnd, 'SysListView32')
if ($oqList -ne [IntPtr]::Zero) { [SL]::SetColumnWidth($oqList, 0, 260); [SL]::SetColumnWidth($oqList, 1, 230) }
foreach ($w in [SL]::Windows()) {
    if ($w.Cls -in @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS') -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        [SL]::Show($w.Hwnd, 6); [SL]::HideFromTaskbar($w.Hwnd); Note "runner window hidden: $w"
    }
}
foreach ($w in [SL]::Windows()) {
    if ($w.Cls -eq '#32770' -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        $texts = [SL]::ChildTexts($w.Hwnd)
        Note "dialog on the store PC: $w $texts"
        if ($texts -match 'paging file') { Note "  closed: $([SL]::ClickButton($w.Hwnd, 'OK'))" }
    }
}
[SL]::Front($Explorer.Hwnd); Start-Sleep -Milliseconds 300
[SL]::Front($Notepad.Hwnd); Start-Sleep -Milliseconds 300
[SL]::Front($Queue.Hwnd); Start-Sleep -Milliseconds 300
[SL]::Front($OldQueue.Hwnd); Start-Sleep -Seconds 2
$base = "session-$Set"
$oq = [SL]::Info($OldQueue.Hwnd)
Note "A. error screen: $([SL]::ShotScreen((Join-Path $Shots "$base-00-error-screen$Tag.png"))); old queue window $($oq.Width)x$($oq.Height) = $([int](100.0 * $oq.Width * $oq.Height / ($s[2] * $s[3])))% of the screen"
[SL]::Windows() | ForEach-Object { Note "console window: $_" }

if ($Lang -ne 'en') {
    Step "The app's own language set to '$Lang' on both PCs (Windows stays English)"
    Set-AppLanguage (Join-Path $env:APPDATA 'RustDesk\config\RustDesk_local.toml') $Lang
    Ask @{ op = 'lang'; lang = $Lang } 20 | Out-Null
}

# ---------------------------------------------------------------- 4. the helper's side before the take
# The session window's visible frame for a 1:1 picture (window outer size: screen + 14 by + 41).
$Region = @(307, 60, $s[2], ($s[3] + 34))
Step 'Warm-up: one session window to an address that answers nothing (192.0.2.10), parked where the recording looks, then closed'
Ask @{ op = 'hide-icons' } 20 | Out-Null
Ask @{ op = 'warm'; exe = $Exe; peer = '192.0.2.10'; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 90 | Out-Null
Step 'The helper opens the app (main window, idle)'
Ask @{ op = 'open-main'; exe = $Exe; x = $Region[0]; y = $Region[1]; w = $Region[2]; h = $Region[3] } 60 | Out-Null
Ask @{ op = 'find-connect' } 20 | Out-Null
Ask @{ op = 'screen'; dir = $Shots; name = 'debug-helper-main' } 20 | Out-Null
Copy-Item -Force "$Shots\debug-helper-main.png" $Debug -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 5. the take
Step 'The take: Connect from the main window, then the fix through the session (both screens recorded)'
$recHelper = Join-Path $Shots "rec-$base-controller"
$recStore = Join-Path $Shots "rec-$base-controlled"
$Marks = New-Object System.Collections.ArrayList
function Mark([string] $Label) { [void]$Marks.Add(@((Now-Ms), $Label)); Note "mark: $Label" }
[SL]::RecordStart(0, 0, $s[2], $s[3], $Fps, $recStore)
Ask @{ op = 'rec-start'; dir = $recHelper; fps = $Fps; x = $Region[0]; y = $Region[1]; w = $Region[2]; h = $Region[3] } 20 | Out-Null
Start-Sleep -Milliseconds 1500
Mark 'the helper main window, idle'
Ask @{ op = 'click-at'; what = 'field'; ms = 700 } 20 | Out-Null
Mark 'address field clicked'
Ask @{ op = 'type'; text = $Peer; ms = 90 } 20 | Out-Null
Mark "address typed ($Peer)"
Ask @{ op = 'click-at'; what = 'connect'; ms = 600 } 20 | Out-Null
Mark 'Connect clicked'
Ask @{ op = 'wait-remote'; peer = $Peer; seconds = 20 } 30 | Out-Null
Mark 'session window open (password prompt)'
Ask @{ op = 'park'; vx = $Region[0]; vy = $Region[1]; vw = $Region[2]; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 10 | Out-Null
Start-Sleep -Milliseconds 900
if (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' }) { throw 'the store PC accepted the helper before any password was given' }
Ask @{ op = 'type-secret'; ms = 70 } 20 | Out-Null
Mark 'password given'
$cm = Wait-Until { Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' } } 20 300
if (-not $cm) { throw 'the store PC did not accept the password' }
Mark 'connected (the store PC accepted the password)'
$loc = ''
for ($i = 0; $i -lt 20; $i++) {
    $loc = Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 20
    if ($loc -like '*wallpaper box*') { break }
    Start-Sleep -Milliseconds 300
}
Mark 'store PC desktop shown in the session window'
$m = [regex]::Match($loc, 'wallpaper box (\d+),(\d+) to')
if ($m.Success) { Ask @{ op = 'calib'; left = [int]$m.Groups[1].Value; top = ([int]$m.Groups[2].Value + 1); scale = 1.0 } 20 | Out-Null }
$CropX = if ($m.Success) { [int]$m.Groups[1].Value - $Region[0] } else { 1 }
$CropY = if ($m.Success) { [int]$m.Groups[2].Value - $Region[1] } else { 31 }
Start-Sleep -Milliseconds 900

# Navigation 1: the stuck job on the old printer.
$lv = [SL]::ChildRect($OldQueue.Hwnd, 'SysListView32')
$hd = [SL]::ChildRect($OldQueue.Hwnd, 'SysHeader32')
Helper-Point ($lv[0] + 90) ($hd[3] + 11) 900
Helper-Click -Right
Mark 'right-click on the stuck job'
$menuTexts = ''
$mi = Wait-Until { [SL]::MenuItemRect('Cancel', [ref]$menuTexts) } 6 150
if (-not $mi) { Debug-Shot 'menu-missing'; throw 'the job menu did not open on the store PC' }
Helper-Point ($mi[0] + 30) ([int](($mi[1] + $mi[3]) / 2)) 550
Helper-Click
Mark 'Cancel chosen'
$dlgText = ''
$yes = Wait-Until { [SL]::DialogButtonRect('Yes', [ref]$dlgText) } 6 150
if (-not $yes) { Debug-Shot 'confirm-missing'; throw 'the confirmation did not appear on the store PC' }
Helper-Point ([int](($yes[0] + $yes[2]) / 2)) ([int](($yes[1] + $yes[3]) / 2)) 650
Helper-Click
Mark 'Yes: the stuck job is cancelled'

# Navigation 2: print the document again, to the printer that works.
$fm = [SL]::MenuBarItemRect($Notepad.Hwnd, 'File')
if (-not $fm) { throw "Notepad's File menu was not found" }
Helper-Point ([int](($fm[0] + $fm[2]) / 2)) ([int](($fm[1] + $fm[3]) / 2)) 900
Helper-Click
Mark 'Notepad: File menu'
$printTexts = ''
$pi = Wait-Until { [SL]::MenuItemRect('Print', [ref]$printTexts) } 6 150
Note "File menu: $printTexts"
if (-not $pi) { Debug-Shot 'file-menu-missing'; throw 'the File menu did not open' }
Helper-Point ($pi[0] + 40) ([int](($pi[1] + $pi[3]) / 2)) 500
Helper-Click
Mark 'Print... chosen'
$dlg = Wait-Until { [SL]::Windows() | Where-Object { $_.Cls -eq '#32770' -and $_.Title -eq 'Print' } | Select-Object -First 1 } 8 150
if (-not $dlg) { Debug-Shot 'print-dialog-missing'; throw 'the Print dialog did not open' }
Start-Sleep -Milliseconds 500
$target = $null
$plv = [SL]::ChildHandle($dlg.Hwnd, 'SysListView32')
if ($plv -ne [IntPtr]::Zero) {
    $rows = [SL]::ListViewItems($plv)
    Note "printers in the Print dialog: $($rows -join ' / ')"
    foreach ($row in $rows) { $f5 = $row.Split('|'); if ($f5[0] -eq $P.Printer) { $target = @([int]$f5[1], [int]$f5[2], [int]$f5[3], [int]$f5[4]) } }
}
if (-not $target) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($dlg.Hwnd).FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $P.Printer)))
    if ($el) { $rr = $el.Current.BoundingRectangle; $target = @([int]$rr.Left, [int]$rr.Top, [int]$rr.Right, [int]$rr.Bottom); Note 'printer found through UI Automation' }
}
if (-not $target) { Debug-Shot 'printer-item-missing'; throw "'$($P.Printer)' not found in the Print dialog" }
Helper-Point ([int](($target[0] + $target[2]) / 2)) ([int](($target[1] + $target[3]) / 2)) 800
Helper-Click
Mark "'$($P.Printer)' selected"
$pbText = ''
$pb = [SL]::DialogButtonRect('Print', [ref]$pbText)
if (-not $pb) { Debug-Shot 'print-button-missing'; throw 'no Print button' }
Helper-Point ([int](($pb[0] + $pb[2]) / 2)) ([int](($pb[1] + $pb[3]) / 2)) 650
Helper-Click
Mark 'Print clicked'
$printed = Wait-Until { $jp = Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue; if ($jp -and ("$($jp[0].JobStatus)" -match 'Printed')) { $jp } } 30 300
$oldLeft = @(Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue).Count
Note "working printer: $(if ($printed) { "'$($printed[0].DocumentName)' status '$($printed[0].JobStatus)'" } else { 'no printed job' }); old printer: $oldLeft job(s)"
if (-not $printed) { Debug-Shot 'not-printed'; throw 'the document did not print on the working printer' }
Mark "printed: '$($P.Doc)' shows Printed on '$($P.Printer)', the old queue is empty"
Start-Sleep -Milliseconds 1200
Mark 'end'

# The cut: 14 to 20 s, the same still time before the first mark and after the last.
$span = $Marks[$Marks.Count - 1][0] - $Marks[0][0]
$pad = [Math]::Max(300, [int]((15000 - $span) / 2))
if ($span + 2 * $pad -gt 20000) { $pad = [Math]::Max(0, [int]((20000 - $span) / 2)) }
$pad = [Math]::Min($pad, 1400)
Note "take $span ms between the first and the last mark; $pad ms kept before and after"
$tail = $Marks[$Marks.Count - 1][0] + $pad + 300 - (Now-Ms)
if ($tail -gt 0) { Start-Sleep -Milliseconds $tail }
Ask @{ op = 'rec-stop' } 180 | Out-Null
Note "store PC recording: $([SL]::RecordStop())"
$CutFrom = $Marks[0][0] - $pad
$CutTo = $Marks[$Marks.Count - 1][0] + $pad

# ---------------------------------------------------------------- 6. stills from the take, videos, the ending
function Frame-At([string] $RecDir, [int64] $When) {
    $start = [int64](Get-Content (Join-Path $RecDir 'start.txt'))
    $rows = @(Import-Csv (Join-Path $RecDir 'frames.csv'))
    $best = $rows | Sort-Object { [Math]::Abs([int64]$_.ms - ($When - $start)) } | Select-Object -First 1
    return (Join-Path $RecDir ('frame-{0:D5}.png' -f [int]$best.frame))
}
function Save-Crop([string] $From, [string] $To, [int] $X, [int] $Y, [int] $W, [int] $H) {
    $bmp = [System.Drawing.Bitmap]::FromFile($From)
    try {
        $r = New-Object System.Drawing.Rectangle($X, $Y, [Math]::Min($W, $bmp.Width - $X), [Math]::Min($H, $bmp.Height - $Y))
        $part = $bmp.Clone($r, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $part.Save($To, [System.Drawing.Imaging.ImageFormat]::Png); $part.Dispose()
    } finally { $bmp.Dispose() }
}
$tShown = ($Marks | Where-Object { $_[1] -like 'store PC desktop shown*' } | Select-Object -First 1)[0] + 700
$tEnd = $Marks[$Marks.Count - 1][0] - 300
Step 'Stills from the recorded take (the same frames as the videos)'
$f = Frame-At $recHelper $tShown; Copy-Item $f (Join-Path $Shots "$base-01-controller-problem$Tag.png")
Save-Crop $f (Join-Path $Shots "$base-01-controller-problem$Tag-remote-only.png") $CropX $CropY $s[2] $s[3]
Copy-Item (Frame-At $recStore $tShown) (Join-Path $Shots "$base-03-controlled-screen$Tag.png")
$f = Frame-At $recHelper $tEnd; Copy-Item $f (Join-Path $Shots "$base-02-controller-fixed$Tag.png")
Save-Crop $f (Join-Path $Shots "$base-02-controller-fixed$Tag-remote-only.png") $CropX $CropY $s[2] $s[3]
Copy-Item (Frame-At $recStore $tEnd) (Join-Path $Shots "$base-03-controlled-screen-fixed$Tag.png")
Note "stills taken from the frames at $($tShown - $CutFrom) ms and $($tEnd - $CutFrom) ms of the videos; remote-only crop at +$CropX,+$CropY"

Step 'Lossless videos of the take (FFV1, real speed)'
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) {
    choco install ffmpeg -y --no-progress --limit-output | Out-Null
    $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    if (-not $ff -and (Test-Path 'C:\ProgramData\chocolatey\bin\ffmpeg.exe')) { $ff = 'C:\ProgramData\chocolatey\bin\ffmpeg.exe' }
}
$steps = @("Steps of the $Set take, seconds from the start of both videos (they start at the same moment):")
foreach ($mk in $Marks) { $steps += ('{0,6:N2} s  {1}' -f (($mk[0] - $CutFrom) / 1000.0), $mk[1]) }
foreach ($rec in @(@($recHelper, "$base-05-take-controller$Tag"), @($recStore, "$base-05-take-controlled$Tag"))) {
    $times = @(Import-Csv (Join-Path $rec[0] 'frames.csv'))
    $start = [int64](Get-Content (Join-Path $rec[0] 'start.txt'))
    $sel = @($times | Where-Object { [int64]$_.ms -ge ($CutFrom - $start) -and [int64]$_.ms -le ($CutTo - $start) })
    $real = [int64]$sel[$sel.Count - 1].ms - [int64]$sel[0].ms
    Note "$($rec[1]): $($times.Count) frames recorded ($([Math]::Round(($times.Count - 1) * 1000.0 / [Math]::Max(1, [int64]$times[$times.Count - 1].ms - [int64]$times[0].ms), 1)) fps); kept $($sel.Count) frames over $real ms"
    if ($ff) {
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
        if (Test-Path $mkv) { Note "video $($rec[1]).mkv $((Get-Item $mkv).Length) bytes, $(($real + 50) / 1000.0) s" }
    }
    $first = [int]$sel[0].frame; $last = [int]$sel[$sel.Count - 1].frame
    foreach ($k in @($first, [int](($first + $last) / 2), $last)) {
        Copy-Item -Force (Join-Path $rec[0] ('frame-{0:D5}.png' -f $k)) (Join-Path $Debug ('{0}-frame-{1:D5}.png' -f $rec[1], $k)) -ErrorAction SilentlyContinue
    }
    $sel | Export-Csv -NoTypeInformation -Path (Join-Path $Shots "$($rec[1])-frames.csv")
}
Set-Content -Path (Join-Path $Shots "$base-05-take-steps$Tag.txt") -Value $steps -Encoding ASCII
$steps | ForEach-Object { Note $_ }

# Extra: the store PC's connection panel opened from its taskbar button, while still connected.
Step 'Extra: the connection panel on the store PC, opened from its taskbar button'
$cmPid = [uint32](@($cm)[0].ProcessId)
$cmWin = [SL]::Windows() | Where-Object { $_.Pid -eq $cmPid -and $_.Width -gt 50 } | Select-Object -First 1
if ($cmWin) {
    [SL]::Show($cmWin.Hwnd, 9); [SL]::Front($cmWin.Hwnd)
    Start-Sleep -Seconds 2
    Note "controlled screen with the panel: $([SL]::ShotScreen((Join-Path $Shots "$base-06-controlled-screen-panel$Tag.png")))"
    Start-Sleep -Milliseconds 800
    Ask @{ op = 'shot'; dir = $Shots; name = "$base-06-controller-panel$Tag" } 30 | Out-Null
} else { Note 'no connection panel window found on the store PC' }

Step 'D. The good ending: the helper closes the session; the store PC afterwards'
Ask @{ op = 'close-remote' } 20 | Out-Null
$gone = Wait-Until { -not (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' }) } 15 500
Note "session over on the store PC: $([bool]$gone)"
[SL]::Front($Notepad.Hwnd)
Start-Sleep -Seconds 2
Note "D. working screen: $([SL]::ShotScreen((Join-Path $Shots "$base-04-working$Tag.png")))"
Note "after the session: '$($P.Printer)' $(@(Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', '); '$Old' $(@(Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue).Count) job(s)"
Copy-Item -Force "$Shots\*.txt" $Out -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 7. evidence and clean-up
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
Write-Host "RESULT the $Set take saved"
