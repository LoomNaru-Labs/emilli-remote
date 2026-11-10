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
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'

$Dir = 'C:\sc'
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$HelperUser = 'Helper'
$Wall = @(38, 84, 124)
$Peer = '127.0.0.1'

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

New-Item -ItemType Directory -Force -Path $Out, $Debug, $Dir, "$Dir\bin", "$Dir\cmd", "$Dir\done", "$Dir\tmp", "$Dir\out", $Shots, "$Dir\secret" | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'SessionLib.cs'), (Join-Path $PSScriptRoot 'helper-agent.ps1') "$Dir\bin"
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'SessionLib.cs')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Security
$A = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

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
        Start-Sleep -Milliseconds 200
    }
    throw "the helper did not answer $name within $Timeout s"
}

# A move at a human pace to a point of the store PC's screen, through the session.
function Helper-Point([int] $X, [int] $Y, [int] $Ms = 900) {
    Ask @{ op = 'move'; rx = $X; ry = $Y; ms = $Ms } 30 | Out-Null
}
function Helper-Click([switch] $Right) {
    Ask @{ op = 'sleep'; ms = 300 } 10 | Out-Null
    Ask @{ op = 'click'; right = [bool]$Right } 10 | Out-Null
}

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
Ask @{ op = 'place'; x = 40; y = 30; w = 2060; h = 1290 } 20 | Out-Null
Start-Sleep -Seconds 2
Ask @{ op = 'screen'; dir = $Shots; name = 'debug-helper-after-place' } 20 | Out-Null
Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 30 | Out-Null

# ---------------------------------------------------------------- 5. pictures and the fix
$base = "session-$Set"
[SL]::Front($Queue.Hwnd)
Start-Sleep -Seconds 2
Helper-Point 1500 760 700
Start-Sleep -Seconds 2
Ask @{ op = 'shot'; dir = $Shots; name = "$base-01-controller-problem"; screen = $true } 30 | Out-Null
Note "controlled screen: $([SL]::ShotScreen((Join-Path $Shots "$base-03-controlled-screen.png")))"
Note "queue before the fix: $(@(Get-PrintJob -PrinterName $P.Printer).Count) job(s), status '$((Get-PrintJob -PrinterName $P.Printer)[0].JobStatus)'"

Step 'The helper cancels the stuck job through the session (real mouse input)'
$qa = $A::FromHandle($Queue.Hwnd)
$item = $null
foreach ($e in $qa.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    $t = $e.Current.ControlType
    if (($t -eq $CT::DataItem -or $t -eq $CT::ListItem) -and $e.Current.Name -like "*$($P.Doc)*") { $item = $e; break }
}
if (-not $item) { throw 'the job row was not found in the queue window' }
$r = $item.Current.BoundingRectangle
Note "job row at $($r.X),$($r.Y) size $($r.Width)x$($r.Height)"
Helper-Point ([int]($r.X + 90)) ([int]($r.Y + $r.Height / 2)) 1100
Helper-Click -Right
$menuItem = Wait-Until {
    foreach ($m in $A::RootElement.FindAll($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Menu)))) {
        foreach ($i in $m.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::MenuItem)))) {
            if (($i.Current.Name -replace '&', '') -like 'Cancel*') { return $i }
        }
    }
} 8 250
Debug-Shot 'menu'
if (-not $menuItem) { throw 'the job menu did not open on the store PC' }
$r = $menuItem.Current.BoundingRectangle
Note "menu item '$($menuItem.Current.Name)' at $($r.X),$($r.Y)"
Helper-Point ([int]($r.X + 30)) ([int]($r.Y + $r.Height / 2)) 600
Helper-Click
$yes = Wait-Until {
    foreach ($w in $A::RootElement.FindAll($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($A::ClassNameProperty, '#32770')))) {
        foreach ($b in $w.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Button)))) {
            if (($b.Current.Name -replace '&', '') -eq 'Yes') { return $b }
        }
    }
} 8 250
Debug-Shot 'confirm'
if (-not $yes) { throw 'the confirmation did not appear on the store PC' }
$r = $yes.Current.BoundingRectangle
Helper-Point ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2)) 700
Helper-Click
$empty = Wait-Until { -not (Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue) } 40
Note "queue after the fix: $(@(Get-PrintJob -PrinterName $P.Printer -ErrorAction SilentlyContinue).Count) job(s)"
if (-not $empty) { throw 'the job did not go away' }
Start-Sleep -Seconds 2
$nr = [SL]::Info($Notepad.Hwnd)
Helper-Point ($nr.Left + 420) ($nr.Top + 300) 900
Helper-Click
Start-Sleep -Seconds 2
Ask @{ op = 'shot'; dir = $Shots; name = "$base-02-controller-fixed"; screen = $true } 30 | Out-Null
Note "controlled screen after the fix: $([SL]::ShotScreen((Join-Path $Shots "$base-03-controlled-screen-fixed.png")))"

# ---------------------------------------------------------------- 6. evidence and clean-up
Step 'Session evidence from the logs'
$pattern = 'direct access from|Connection opened|onnection.*(established|closed)|login|Login|authoriz|peer info|PeerInfo|selected_sid|video service|Mouse|mouse'
foreach ($root in @("$SvcRoot\log", "$env:APPDATA\RustDesk\log", "C:\Users\$HelperUser\AppData\Roaming\RustDesk\log")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.log' | ForEach-Object {
        $hits = Select-String -Path $_.FullName -Pattern $pattern | Select-Object -First 25
        foreach ($h in $hits) {
            $line = $h.Line -replace '[A-Za-z0-9+/]{40,}={0,2}', '(long value hidden)'
            Note "$($_.Directory.Name)/$($_.Name): $line"
        }
    }
}
Get-Content -Path "$Dir\out\agent.log" -ErrorAction SilentlyContinue | ForEach-Object { Note "agent: $_" }

Ask @{ op = 'quit' } 20 | Out-Null
Copy-Item -Force "$Shots\*.png" $Out
Copy-Item -Force "$Dir\out\agent.log" $Debug -ErrorAction SilentlyContinue
Remove-Item -Force -Recurse "$Dir\secret" -ErrorAction SilentlyContinue
cmdkey "/delete:TERMSRV/127.0.0.2" | Out-Null
cmd /c "logoff $sid 2>nul"
Start-Sleep -Seconds 5
Remove-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue
Note "throwaway user removed: $(-not (Get-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue))"
Get-ChildItem $Out -Filter '*.png' | ForEach-Object { Note "saved $($_.Name) ($($_.Length) bytes)" }
Write-Host "RESULT session pictures for the $Set set saved"
