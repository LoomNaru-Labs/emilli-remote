# Round 3 of the connected-session pictures (brief REMOTE-SESSION-CAPTURE-3), store set only, on a
# fresh GitHub "windows-latest" runner only. It installs software, adds and removes printers,
# adds a local user, switches on Remote Desktop and signs that user in, so never run it on a PC
# that matters.
#
#   powershell -File session-capture/run-take3.ps1 -Setup <setup.exe> -Out <folder> [-Msg en|ko]
#
# One runner plays both PCs as in rounds 1 and 2 (run-take.ps1): the console session is the store
# PC (175 %, large pointer), a second Windows session is the helper, who connects with the
# installed app to 127.0.0.1 by direct access. Five recordings, each on both screens where the
# helper is connected:
#   1. problem: the staff (the store PC's own mouse) prints the receipt; the job goes to the
#      default printer, which does not answer; Windows' red-icon message box says so (a prop,
#      as round 2's option b);
#   2. diagnostic: the helper double-clicks the "Printer check" support script on the store PC's
#      desktop (printer-check.ps1: real queries of the print service, printers, ports, queue);
#   3. fix: through the session, the helper opens Printers, the old printer's queue, cancels the
#      stuck job, opens the working printer's queue and sets it as the default printer;
#   4. message: the helper opens the session toolbar, Chat, Text chat, types the message and
#      sends it; the store PC's connection panel shows it;
#   5. print works: the staff closes the panel and prints again; the working printer gets it.
# Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Out,
    # The message the helper sends: English, or the Korean take.
    [ValidateSet('en', 'ko')] [string] $Msg = 'en',
    [ValidateSet(100, 125, 150, 175, 200)] [int] $Scale = 175,
    [ValidateRange(32, 256)] [int] $PointerPx = 96
)
$ErrorActionPreference = 'Stop'
$Tag = if ($Msg -eq 'ko') { '-ko' } else { '' }

$Dir = 'C:\sc'
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$HelperUser = 'Helper'
$Wall = @(38, 84, 124)
$Peer = '127.0.0.1'
$Fps = 15

$Printer = 'Receipt Printer'; $PrinterPort = 'ReceiptPrinterPort'
$Old = 'Old Receipt Printer'; $OldPort = 'OldReceiptPrinterPort'
$Root = 'C:\Store'; $Doc = 'Receipt_0412.txt'
$DocPath = Join-Path $Root "Receipts\$Doc"
$Lines = @('Receipt 0412      Table 7', '2  Lunch set        18.00', '1  Iced tea          3.50', '1  Side salad        4.50',
           'Subtotal            26.00', 'Tax                  2.34', 'Total               28.34', 'Thank you!')
# "Fixed. Please print again." and, for the Korean take, the same in Korean as code points
# (the script stays ASCII): "hae-gyeol-dwaet-seum-ni-da. da-si in-swae-hae bo-se-yo."
$Message = if ($Msg -eq 'ko') {
    @{ cp = @(0xD574, 0xACB0, 0xB410, 0xC2B5, 0xB2C8, 0xB2E4, 0x2E, 0x20, 0xB2E4, 0xC2DC, 0x20, 0xC778, 0xC1C4, 0xD574, 0x20, 0xBCF4, 0xC138, 0xC694, 0x2E) }
} else { @{ text = 'Fixed. Please print again.' } }

$Shots = Join-Path $Dir 'out\shots'
$Debug = Join-Path $Out 'debug'
$CheckLog = Join-Path $Dir 'out\check.json'
$CheckDone = Join-Path $Dir 'out\check-done.txt'
$SinkLog = Join-Path $Dir 'out\sink.log'
$Done = New-Object System.Collections.ArrayList
$Missed = New-Object System.Collections.ArrayList

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

function Ensure-Key([string] $Path) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Debug-Shot([string] $Name) {
    try { [SL]::ShotScreen((Join-Path $Debug "console-$Name.png")) | Out-Null } catch { Note "debug shot $Name failed: $($_.Exception.Message)" }
}

trap {
    Write-Host "FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Debug-Shot 'failure'
    try { Ask @{ op = 'screen'; dir = $Shots; name = 'helper-failure' } 20 | Out-Null } catch { }
    Copy-Item -Force "$Dir\out\agent.log", $CheckLog, $SinkLog, (Join-Path $Shots 'helper-*.png') $Debug -ErrorAction SilentlyContinue
    Write-Host "RESULT round 3 stopped; saved: $($Done -join ', '); not made: $($Missed -join ', ')"
    break
}

New-Item -ItemType Directory -Force -Path $Out, $Debug, $Dir, "$Dir\bin", "$Dir\cmd", "$Dir\done", "$Dir\tmp", "$Dir\out", $Shots, "$Dir\secret" | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'SessionLib.cs'), (Join-Path $PSScriptRoot 'helper-agent.ps1'), (Join-Path $PSScriptRoot 'printer-check.ps1') "$Dir\bin"
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'SessionLib.cs')
Add-Type -AssemblyName System.Drawing, System.Security, UIAutomationClient, UIAutomationTypes

$s = [SL]::Screen()
Note "console: session $([SL]::MySession()), user $env:USERNAME, screen $($s[2])x$($s[3]), $([Environment]::OSVersion.VersionString); message take '$Msg'"

# ffmpeg for the videos, fetched while the rest is set up.
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
$chocoProc = $null
if (-not $ff) { $chocoProc = Start-Process -FilePath choco -ArgumentList @('install', 'ffmpeg', '-y', '--no-progress', '--limit-output') -PassThru -WindowStyle Hidden }

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

# The helper's real mouse through the session, to a point of the store PC's screen.
function Helper-Act([int] $X, [int] $Y, [string] $Click = '', [int] $Ms = 450) {
    $c = @{ op = 'move'; rx = $X; ry = $Y; ms = $Ms }
    if ($Click) { $c.click = $Click }
    Ask $c 30 | Out-Null
}
function Mid([int[]] $r) { return @([int](($r[0] + $r[2]) / 2), [int](($r[1] + $r[3]) / 2)) }
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# The store PC's own mouse (the staff), at a human pace.
function Staff-Act([int] $X, [int] $Y, [string] $Click = 'left', [int] $Ms = 500) {
    [SL]::Glide($X, $Y, $Ms)
    Start-Sleep -Milliseconds 120
    switch ($Click) { 'left' { [SL]::Click($false) } 'right' { [SL]::Click($true) } 'double' { [SL]::DoubleClick() } }
}

function Wait-Window([scriptblock] $Match, [int] $Seconds = 10) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $w = [SL]::Windows() | Where-Object $Match | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 30
    }
    return $null
}

# An item of a window found through UI Automation (Explorer's item view has no Win32 rows), in
# screen pixels: UI Automation's view of the whole screen is mapped onto the real one.
function Uia-Rect([IntPtr] $Hwnd, [string] $Name) {
    $A = [System.Windows.Automation.AutomationElement]
    $both = [System.Windows.Automation.Condition[]]@(
        (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $Name)),
        (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)))
    $cond = New-Object System.Windows.Automation.AndCondition(, $both)
    $el = $A::FromHandle($Hwnd).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $el) { return $null }
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty -or $r.Width -le 0) { return $null }
    $f = $s[2] / $A::RootElement.Current.BoundingRectangle.Width
    return @([int]($r.Left * $f), [int]($r.Top * $f), [int]($r.Right * $f), [int]($r.Bottom * $f))
}

# A desktop icon's rectangle (the desktop is a list view with Win32 rows).
function Desktop-Icon([string] $Name) {
    $lv = [SL]::DesktopListView()
    if ($lv -eq [IntPtr]::Zero) { return $null }
    foreach ($row in [SL]::ListViewItems($lv)) {
        $f5 = $row.Split('|')
        if ($f5[0] -eq $Name) { return @([int]$f5[1], [int]$f5[2], [int]$f5[3], [int]$f5[4]) }
    }
    return $null
}

# The store PC's connection panel (the app's connection manager window, rustdesk.exe --cm).
function CM-Window {
    $ids = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' } | ForEach-Object { [uint32]$_.ProcessId })
    if ($ids.Count -eq 0) { return $null }
    return [SL]::Windows() | Where-Object { $ids -contains $_.Pid -and $_.Cls -eq 'FLUTTER_RUNNER_WIN32_WINDOW' } | Select-Object -First 1
}

# What Windows itself says right now (beside the printer check's own findings).
function State-Query([string] $When) {
    $svc = Get-Service -Name Spooler
    $def = (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' | Select-Object -First 1).Name
    Note "STATE ($When): Spooler $($svc.Status); default printer '$def'"
    foreach ($p in (Get-Printer | Sort-Object Name)) {
        $jobs = @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', '
        Note "STATE ($When): '$($p.Name)' status $($p.PrinterStatus), port $($p.PortName); jobs: $(if ($jobs) { $jobs } else { 'none' })"
    }
    $l9100 = [bool](Get-NetTCPConnection -LocalPort 9100 -State Listen -ErrorAction SilentlyContinue)
    $l9 = [bool](Get-NetTCPConnection -LocalPort 9 -State Listen -ErrorAction SilentlyContinue)
    Note "STATE ($When): a listener on port 9100 ('$Printer', the stand-in printer): $l9100; on port 9 ('$Old'): $l9"
}

# ---------------------------------------------------------------- recordings
$script:Cur = $null
function Mark([string] $Label) { [void]$script:Cur.Marks.Add(@((Now-Ms), $Label)); Note "mark [$($script:Cur.Base)]: $Label" }
function Rec-Begin([string] $Base, [switch] $Helper) {
    $script:Cur = @{ Base = "$Base$Tag"; Store = (Join-Path $Shots "rec-$Base-store"); Helper = $null; Marks = (New-Object System.Collections.ArrayList) }
    [SL]::RecordStart(0, 0, $s[2], $s[3], $Fps, $script:Cur.Store, 40)
    if ($Helper) {
        $script:Cur.Helper = Join-Path $Shots "rec-$Base-helper"
        Ask @{ op = 'rec-start'; dir = $script:Cur.Helper; fps = $Fps; x = $Region[0]; y = $Region[1]; w = $Region[2]; h = $Region[3] } 20 | Out-Null
    }
    Start-Sleep -Milliseconds 900
    Mark 'start'
}
function Rec-End([int] $TailMs = 1200) {
    $last = $script:Cur.Marks[$script:Cur.Marks.Count - 1][0]
    $wait = $last + $TailMs - (Now-Ms)
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    Mark 'end'
    if ($script:Cur.Helper) { Ask @{ op = 'rec-stop' } 300 | Out-Null }
    Note "store PC recording: $([SL]::RecordStop())"
    $script:Cur.Stopped = $true
    Save-Rec $script:Cur
}
# After a failed step inside a recording: stop and keep it (named -partial).
function Rec-Abort {
    if (-not $script:Cur -or $script:Cur.Stopped) { return }
    $script:Cur.Base = "$($script:Cur.Base)-partial"
    try { Rec-End 300 } catch { Note "partial recording not saved: $($_.Exception.Message)" }
}
function Frame-At([string] $RecDir, [int64] $When) {
    $start = [int64](Get-Content (Join-Path $RecDir 'start.txt'))
    $rows = @(Import-Csv (Join-Path $RecDir 'frames.csv'))
    $best = $rows | Sort-Object { [Math]::Abs([int64]$_.ms - ($When - $start)) } | Select-Object -First 1
    return (Join-Path $RecDir ('frame-{0:D5}.png' -f [int]$best.frame))
}
function Slug([string] $t) { return (($t.ToLower() -replace "[^a-z0-9]+", '-').Trim('-')) }
# Videos (FFV1, lossless, each frame at its real time), the step times, and a still of both
# screens at every step (250 ms after it), all copied to the artifact folder at once.
function Save-Rec($R) {
    if ($chocoProc -and -not $chocoProc.HasExited) { $chocoProc.WaitForExit(300000) | Out-Null }
    if (-not $script:FF) {
        $script:FF = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
        if (-not $script:FF -and (Test-Path 'C:\ProgramData\chocolatey\bin\ffmpeg.exe')) { $script:FF = 'C:\ProgramData\chocolatey\bin\ffmpeg.exe' }
    }
    $from = $R.Marks[0][0] - 700
    $to = $R.Marks[$R.Marks.Count - 1][0]
    $sides = @(, @('store', $R.Store))
    if ($R.Helper) { $sides += , @('helper', $R.Helper) }
    $steps = @("Steps of $($R.Base), seconds from the start of the video$(if ($R.Helper) { 's (store PC and helper start at the same moment)' }):")
    foreach ($mk in $R.Marks) { $steps += ('{0,6:N2} s  {1}' -f (($mk[0] - $from) / 1000.0), $mk[1]) }
    Set-Content -Path (Join-Path $Out "$($R.Base)-steps.txt") -Value $steps -Encoding ASCII
    $steps | ForEach-Object { Note $_ }
    foreach ($side in $sides) {
        $rec = $side[1]; $name = "$($R.Base)-$($side[0])"
        $times = @(Import-Csv (Join-Path $rec 'frames.csv'))
        $start = [int64](Get-Content (Join-Path $rec 'start.txt'))
        $sel = @($times | Where-Object { [int64]$_.ms -ge ($from - $start) -and [int64]$_.ms -le ($to - $start) })
        if ($sel.Count -lt 2) { Note "$name`: too few frames ($($sel.Count))"; continue }
        $real = [int64]$sel[$sel.Count - 1].ms - [int64]$sel[0].ms
        Note "$name`: $($times.Count) frames recorded ($([Math]::Round(($times.Count - 1) * 1000.0 / [Math]::Max(1, [int64]$times[$times.Count - 1].ms - [int64]$times[0].ms), 1)) fps); kept $($sel.Count) frames over $real ms"
        if ($script:FF) {
            $list = @('ffconcat version 1.0')
            for ($i = 0; $i -lt $sel.Count; $i++) {
                $dur = if ($i + 1 -lt $sel.Count) { ([int64]$sel[$i + 1].ms - [int64]$sel[$i].ms) / 1000.0 } else { 1.0 / $Fps }
                $list += ("file 'frame-{0:D5}.png'" -f [int]$sel[$i].frame)
                $list += ('duration {0}' -f $dur.ToString([Globalization.CultureInfo]::InvariantCulture))
            }
            $list += ("file 'frame-{0:D5}.png'" -f [int]$sel[$sel.Count - 1].frame)
            $listPath = Join-Path $rec 'list.ffconcat'
            Set-Content -Path $listPath -Value $list -Encoding ASCII
            $mkv = Join-Path $Out "$name.mkv"
            cmd /c "`"$($script:FF)`" -hide_banner -loglevel error -y -f concat -safe 0 -i `"$listPath`" -fps_mode cfr -r $Fps -c:v ffv1 -level 3 -pix_fmt bgr0 `"$mkv`" 2>&1" | ForEach-Object { Note "ffmpeg: $_" }
            if (Test-Path $mkv) {
                Note "video $name.mkv $((Get-Item $mkv).Length) bytes, $(($real + 67) / 1000.0) s"
                # Read back from the video file itself: frame count and size, and its first,
                # middle and last frames decoded to pictures (verify\).
                $ver = Join-Path $Out 'verify'
                New-Item -ItemType Directory -Force -Path $ver | Out-Null
                $probe = Join-Path (Split-Path $script:FF) 'ffprobe.exe'
                if (Test-Path $probe) { Note "ffprobe $name.mkv: $(cmd /c "`"$probe`" -v error -count_frames -select_streams v:0 -show_entries stream=codec_name,width,height,nb_read_frames,r_frame_rate:format=duration -of compact `"$mkv`" 2>&1")" }
                $inv = [Globalization.CultureInfo]::InvariantCulture
                foreach ($pt in @(@('first', 0.0), @('middle', ($real / 2000.0)), @('last', [Math]::Max(0.0, $real / 1000.0 - 0.12)))) {
                    cmd /c "`"$($script:FF)`" -hide_banner -loglevel error -y -ss $(([double]$pt[1]).ToString('0.000', $inv)) -i `"$mkv`" -frames:v 1 `"$ver\$name-video-$($pt[0]).png`" 2>&1" | ForEach-Object { Note "ffmpeg: $_" }
                }
            }
        } else { Note 'no ffmpeg: frames only' }
        $sel | Export-Csv -NoTypeInformation -Path (Join-Path $Out "$name-frames.csv")
        $k = 0
        foreach ($mk in $R.Marks) {
            $k++
            $png = Join-Path $Out ('{0}-{1:D2}-{2}-{3}.png' -f $R.Base, $k, (Slug $mk[1]), $side[0])
            Copy-Item -Force (Frame-At $rec ([Math]::Min($mk[0] + 250, $to))) $png
        }
    }
    [void]$Done.Add($R.Base)
}

# ---------------------------------------------------------------- 1. Emilli Remote as a store PC
Step 'Install Emilli Remote Setup as a store PC (silent, throwaway password)'
$pwFile = Join-Path $Dir 'secret\pw.txt'
[System.IO.File]::WriteAllText($pwFile, (New-Secret 10))
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
Note "listening on 21118: $([bool]$listen)"
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
if (-not $sid) { Debug-Shot 'rdp-failed'; throw 'the helper session did not start' }
Note "helper session $sid is signed in"
Start-Sleep -Seconds 8
foreach ($w in [SL]::Windows()) {
    if ($w.Proc -eq 'mstsc' -and $w.Cls -eq 'TscShellContainerClass') {
        [SL]::Place($w.Hwnd, -3200, 60, 1400, 900)
        [SL]::HideFromTaskbar($w.Hwnd)
        Note "Remote Desktop client window moved off the store PC's screen"
    }
}

Step 'Start the helper agent in the helper session'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bin\helper-agent.ps1`" -Dir `"$Dir`""
$pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$HelperUser" -LogonType Interactive -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'EmilliSessionHelper' -Action $act -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName 'EmilliSessionHelper'
Ask @{ op = 'hello' } 90 | Out-Null

# ---------------------------------------------------------------- 2b. larger: scale and pointer (as round 2)
Step "The store PC at $Scale % with a larger pointer ($PointerPx px)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\windows-capture\capture-display.ps1') -Width $s[2] -Height $s[3] -Scale $Scale | ForEach-Object { Note $_ }
$wantDpi = [int](96 * $Scale / 100)
$dpiNow = Wait-Until { $d = [SL]::MonitorDpi(); if ($d -eq $wantDpi) { $d } } 15 500
Note "store PC screen DPI now $([SL]::MonitorDpi()) (wanted $wantDpi)"
if (-not $dpiNow) { Debug-Shot 'scale-not-set'; throw "the store PC is not at $Scale %" }
Note "store PC pointer: $([SL]::SetPointerPixels($PointerPx))"
$helperDpi = Ask @{ op = 'dpi' } 20
if ($helperDpi -notmatch 'DPI 96$') { throw "the helper's screen changed with the store PC ($helperDpi)" }
Ask @{ op = 'pointer'; px = [int]($PointerPx * $Scale / 100) } 20 | Out-Null

# ---------------------------------------------------------------- 3. the store PC as the staff sees it
Step 'Stage the store PC: plain desktop with two shortcuts, the receipt, two printers'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value ''
Set-ItemProperty 'HKCU:\Control Panel\Colors' -Name Background -Value ($Wall -join ' ')
[SL]::PlainDesktop($Wall[0], $Wall[1], $Wall[2])
# Only our two shortcuts on the desktop: the runner's own items are moved aside (throwaway
# machine) and the Recycle Bin icon is hidden.
$hide = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
Ensure-Key $hide
Set-ItemProperty $hide -Name '{645FF040-5081-101B-9F08-00AA002F954E}' -Value 1 -Type DWord
$parked = Join-Path $Dir 'desktop-parked'
New-Item -ItemType Directory -Force -Path $parked | Out-Null
foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
    Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
        Note "desktop item moved aside: $($_.Name)"
        Move-Item -LiteralPath $_.FullName -Destination $parked -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Force -Path "$Dir\support" | Out-Null
$ws = New-Object -ComObject WScript.Shell
$desk = [Environment]::GetFolderPath('Desktop')
$lnk = $ws.CreateShortcut((Join-Path $desk 'Printer check.lnk'))
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bin\printer-check.ps1`" -X 960 -Y 16 -W 940 -H 780 -Log `"$CheckLog`""
$lnk.WindowStyle = 7
$lnk.WorkingDirectory = "$Dir\support"
$lnk.Description = 'Printer check'
$lnk.Save()
$lnk = $ws.CreateShortcut((Join-Path $desk 'Printers.lnk'))
$lnk.TargetPath = "$env:SystemRoot\explorer.exe"
$lnk.Arguments = 'shell:::{2227A280-3AEA-1069-A2DE-08002B30309D}'
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,16"
$lnk.Description = 'Printers'
$lnk.Save()
Note "desktop icons shown: $([SL]::ShowDesktopIcons())"
[SL]::RefreshShell()
Ensure-Key 'HKCU:\Software\Microsoft\Notepad'
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name iPointSize -Value 160 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name lfFaceName -Value 'Consolas'
Set-ItemProperty 'HKCU:\Software\Microsoft\Notepad' -Name StatusBar -Value 0 -Type DWord
# Console programs stay in Windows' console host (no hand-off to Windows Terminal), so the
# printer check's hidden PowerShell console stays hidden.
Ensure-Key 'HKCU:\Console\%%Startup'
Set-ItemProperty 'HKCU:\Console\%%Startup' -Name DelegationConsole -Value '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'
Set-ItemProperty 'HKCU:\Console\%%Startup' -Name DelegationTerminal -Value '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'
foreach ($f in @('Receipts', 'Menu', 'Reports')) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $f) | Out-Null }
[System.IO.File]::WriteAllText($DocPath, (($Lines -join "`r`n") + "`r`n"))

# Printers: only the store's two. Windows does not move the default printer by itself
# (LegacyDefaultPrinterMode), so the default stays what the take sets.
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord
Set-Service -Name Spooler -StartupType Automatic
Start-Service -Name Spooler
foreach ($p in @(Get-Printer -ErrorAction SilentlyContinue)) {
    try { Remove-Printer -Name $p.Name; Note "runner printer removed: $($p.Name)" } catch { Note "runner printer kept: $($p.Name) ($($_.Exception.Message))" }
}
$driver = $null
foreach ($d in @('Generic / Text Only', 'Microsoft Software Printer Driver', 'Microsoft Print To PDF', 'Microsoft XPS Document Writer v4', 'Microsoft PS Class Driver')) {
    try {
        if (-not (Get-PrinterDriver -Name $d -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $d }
        $driver = $d; break
    } catch { Note "driver '$d' not available: $($_.Exception.Message)" }
}
if (-not $driver) { throw 'no printer driver' }
Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'printer-sink.ps1'), '-Log', $SinkLog)
$sinkUp = Wait-Until { Get-NetTCPConnection -LocalPort 9100 -State Listen -ErrorAction SilentlyContinue } 20
Note "stand-in printer listening on 9100: $([bool]$sinkUp)"
Add-PrinterPort -Name $PrinterPort -PrinterHostAddress '127.0.0.1' -PortNumber 9100
Add-Printer -Name $Printer -DriverName $driver -PortName $PrinterPort
Set-Printer -Name $Printer -KeepPrintedJobs $true
# The old printer, still the default: its port points where nothing answers (round 1 probe:
# Windows then reports the job as an error after about 20 s).
Add-PrinterPort -Name $OldPort -PrinterHostAddress '127.0.0.1' -PortNumber 9
Add-Printer -Name $Old -DriverName $driver -PortName $OldPort
Get-CimInstance Win32_Printer -Filter "Name='$Old'" | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null
Note "printers now: $((Get-Printer | ForEach-Object { "'$($_.Name)' on $($_.PortName)" }) -join ', '); default '$((Get-CimInstance Win32_Printer -Filter 'Default=TRUE').Name)'"

Get-Process -Name SystemPropertiesPerformance -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($w in [SL]::Windows()) {
    if ($w.Cls -in @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS') -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        [SL]::Show($w.Hwnd, 6); [SL]::HideFromTaskbar($w.Hwnd); Note "runner window hidden: $w"
    }
    if ($w.Cls -eq '#32770' -and [SL]::SessionOf($w.Pid) -eq [SL]::MySession()) {
        $texts = [SL]::ChildTexts($w.Hwnd)
        Note "dialog on the store PC: $w $texts"
        if ($texts -match 'paging file') { Note "  closed: $([SL]::ClickButton($w.Hwnd, 'OK'))" }
    }
}
Start-Process -FilePath notepad.exe -ArgumentList "`"$DocPath`""
$Notepad = Wait-Window { $_.Proc -eq 'notepad' } 30
if (-not $Notepad) { throw 'Notepad did not open' }
Start-Sleep -Seconds 1
[SL]::Place($Notepad.Hwnd, 160, 16, 760, 560)
[SL]::Front($Notepad.Hwnd)
Start-Sleep -Seconds 2
$both = Wait-Until { if ((Desktop-Icon 'Printer check') -and (Desktop-Icon 'Printers')) { 'both' } } 15 500
$icons = @([SL]::ListViewItems([SL]::DesktopListView()))
Note "desktop icons: $($icons -join ' / ')"
if (-not $both) { Debug-Shot 'icons-missing'; throw 'the desktop shortcuts are not on the desktop' }

# The error window (a prop as in round 2, option b): started now, shown on a signal right after
# the staff's Print click.
$ErrSignal = Join-Path $Dir 'tmp\error-go.txt'
Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'error-box.ps1'), '-Title', "`"$Old`"", '-Text', '"The document could not be printed."', '-Signal', "`"$ErrSignal`"")

# ---------------------------------------------------------------- 4. the helper's side, ready
$Region = @(307, 60, $s[2], ($s[3] + 34))
Step 'Helper: warm-up connection (closed at the password prompt), then the main window, idle'
Ask @{ op = 'hide-icons' } 20 | Out-Null
Ask @{ op = 'warm'; exe = $Exe; peer = $Peer; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 90 | Out-Null
Start-Sleep -Seconds 2
Ask @{ op = 'open-main'; exe = $Exe; x = $Region[0]; y = $Region[1]; w = $Region[2]; h = $Region[3] } 60 | Out-Null
Ask @{ op = 'find-connect' } 20 | Out-Null
# Attempt 2: the first Printers window took 5 s to open and UI Automation 4 s more to find its
# items. Both are used once here, before anything is filmed, and the window closed again.
$t0 = Get-Date
Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList 'shell:::{2227A280-3AEA-1069-A2DE-08002B30309D}'
$wf = Wait-Window { $_.Cls -eq 'CabinetWClass' -and $_.Title -like 'Printers*' } 30
if ($wf) {
    [SL]::Place($wf.Hwnd, 160, 470, 780, 520)
    $warm = Wait-Until { Uia-Rect $wf.Hwnd $Old } 20 300
    Note "warm-up of the Printers window: open, item found at $($warm -join ',') after $([int]((Get-Date) - $t0).TotalMilliseconds) ms"
    [SL]::PostClose($wf.Hwnd)
    Wait-Until { -not ([SL]::Windows() | Where-Object { $_.Hwnd -eq $wf.Hwnd }) } 10 200 | Out-Null
} else { Note 'warm-up: no Printers window' }
[SL]::Front($Notepad.Hwnd)
Debug-Shot 'staged'

# ---------------------------------------------------------------- item 1: the problem (staff)
Step 'Item 1: the staff prints the receipt; it does not print'
$RestX = 640; $RestY = 820
[SL]::Glide(560, 300, 60)
Start-Sleep -Milliseconds 400
function Staff-Print([string] $Expect) {
    $fm = [SL]::MenuBarItemRect($Notepad.Hwnd, 'File')
    if (-not $fm) { throw "Notepad's File menu was not found" }
    $p = Mid $fm; Staff-Act $p[0] $p[1] 'left' 600
    Mark 'staff: File'
    $t = ''
    $pi = Wait-Until { [SL]::MenuItemRect('Print', [ref]$t) } 6 100
    if (-not $pi) { Debug-Shot 'file-menu-missing'; throw 'the File menu did not open' }
    Staff-Act ($pi[0] + 50) ([int](($pi[1] + $pi[3]) / 2)) 'left' 450
    Mark 'staff: Print...'
    $dlg = Wait-Window { $_.Cls -eq '#32770' -and $_.Title -eq 'Print' } 8
    if (-not $dlg) { Debug-Shot 'print-dialog-missing'; throw 'the Print dialog did not open' }
    Start-Sleep -Milliseconds 250
    $plv = [SL]::ChildHandle($dlg.Hwnd, 'SysListView32')
    $sel = '(unknown)'
    if ($plv -ne [IntPtr]::Zero) {
        $rows = @([SL]::ListViewItems($plv)); $i = [SL]::ListViewSelected($plv)
        if ($i -ge 0 -and $i -lt $rows.Count) { $sel = $rows[$i].Split('|')[0] }
        Note "printers in the Print dialog: $(($rows | ForEach-Object { $_.Split('|')[0] }) -join ' / '); selected '$sel'"
    }
    if ($sel -ne $Expect) {
        # Notepad keeps the printer of its last print (attempt 2): the staff picks the right one.
        $row = $rows | Where-Object { $_.Split('|')[0] -eq $Expect } | Select-Object -First 1
        if (-not $row) { Debug-Shot 'unexpected-printer'; throw "'$Expect' is not in the Print dialog" }
        $f5 = $row.Split('|')
        Staff-Act ([int](([int]$f5[1] + [int]$f5[3]) / 2)) ([int](([int]$f5[2] + [int]$f5[4]) / 2)) 'left' 450
        Start-Sleep -Milliseconds 200
        $i = [SL]::ListViewSelected($plv); $sel = if ($i -ge 0 -and $i -lt $rows.Count) { $rows[$i].Split('|')[0] } else { '(none)' }
        Note "selected in the Print dialog now: '$sel'"
        if ($sel -ne $Expect) { Debug-Shot 'unexpected-printer'; throw "the Print dialog has '$sel' selected, not '$Expect'" }
        Mark "staff: chooses '$Expect'"
    }
    $pbText = ''
    $pb = [SL]::DialogButtonRect('Print', [ref]$pbText)
    if (-not $pb) { throw 'no Print button' }
    $p = Mid $pb; Staff-Act $p[0] $p[1] 'left' 500
    Mark "staff: Print (to '$Expect', the default printer)"
}
Rec-Begin 'r3-store-1-problem'
Staff-Print $Old
$job = Wait-Until { Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue } 5 100
Note "the job on '$Old': $(@($job | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', ')"
Start-Sleep -Milliseconds 300
Set-Content -Path $ErrSignal -Value 'go' -Encoding ASCII
$ErrBox = Wait-Window { $_.Cls -eq '#32770' -and $_.Title -eq $Old -and $_.Proc -eq 'powershell' } 6
if (-not $ErrBox) { Debug-Shot 'error-box-missing'; throw 'the error message box did not open' }
# Attempt 1 showed the box opening behind Notepad (its own topmost flag did not take while
# Notepad held the foreground); it is put in front at once.
[SL]::Topmost($ErrBox.Hwnd, $true); [SL]::Front($ErrBox.Hwnd)
Mark 'the red-icon error window: "The document could not be printed."'
Start-Sleep -Milliseconds 700
Note "1. error screen: $([SL]::ShotScreen((Join-Path $Out "r3-store-1-problem$Tag-error-screen.png")))"
Note "error window: $([SL]::Info($ErrBox.Hwnd)) $([SL]::ChildTexts($ErrBox.Hwnd))"
Rec-End 1300
# The staff closes the error window and calls for help (not filmed).
$ok = [SL]::ButtonRect($ErrBox.Hwnd, 'OK')
if ($ok) { $p = Mid $ok; Staff-Act $p[0] $p[1] 'left' 400 }
[SL]::Glide($RestX, $RestY, 400)

# ---------------------------------------------------------------- the helper connects (as round 2, not filmed)
Step 'The helper connects: address, Connect, password'
Ask @{ op = 'click-at'; what = 'field'; ms = 400 } 20 | Out-Null
Ask @{ op = 'type'; text = $Peer; ms = 60 } 20 | Out-Null
Ask @{ op = 'click-at'; what = 'connect'; ms = 300 } 20 | Out-Null
Ask @{ op = 'wait-remote'; peer = $Peer; seconds = 20 } 30 | Out-Null
Ask @{ op = 'park'; vx = $Region[0]; vy = $Region[1]; vw = $Region[2]; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 10 | Out-Null
Ask @{ op = 'glide'; x = ($Region[0] + 1 + $RestX); y = ($Region[1] + 32 + $RestY); ms = 400 } 10 | Out-Null
Ask @{ op = 'type-secret'; ms = 55 } 20 | Out-Null
function Desktop-Shown {
    $r = Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 20
    $mm = [regex]::Match($r, 'wallpaper box (\d+),(\d+) to (\d+),(\d+).*not black (\d+)/1000')
    if ($mm.Success -and ([int]$mm.Groups[3].Value - [int]$mm.Groups[1].Value) -ge ($s[2] - 300) -and [int]$mm.Groups[5].Value -ge 500) { return $r }
    return $null
}
$loc = $null
for ($i = 0; $i -lt 40 -and -not $loc; $i++) { $loc = Desktop-Shown; if (-not $loc) { Start-Sleep -Milliseconds 250 } }
if (-not $loc) {
    Ask @{ op = 'screen'; dir = $Shots; name = 'helper-password-retry' } 20 | Out-Null
    Ask @{ op = 'type-secret'; ms = 70; clickx = ($Region[0] + [int]($Region[2] / 2)); clicky = ($Region[1] + [int]($Region[3] / 2) - 10) } 20 | Out-Null
    for ($i = 0; $i -lt 40 -and -not $loc; $i++) { $loc = Desktop-Shown; if (-not $loc) { Start-Sleep -Milliseconds 250 } }
}
if (-not $loc) { Debug-Shot 'not-accepted'; Ask @{ op = 'screen'; dir = $Shots; name = 'helper-not-accepted' } 20 | Out-Null; throw 'the store PC desktop did not appear in the session window' }
Note "connected: $loc"
Ask @{ op = 'rec-cursor'; on = $false } 10 | Out-Null
# The picture starts at the session window's +1,+32 (round 2: 1:1, scale 1.0).
$m = [regex]::Match($loc, 'wallpaper box (\d+),(\d+) to')
if ($m.Success) { Ask @{ op = 'calib'; left = [int]$m.Groups[1].Value; top = ([int]$m.Groups[2].Value + 1); scale = 1.0 } 20 | Out-Null }
else { Ask @{ op = 'calib'; left = ($Region[0] + 1); top = ($Region[1] + 32); scale = 1.0 } 20 | Out-Null }
$cmAt = CM-Window
Note "store PC panel after the connection: $cmAt"
$hidden = Wait-Until { $w = CM-Window; if (-not $w -or $w.Iconic) { 'hidden' } } 30 300
Note "store PC panel went out of the way by itself: $([bool]$hidden) ($(CM-Window))"
$job = @(Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue)
Note "the job on '$Old' now: $(@($job | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', ')"
$errState = Wait-Until { $j = Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue; if ($j -and ("$($j[0].JobStatus)" -match 'Error')) { $j } } 60 1000
Note "stuck job state before the check: $(@(Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', ')"
Debug-Shot 'before-item-2'
Ask @{ op = 'screen'; dir = $Shots; name = 'helper-before-item-2' } 20 | Out-Null

# ---------------------------------------------------------------- item 2: the diagnostic
Step 'Item 2: the helper starts the printer check on the store PC'
$ic = Desktop-Icon 'Printer check'
Note "'Printer check' icon at $($ic -join ',')"
Remove-Item -Force $CheckLog, $CheckDone -ErrorAction SilentlyContinue
State-Query 'item 2, before the check'
Rec-Begin 'r3-store-2-diagnostic' -Helper
try {
Helper-Act ([int](($ic[0] + $ic[2]) / 2)) ([int]($ic[1] + ($ic[3] - $ic[1]) * 0.35)) 'double' 650
Mark "helper: double-click on 'Printer check'"
$chk = Wait-Window { $_.Title -eq 'Printer check' -and $_.Cls -like 'WindowsForms*' } 10
if (-not $chk -and -not (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*printer-check.ps1*' })) {
    # The double-click only selected the icon: once more, as a person would.
    Debug-Shot 'check-not-started'
    Helper-Act ([int](($ic[0] + $ic[2]) / 2)) ([int]($ic[1] + ($ic[3] - $ic[1]) * 0.35)) 'double' 300
    Mark "helper: double-click on 'Printer check' again"
}
if (-not $chk) { $chk = Wait-Window { $_.Title -eq 'Printer check' -and $_.Cls -like 'WindowsForms*' } 25 }
if (-not $chk) { Debug-Shot 'check-missing'; throw 'the printer check window did not open' }
Mark 'the Printer check window opens'
$fin = Wait-Until { Test-Path $CheckDone } 30 100
if (-not $fin) { Debug-Shot 'check-unfinished'; throw 'the printer check did not finish' }
Mark 'the finding shows'
State-Query 'item 2, at the finding'
Rec-End 1800
Note "printer check window: $([SL]::Info($chk.Hwnd)) DPI $([SL]::WindowDpi($chk.Hwnd))"
} catch {
    Note "ITEM 2 FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    [void]$Missed.Add('item 2: the printer check')
    Debug-Shot 'item-2-failed'
    Rec-Abort
}
Get-Content -Path $CheckLog -ErrorAction SilentlyContinue | ForEach-Object { Note "check: $_" }
Copy-Item -Force $CheckLog (Join-Path $Out "r3-store-2-diagnostic$Tag-check.json") -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- item 3: the fix
Step 'Item 3: the helper fixes it through the session'
$isDef = $null; $gqList = [IntPtr]::Zero
try {
$pf = Desktop-Icon 'Printers'
Rec-Begin 'r3-store-3-fix' -Helper
Helper-Act ([int](($pf[0] + $pf[2]) / 2)) ([int]($pf[1] + ($pf[3] - $pf[1]) * 0.35)) 'double' 550
Mark "helper: double-click on 'Printers'"
$folder = Wait-Window { $_.Cls -eq 'CabinetWClass' -and $_.Title -like 'Printers*' } 15
if (-not $folder) { Debug-Shot 'printers-folder-missing'; [SL]::Windows() | ForEach-Object { Note "window: $_" }; throw 'the Printers window did not open' }
[SL]::Place($folder.Hwnd, 160, 470, 780, 520)
Mark 'the Printers window opens'
$oi = Wait-Until { Uia-Rect $folder.Hwnd $Old } 8 150
if (-not $oi) { Debug-Shot 'old-item-missing'; throw "'$Old' not found in the Printers window" }
$p = Mid $oi; Helper-Act $p[0] $p[1] 'double' 480
Mark "helper: double-click on '$Old'"
$oq = Wait-Window { $_.Title -like "$Old*" -and $_.Cls -notin @('#32770', 'CabinetWClass') } 15
if (-not $oq) { Debug-Shot 'old-queue-missing'; [SL]::Windows() | ForEach-Object { Note "window: $_" }; throw "the queue of '$Old' did not open" }
[SL]::Place($oq.Hwnd, 960, 560, 940, 430)
$qf = [SL]::WindowDpi($oq.Hwnd) / [double][SL]::MonitorDpi()
$oqList = [SL]::ChildHandle($oq.Hwnd, 'SysListView32')
if ($oqList -ne [IntPtr]::Zero) { [SL]::SetColumnWidth($oqList, 0, [int](300 * $qf)); [SL]::SetColumnWidth($oqList, 1, [int](300 * $qf)) }
Mark "the queue of '$Old' opens: 1 document, Error - Printing"
Start-Sleep -Milliseconds 250
$lv = [SL]::ChildRect($oq.Hwnd, 'SysListView32')
$hd = [SL]::ChildRect($oq.Hwnd, 'SysHeader32')
Helper-Act ($lv[0] + 140) ($hd[3] + [int](10 * [SL]::MonitorDpi() / 96)) 'right' 450
Mark 'helper: right-click on the stuck job'
$t = ''
$mi = Wait-Until { [SL]::MenuItemRect('Cancel', [ref]$t) } 6 100
if (-not $mi) { Debug-Shot 'job-menu-missing'; throw 'the job menu did not open' }
Helper-Act ($mi[0] + 30) ([int](($mi[1] + $mi[3]) / 2)) 'left' 400
Mark 'helper: Cancel'
$dt = ''
$yes = Wait-Until { [SL]::DialogButtonRect('Yes', [ref]$dt) } 6 100
if (-not $yes) { Debug-Shot 'confirm-missing'; throw 'the confirmation did not appear' }
Note "confirmation: $dt"
$p = Mid $yes; Helper-Act $p[0] $p[1] 'left' 400
Mark 'helper: Yes (the stuck job is cancelled)'
$ri = Uia-Rect $folder.Hwnd $Printer
if (-not $ri) { Debug-Shot 'item-missing'; throw "'$Printer' not found in the Printers window" }
$p = Mid $ri; Helper-Act $p[0] $p[1] 'double' 480
Mark "helper: double-click on '$Printer'"
$gq = Wait-Window { $_.Title -like "$Printer*" -and $_.Cls -notin @('#32770', 'CabinetWClass') } 15
if (-not $gq) { Debug-Shot 'queue-missing'; throw "the queue of '$Printer' did not open" }
[SL]::Place($gq.Hwnd, 960, 560, 940, 430)
$gqList = [SL]::ChildHandle($gq.Hwnd, 'SysListView32')
if ($gqList -ne [IntPtr]::Zero) { [SL]::SetColumnWidth($gqList, 0, [int](300 * $qf)); [SL]::SetColumnWidth($gqList, 1, [int](300 * $qf)) }
Mark "the queue of '$Printer' opens: empty, ready"
Start-Sleep -Milliseconds 200
$pm = [SL]::MenuBarItemRect($gq.Hwnd, 'Printer')
if (-not $pm) { throw "no Printer menu in the queue of '$Printer'" }
$p = Mid $pm; Helper-Act $p[0] $p[1] 'left' 420
Mark 'helper: Printer menu'
$t = ''
$sd = Wait-Until { [SL]::MenuItemRect('Set As Default', [ref]$t) } 6 100
Note "Printer menu: $t"
if (-not $sd) { Debug-Shot 'printer-menu-missing'; throw 'the Printer menu did not open' }
Helper-Act ($sd[0] + 60) ([int](($sd[1] + $sd[3]) / 2)) 'left' 420
Mark 'helper: Set As Default Printer'
Start-Sleep -Milliseconds 300
$dt = ''
$okd = [SL]::DialogButtonRect('OK', [ref]$dt)
if ($okd) { Note "a notice after Set As Default: $dt"; $p = Mid $okd; Helper-Act $p[0] $p[1] 'left' 400; Mark 'helper: OK on the notice' }
$isDef = Wait-Until { $d = (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' | Select-Object -First 1).Name; if ($d -eq $Printer) { $d } } 6 150
if ($isDef) { Mark "'$Printer' is the default printer now" } else { Note "default printer is still '$((Get-CimInstance Win32_Printer -Filter 'Default=TRUE').Name)'" }
$empty = Wait-Until { @(Get-PrintJob -PrinterName $Old -ErrorAction SilentlyContinue).Count -eq 0 } 6 200
if ($empty) { Mark "the queue of '$Old' is empty" }
Rec-End 1400
} catch {
    # One item failing does not stop the others: the partial recording is kept for checking.
    Note "ITEM 3 FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Debug-Shot 'item-3-failed'
    try { Ask @{ op = 'screen'; dir = $Shots; name = 'helper-item-3-failed' } 20 | Out-Null } catch { }
    Rec-Abort
}
State-Query 'item 3, after the fix'
if (-not $isDef) { [void]$Missed.Add('item 3: the default printer did not change') }

# ---------------------------------------------------------------- item 4: the message
Step "Item 4: the helper sends a message through the app's chat ($Msg)"
$cm0 = CM-Window
Note "store PC panel before the message: $cm0"
$msgCmd = @{ op = 'chat-type'; ms = 70 }
foreach ($k in $Message.Keys) { $msgCmd[$k] = $Message[$k] }
Rec-Begin 'r3-store-4-message' -Helper
Ask @{ op = 'rec-cursor'; on = $true } 10 | Out-Null
$chatOk = $true
try {
    Ask @{ op = 'toolbar-show'; ms = 650 } 30 | Out-Null
    Mark 'helper: Show Toolbar (the toolbar opens)'
    Ask @{ op = 'chat-open'; ms = 450 } 30 | Out-Null
    Mark 'helper: Chat, Text chat (the chat window opens)'
    Ask $msgCmd 40 | Out-Null
    Mark 'helper: the message typed'
    Ask @{ op = 'chat-send'; ms = 380 } 30 | Out-Null
    Mark 'helper: send'
    $shown = Wait-Until { $w = CM-Window; if ($w -and -not $w.Iconic -and $w.Width -gt 900) { $w } } 8 50
    if ($shown) { Mark 'the message shows on the store PC (the panel opens with the chat)' } else { $chatOk = $false; Note "the store PC panel did not open with the chat: $(CM-Window)" }
} catch { $chatOk = $false; Note "chat: $($_.Exception.Message)"; Ask @{ op = 'screen'; dir = $Shots; name = 'helper-chat-failed' } 20 | Out-Null }
Rec-End 2600
Ask @{ op = 'rec-cursor'; on = $false } 10 | Out-Null
$cm1 = CM-Window
Note "store PC panel after the message: $cm1"
if (-not $chatOk) { [void]$Missed.Add('item 4: the message did not arrive'); Debug-Shot 'message-missing' }

# ---------------------------------------------------------------- item 5: printing works (staff)
Step 'Item 5: the staff prints again'
$through = $null
if (-not $isDef) { Note 'item 5 skipped: the fix did not make the working printer the default' }
else { try {
$sinkBefore = @(Get-Content -Path $SinkLog -ErrorAction SilentlyContinue).Count
Rec-Begin 'r3-store-5-print' -Helper
$cm = CM-Window
if ($cm -and -not $cm.Iconic -and $cm.Width -gt 200) {
    # The panel's own minimize button: the flat dark line among the two glyphs at its top right.
    $fr = [SL]::Frame($cm.Hwnd)
    $gl = @([SL]::Clusters($fr.Right - 170, $fr.Top + 4, 166, 52, 'dark', 1) | Where-Object { ($_[2] - $_[0]) -ge 10 })
    Note "panel title glyphs: $(($gl | ForEach-Object { '[' + ($_[0..3] -join ',') + ']' }) -join ' ')"
    $mn = $gl | Where-Object { ($_[3] - $_[1]) -le 6 } | Sort-Object { $_[0] } | Select-Object -First 1
    $mx = if ($mn) { [int](($mn[0] + $mn[2]) / 2) } else { $fr.Right - 72 }
    $my = if ($mn) { [int](($mn[1] + $mn[3]) / 2) } else { $fr.Top + 26 }
    Staff-Act $mx $my 'left' 650
    Mark 'staff: minimizes the panel with the message'
    $gone = Wait-Until { $w = CM-Window; if (-not $w -or $w.Iconic) { 'yes' } } 3 100
    Note "panel minimized: $([bool]$gone)"
}
Staff-Print $Printer
$through = Wait-Until { @(Get-Content -Path $SinkLog -ErrorAction SilentlyContinue).Count -gt $sinkBefore } 15 200
if ($through) { Mark "the job reaches '$Printer' (the stand-in printer received it)" }
$shownQ = $null
if ($gqList -ne [IntPtr]::Zero) { $shownQ = Wait-Until { @([SL]::ListViewItems($gqList, 1)) | Where-Object { $_ -like 'Printed|*' } | Select-Object -First 1 } 6 150 }
if ($shownQ) { Mark "the queue of '$Printer' shows Printed" } else { Note "the queue's Status column: $(@([SL]::ListViewItems($gqList, 1)) -join ' / ')" }
Rec-End 1600
Note "stand-in printer: $(@(Get-Content -Path $SinkLog -ErrorAction SilentlyContinue) -join ' / '); probes: $(@(Get-Content -Path ($SinkLog -replace '\.log$', '-probes.log') -ErrorAction SilentlyContinue).Count)"
State-Query 'item 5, after printing'
Note "5. working screen: $([SL]::ShotScreen((Join-Path $Out "r3-store-5-print$Tag-working-screen.png")))"
Ask @{ op = 'shot'; dir = $Shots; name = "r3-store-5-print$Tag-helper-window" } 30 | Out-Null
Copy-Item -Force (Join-Path $Shots "r3-store-5-print$Tag-helper-window*.png") $Out -ErrorAction SilentlyContinue
} catch {
    Note "ITEM 5 FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Debug-Shot 'item-5-failed'
    Rec-Abort
} }
if (-not $through) { [void]$Missed.Add('item 5: the job did not reach the working printer') }

# ---------------------------------------------------------------- evidence and clean-up
Step 'Session evidence from the logs (short lines)'
$pattern = 'direct access|Connection opened|onnection closed|Logged|[Ll]ogin|authoriz|[Cc]hat'
$roots = @("$SvcRoot\log", 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\log',
           "$env:APPDATA\RustDesk\log", "C:\Users\$HelperUser\AppData\Roaming\RustDesk\log")
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.log' | ForEach-Object {
        Note "log file $($_.FullName) ($($_.Length) bytes)"
        $hits = Select-String -Path $_.FullName -Pattern $pattern | Where-Object { $_.Line -notmatch 'ipc connection closed' } | Select-Object -First 14
        foreach ($h in $hits) {
            $line = $h.Line -replace '[A-Za-z0-9+/]{40,}={0,2}', '(long value hidden)'
            if ($line.Length -gt 240) { $line = $line.Substring(0, 240) + ' ...' }
            Note "  $line"
        }
    }
}
Get-Content -Path "$Dir\out\agent.log" -ErrorAction SilentlyContinue | ForEach-Object { Note "agent: $_" }
Ask @{ op = 'close-remote' } 20 | Out-Null
Ask @{ op = 'quit' } 20 | Out-Null
Copy-Item -Force "$Dir\out\agent.log", $SinkLog, (Join-Path $Shots 'helper-*.png') $Debug -ErrorAction SilentlyContinue
Remove-Item -Force -Recurse "$Dir\secret" -ErrorAction SilentlyContinue
cmdkey "/delete:TERMSRV/127.0.0.2" | Out-Null
cmd /c "logoff $sid 2>nul"
Start-Sleep -Seconds 5
Remove-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue
Note "throwaway user removed: $(-not (Get-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue))"
Get-ChildItem $Out -File | ForEach-Object { Note "saved $($_.Name) ($($_.Length) bytes)" }
Write-Host "RESULT round 3 ($Msg) saved: $($Done -join ', '); not made: $(if ($Missed.Count) { $Missed -join ', ' } else { 'nothing' })"
