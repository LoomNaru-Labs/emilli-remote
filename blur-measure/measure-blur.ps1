# How long an Emilli Remote session picture stays blurry after the screen changes (brief
# REMOTE-BLUR), on a fresh GitHub "windows-latest" runner only. It installs software, adds a
# local user, switches on Remote Desktop and signs that user in, so never run it on a PC that
# matters.
#
#   powershell -File blur-measure/measure-blur.ps1 -Setup <setup.exe> -Out <folder>
#
# One runner plays both PCs, as in the session captures (session-capture/run-take3.ps1): the
# console session is the store PC with the tested Emilli Remote Setup installed as a store PC;
# a second Windows session (a throwaway user signed in through a Remote Desktop loopback) is the
# helper, who connects with the installed app to 127.0.0.1 (direct access). A loopback is not a
# slow internet line: these numbers are the best case of each setting.
#
# The store PC shows a text-heavy page A (text-pages.ps1). For each setting the helper connects
# with that setting as its default (RustDesk_default.toml, the file the app's own Settings >
# Display writes), the picture settles, the helper's view of a 1280x720 piece of the screen is
# recorded at 15 frames a second, the store PC switches to page B, and the recording goes on for
# 12 seconds. Every frame is compared with the store PC's own screen (grey levels, mean
# difference per pixel), so the numbers say how far the helper's picture is from the real one
# at each moment after the change.
#
# Two kinds of screen: "ticker" (a small square on the store PC blinks twice a second, as a
# clock or a caret does on a real PC; it is outside the measured piece) and "still" (nothing on
# the store PC changes after page B appears).
# Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [string] $Setup = '',
    [Parameter(Mandatory)] [string] $Out,
    [string] $Only = $env:BLUR_ONLY,
    # Attempt 4: upstream's own installer (rustdesk-<version>-x86_64.exe) instead of our Setup,
    # to see whether upstream's later fix clears what attempt 3 found.
    [string] $Official = '',
    # REMOTE-153: the settings of the 1.5.3 build (the defaults, a store PC that fails the AV1
    # speed test, the slow-line floor) instead of attempt 4's list.
    [string] $Matrix = ''
)
$ErrorActionPreference = 'Stop'

$Dir = 'C:\sc'
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$HelperUser = 'Helper'
$Wall = @(38, 84, 124)
$Peer = '127.0.0.1'
$Fps = 15
$Margin = 30
# The measured piece of the store PC's screen, and the extra border recorded around it so the
# helper's picture can be lined up with the store PC's own pixels.
$Cx = 320; $Cy = 180; $Cw = 1280; $Ch = 720; $Pad = 4
$AfterMs = 12000

# image_quality / codec-preference / custom_image_quality as the app's Display settings store them.
# Attempt 1 (run 42928158910) measured the four quality modes and the three codecs at full speed:
# every one was sharp from its first frame on the loopback. Attempt 2 measures the state a slow
# line pushes the session into: the app's own speed control (src/server/video_qos.rs) lowers the
# bitrate to its floor, about half of Balanced (min_ratio: 0.335 of the base bitrate for Balanced,
# 0.1 to 0.2 for Low and Custom). The same bitrate is set here with Custom quality: 17 (0.34,
# the Balanced floor) and 10 (0.2), per codec. Balanced VP9 "still" is repeated (attempt 1 lost
# it to a signal-file race in text-pages.ps1).
# Attempt 2 (run 42932699115): even at the floor every codec was sharp from its first frame after
# a one-step page change. Attempt 3 measures what upstream changed in 1.5.1 ("improve clarity
# after scrolling by re-encoding static frames", rustdesk/rustdesk#16128): a tall list scrolled
# for 1.5 s (510 pixels at 340 pixels a second), then still; the clock starts when it stops.
# Attempt 4 (upstream 1.5.3 only): the settings that stayed blurry in attempt 3, plus Auto.
$Settings = @(
    @{ name = 'balanced-vp9';  q = 'balanced'; codec = 'vp9' },
    @{ name = 'custom17-vp9';  q = 'custom';   codec = 'vp9'; custom = 17 },
    @{ name = 'balanced-vp8';  q = 'balanced'; codec = 'vp8' },
    @{ name = 'balanced-auto'; q = 'balanced'; codec = 'auto' }
)
$Modes = @('scroll-ticker', 'scroll-still')
# REMOTE-153 (1.5.3 build, both PCs on it). "default": no defaults file at all, so the helper
# uses what the app ships with. "weak": the store PC's AV1 speed test failed (option av1-test N,
# what the app saves on a PC too slow for AV1), so Auto picks VP9 there. A setting with "modes"
# runs only those screens.
if ($Matrix -eq '153') {
    $Settings = @(
        @{ name = 'default';          none = $true;                         av1test = 'Y' },
        @{ name = 'weak-default';     none = $true;                         av1test = 'N' },
        @{ name = 'weak-best';        q = 'best';     codec = 'auto';       av1test = 'N' },
        @{ name = 'weak-custom17';    q = 'custom';   codec = 'auto'; custom = 17; av1test = 'N'; modes = @('scroll-still') },
        @{ name = 'default-custom17'; q = 'custom';   codec = 'auto'; custom = 17; av1test = 'Y'; modes = @('scroll-still') },
        @{ name = 'balanced-vp8';     q = 'balanced'; codec = 'vp8';        av1test = 'Y'; modes = @('scroll-still') }
    )
}

$Results = New-Object System.Collections.ArrayList

function Step([string] $m) { Write-Host ("STEP {0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Note([string] $m) { Write-Host "  $m" }
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

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

$Debug = Join-Path $Out 'debug'
function Debug-Shot([string] $Name) {
    try { [SL]::ShotScreen((Join-Path $Debug "console-$Name.png")) | Out-Null } catch { Note "debug shot $Name failed: $($_.Exception.Message)" }
}

trap {
    Write-Host "FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Debug-Shot 'failure'
    try { Ask @{ op = 'screen'; dir = $Debug; name = 'helper-failure' } 20 | Out-Null } catch { }
    Copy-Item -Force "$Dir\out\agent.log" $Debug -ErrorAction SilentlyContinue
    Write-Host "RESULT blur measurement stopped after $($Results.Count) sessions"
    break
}

New-Item -ItemType Directory -Force -Path $Out, $Debug, $Dir, "$Dir\bin", "$Dir\cmd", "$Dir\done", "$Dir\tmp", "$Dir\out", "$Dir\secret", "$Dir\rec" | Out-Null
$lib = Join-Path $PSScriptRoot '..\session-capture\SessionLib.cs'
Copy-Item -Force $lib "$Dir\bin\SessionLib.cs"
# The helper agent of the session captures, allowed to run for 100 minutes instead of 40.
$agentText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\session-capture\helper-agent.ps1'))
if ($agentText -notmatch 'AddMinutes\(40\)') { throw 'helper-agent.ps1 changed: no 40-minute deadline found' }
[System.IO.File]::WriteAllText("$Dir\bin\helper-agent.ps1", ($agentText -replace 'AddMinutes\(40\)', 'AddMinutes(100)'))
Add-Type -ReferencedAssemblies System.Drawing -Path $lib
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'Sharp.cs')
Add-Type -AssemblyName System.Drawing, System.Security

$s = [SL]::Screen()
Note "console: session $([SL]::MySession()), user $env:USERNAME, screen $($s[2])x$($s[3]), $([Environment]::OSVersion.VersionString)"
Note "runner: $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name), $([Environment]::ProcessorCount) logical processors, $([Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)) GB"
Get-CimInstance Win32_VideoController | ForEach-Object { Note "display adapter: $($_.Name)" }

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

function CM-Window {
    $ids = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' } | ForEach-Object { [uint32]$_.ProcessId })
    if ($ids.Count -eq 0) { return $null }
    return [SL]::Windows() | Where-Object { $ids -contains $_.Pid -and $_.Cls -eq 'FLUTTER_RUNNER_WIN32_WINDOW' } | Select-Object -First 1
}

# ---------------------------------------------------------------- 0. can this runner slow a loopback down?
# Windows' own QoS policy (New-NetQosPolicy, part of Windows, nothing installed) is tried on a
# test port first: the listening side sends 2 MB, as the store PC sends the picture from its
# listening port. Only if that is clearly slowed is the same policy put on the session's port.
function Loop-Send([int] $Bytes, [int] $Port) {
    $job = Start-Job -ArgumentList $Bytes, $Port -ScriptBlock {
        param($n, $p)
        $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $p
        $l.Start()
        $c = $l.AcceptTcpClient()
        $st = $c.GetStream()
        $data = New-Object byte[] $n
        $st.Write($data, 0, $n)
        $st.Flush()
        $c.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
        Start-Sleep -Seconds 2
        $c.Close(); $l.Stop()
    }
    $cl = $null
    for ($i = 0; $i -lt 60 -and -not $cl; $i++) {
        try { $t = New-Object System.Net.Sockets.TcpClient; $t.Connect('127.0.0.1', $Port); $cl = $t } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $cl) { Remove-Job $job -Force; throw "no test listener on $Port" }
    $st = $cl.GetStream()
    $buf = New-Object byte[] 65536
    $got = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st.ReadTimeout = 40000
    while ($got -lt $Bytes) {
        $r = $st.Read($buf, 0, $buf.Length)
        if ($r -le 0) { break }
        $got += $r
    }
    $sw.Stop()
    $cl.Close()
    Wait-Job $job -Timeout 20 | Out-Null
    Remove-Job $job -Force
    return @($got, $sw.ElapsedMilliseconds)
}
$Throttle = $false
Step 'Loopback slow-down check (Windows QoS policy, test port 21999, 2 Mbit/s)'
try {
    $plain = Loop-Send 2000000 21999
    Note "without a policy: $($plain[0]) bytes in $($plain[1]) ms"
    New-NetQosPolicy -Name 'BlurProbe' -IPPortMatchCondition 21999 -ThrottleRateActionBitsPerSecond 2000000 -PolicyStore ActiveStore | Out-Null
    $slow = Loop-Send 2000000 21999
    Remove-NetQosPolicy -Name 'BlurProbe' -PolicyStore ActiveStore -Confirm:$false
    Note "with a 2 Mbit/s policy: $($slow[0]) bytes in $($slow[1]) ms (8000 ms if the policy acts)"
    $Throttle = ($slow[1] -ge 4000 -and $slow[1] -ge 4 * [Math]::Max(1, $plain[1]))
    Note "loopback slow-down works on this runner: $Throttle"
} catch { Note "slow-down check failed: $($_.Exception.Message)" }
if ($Throttle) {
    $Settings += @{ name = 'balanced-auto-3mbit'; q = 'balanced'; codec = 'auto'; mbit = 3 }
    $Settings += @{ name = 'best-auto-3mbit'; q = 'best'; codec = 'auto'; mbit = 3 }
}
if ($Only) { $Settings = @($Settings | Where-Object { $Only.Split(',') -contains $_.name }) }

# ---------------------------------------------------------------- 1. Emilli Remote as a store PC
$pwFile = Join-Path $Dir 'secret\pw.txt'
[System.IO.File]::WriteAllText($pwFile, (New-Secret 10))
if ($Official) {
    # The same steps our Setup takes (windows-easy/EmilliRemoteSetup.iss on easy-windows), with
    # upstream's installer and no server: direct access only.
    Step "Install upstream's $([System.IO.Path]::GetFileName($Official)) as a store PC (silent, throwaway password)"
    $proc = Start-Process -FilePath $Official -PassThru -WorkingDirectory "$env:SystemRoot\System32" -ArgumentList @('--silent-install')
    $proc.WaitForExit(300000) | Out-Null
    $inst = Wait-Until { (Test-Path $Exe) -and (Get-Service -Name RustDesk -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) } 300 2000
    if (-not $inst) { throw 'upstream RustDesk was not installed with a running service' }
    Start-Sleep -Seconds 5
    cmd /c "`"$Exe`" --option verification-method use-permanent-password 2>&1" | Out-Null
    cmd /c "`"$Exe`" --option approve-mode password 2>&1" | Out-Null
    $pwNow = ([System.IO.File]::ReadAllText($pwFile)).Trim()
    $said = cmd /c "`"$Exe`" --password $pwNow 2>&1"
    $pwNow = $null
    Note "password set: '$said'; verification-method '$(cmd /c "`"$Exe`" --option verification-method 2>nul")'"
} else {
Step 'Install Emilli Remote Setup as a store PC (silent, throwaway password)'
$setupLog = Join-Path $Debug 'setup.log'
$proc = Start-Process -FilePath $Setup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MODE=store', "/PWFILE=$pwFile", "/LOG=$setupLog")
if (-not $proc.WaitForExit(600000)) { throw 'Setup did not finish in 10 minutes' }
Note "Setup exit code $($proc.ExitCode)"
if (Test-Path $setupLog) { Select-String -Path $setupLog -SimpleMatch 'Emilli:' | ForEach-Object { Note $_.Line.Trim() } }
if ($proc.ExitCode -ne 0) { throw 'Setup failed' }
}
Note "rustdesk.exe $((Get-Item $Exe).VersionInfo.FileVersion), $((Get-Item $Exe).Length) bytes"

Step 'Direct access on (port 21118) and one Windows session served (no session picker)'
cmd /c "`"$Exe`" --option direct-server Y > `"$Dir\tmp\opt-set.txt`" 2>&1"
reg add 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk' /f /v share_rdp /t REG_SZ /d false | Out-Null
$listen = Wait-Until { Get-NetTCPConnection -LocalPort 21118 -State Listen -ErrorAction SilentlyContinue } 60
Note "listening on 21118: $([bool]$listen)"
if (-not $listen) { throw 'RustDesk does not listen on 21118' }
foreach ($k in @('enable-hwcodec', 'av1-test', 'enable-abr', 'enable-directx-capture')) {
    Note "store PC option $k = '$(cmd /c "`"$Exe`" --option $k 2>nul")'"
}

# ---------------------------------------------------------------- 2. the helper's Windows session
Step 'Throwaway local user, Remote Desktop on, loopback sign-in'
$helperPw = 'Hx7' + (New-Secret 21)
New-LocalUser -Name $HelperUser -Password (ConvertTo-SecureString $helperPw -AsPlainText -Force) -PasswordNeverExpires -AccountNeverExpires -Description 'Throwaway user for the blur measurement' | Out-Null
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
if (-not $sid) { Debug-Shot 'rdp-failed'; throw 'the helper session did not start' }
Note "helper session $sid is signed in"
Start-Sleep -Seconds 8
foreach ($w in [SL]::Windows()) {
    if ($w.Proc -eq 'mstsc' -and $w.Cls -eq 'TscShellContainerClass') {
        [SL]::Place($w.Hwnd, -3200, 60, 1400, 900)
        [SL]::HideFromTaskbar($w.Hwnd)
        Note 'Remote Desktop client window moved off the store PC screen'
    }
}

Step 'Start the helper agent in the helper session'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bin\helper-agent.ps1`" -Dir `"$Dir`""
$pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$HelperUser" -LogonType Interactive -RunLevel Limited
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'EmilliBlurHelper' -Action $act -Principal $pr -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName 'EmilliBlurHelper'
Ask @{ op = 'hello' } 90 | Out-Null
Ask @{ op = 'dpi' } 20 | Out-Null
Ask @{ op = 'glide'; x = 8; y = 8; ms = 200 } 20 | Out-Null
Ask @{ op = 'rec-cursor'; on = $false } 10 | Out-Null
$prof = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -match "\\$HelperUser(\.[^\\]+)?$" } | Select-Object -First 1
$HelperHome = if ($prof) { $prof.LocalPath } else { "C:\Users\$HelperUser" }
$HelperCfg = Join-Path $HelperHome 'AppData\Roaming\RustDesk\config'
Note "helper's settings folder: $HelperCfg"

# ---------------------------------------------------------------- 3. the store PC's screen
Step 'Store PC: plain desktop, no icons, the text pages window'
[SL]::PlainDesktop($Wall[0], $Wall[1], $Wall[2])
Note "desktop icon lists hidden: $([SL]::HideDesktopIcons())"
$Signal = Join-Path $Dir 'tmp\page-signal.txt'
$Answer = Join-Path $Dir 'out\page-answer.txt'
Remove-Item -Force $Signal, $Answer -ErrorAction SilentlyContinue
Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'text-pages.ps1'), '-Signal', "`"$Signal`"", '-Answer', "`"$Answer`"", '-Margin', $Margin)
$shown = Wait-Until { if (Test-Path $Answer) { Select-String -Path $Answer -Pattern '^shown' } } 60 500
if (-not $shown) { Debug-Shot 'pages-missing'; throw 'the text pages window did not open' }
Note "pages window: $($shown.Line)"
[SL]::Glide($s[2] - 12, 12, 300)

function Send-Page([string] $Cmd, [int] $Seconds = 10) {
    $before = if (Test-Path $Answer) { @(Get-Content $Answer).Count } else { 0 }
    Start-Sleep -Milliseconds 30
    [System.IO.File]::WriteAllText($Signal, $Cmd)
    $line = Wait-Until { try { $all = @([System.IO.File]::ReadAllLines($Answer)); if ($all.Count -gt $before) { $all[$all.Count - 1] } } catch { $null } } $Seconds 20
    if (-not $line -or $line -notmatch "^$Cmd (\d+)$") { throw "the pages window did not answer '$Cmd' ($line)" }
    return [int64]$Matches[1]
}
# The scroll: the answer is "scroll <start> <end>" once the list has stopped.
function Send-Scroll {
    $before = if (Test-Path $Answer) { @(Get-Content $Answer).Count } else { 0 }
    Start-Sleep -Milliseconds 30
    [System.IO.File]::WriteAllText($Signal, 'scroll')
    $line = Wait-Until { try { $all = @([System.IO.File]::ReadAllLines($Answer)); if ($all.Count -gt $before) { $all[$all.Count - 1] } } catch { $null } } 15 20
    if (-not $line -or $line -notmatch '^scroll (\d+) (\d+)$') { throw "the pages window did not answer 'scroll' ($line)" }
    return @([int64]$Matches[1], [int64]$Matches[2])
}
Send-Page 'A' | Out-Null
Send-Page 'tick-on' | Out-Null
Start-Sleep -Seconds 2
Debug-Shot 'page-a'

# ---------------------------------------------------------------- 4. one session per setting and kind of screen
function Write-Prefs($Set) {
    New-Item -ItemType Directory -Force -Path $HelperCfg | Out-Null
    Remove-Item -Force -Recurse (Join-Path $HelperCfg 'peers') -ErrorAction SilentlyContinue
    if ($Set.av1test) {
        cmd /c "`"$Exe`" --option av1-test $($Set.av1test) > nul 2>&1"
        Note "store PC option av1-test = '$(cmd /c "`"$Exe`" --option av1-test 2>nul")'"
    }
    if ($Set.none) {
        Remove-Item -Force (Join-Path $HelperCfg 'RustDesk_default.toml') -ErrorAction SilentlyContinue
        return
    }
    $lines = @('[options]', "image_quality = '$($Set.q)'", "codec-preference = '$($Set.codec)'")
    if ($Set.custom) { $lines += "custom_image_quality = '$($Set.custom)'" }
    [System.IO.File]::WriteAllText((Join-Path $HelperCfg 'RustDesk_default.toml'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Peer-Settings {
    $f = Get-ChildItem -Path (Join-Path $HelperCfg 'peers') -Filter '*.toml' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $f) { return 'no peer file' }
    $keep = Get-Content $f.FullName | Where-Object { $_ -match '^(image_quality|custom_image_quality|codec-preference|view_style)\s*=' -or $_ -match '^\s*(codec-preference|custom-fps)\s*=' }
    return "$($f.Name): $(($keep | ForEach-Object { $_.Trim() }) -join '; ')"
}

function Gray-Of([string] $Png) { return [Sharp]::Gray($Png, $Cx, $Cy, $Cw, $Ch) }

function Measure-One($Set, [string] $Mode) {
    $tag = "$($Set.name)-$Mode"
    Step "Session $tag"
    Write-Prefs $Set
    $df = Join-Path $HelperCfg 'RustDesk_default.toml'
    Note "helper defaults: $(if (Test-Path $df) { [System.IO.File]::ReadAllText($df).Replace("`n", ' | ') } else { 'none (the app as shipped)' })"
    if ($Set.mbit) {
        New-NetQosPolicy -Name 'BlurSession' -IPPortMatchCondition 21118 -ThrottleRateActionBitsPerSecond ([int64]$Set.mbit * 1000000) -PolicyStore ActiveStore | Out-Null
        Note "QoS policy on port 21118: $($Set.mbit) Mbit/s"
    }
    $scroll = $Mode -like 'scroll*'
    Send-Page $(if ($scroll) { 'T' } else { 'A' }) | Out-Null
    Send-Page 'tick-on' | Out-Null
    $t0 = Now-Ms
    Ask @{ op = 'connect'; exe = $Exe; peer = $Peer; seconds = 40 } 120 | Out-Null
    Ask @{ op = 'place'; x = 300; y = 60; w = ($s[2] + 14); h = ($s[3] + 41) } 20 | Out-Null
    $loc = $null
    for ($i = 0; $i -lt 60 -and -not $loc; $i++) {
        $r = Ask @{ op = 'locate'; r = $Wall[0]; g = $Wall[1]; b = $Wall[2]; tol = 26; rw = $s[2]; rh = $s[3] } 20
        if ($r -match 'picture at (\d+),(\d+) scale ([0-9.]+)' -and [double]$Matches[3] -eq 1.0) { $loc = @([int]$Matches[1], [int]$Matches[2]) }
        else { Start-Sleep -Milliseconds 500 }
    }
    if (-not $loc) { Ask @{ op = 'screen'; dir = $Debug; name = "helper-$tag-not-located" } 20 | Out-Null; throw "the store PC picture was not found at 1:1 in the session window ($tag)" }
    Note "connected in $((Now-Ms) - $t0) ms; picture at $($loc -join ',') (1:1)"
    $hidden = Wait-Until { $w = CM-Window; if (-not $w -or $w.Iconic) { 'hidden' } } 15 300
    Note "store PC panel out of the way: $([bool]$hidden)"
    Start-Sleep -Seconds 8
    $work = Join-Path $Dir "rec\$tag"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    [SL]::ShotScreen((Join-Path $work 'truth-a.png')) | Out-Null
    if ($Mode -like '*still') { Send-Page 'tick-off' | Out-Null; Start-Sleep -Milliseconds 1500 }
    $frames = Join-Path $work 'frames'
    Ask @{ op = 'rec-start'; dir = $frames; fps = $Fps; x = ($loc[0] + $Cx - $Pad); y = ($loc[1] + $Cy - $Pad); w = ($Cw + 2 * $Pad); h = ($Ch + 2 * $Pad) } 20 | Out-Null
    Start-Sleep -Milliseconds 1600
    if ($scroll) {
        $sc = Send-Scroll
        $changeAt = $sc[0]; $switch = $sc[1]
        Note "scrolled from $changeAt to $switch ($($switch - $changeAt) ms)"
    } else {
        $switch = Send-Page 'B'
        $changeAt = $switch
    }
    Start-Sleep -Milliseconds 500
    [SL]::ShotScreen((Join-Path $work 'truth-b.png')) | Out-Null
    $wait = $switch + $AfterMs - (Now-Ms)
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    Ask @{ op = 'rec-stop' } 300 | Out-Null
    $peerSet = Peer-Settings
    Ask @{ op = 'close-remote' } 30 | Out-Null
    Wait-Until { -not (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.CommandLine -like '*--cm*' }) } 20 500 | Out-Null
    if ($Set.mbit) { Remove-NetQosPolicy -Name 'BlurSession' -PolicyStore ActiveStore -Confirm:$false }
    Note "helper's saved session settings: $peerSet"

    # ---- the numbers
    $ta = Gray-Of (Join-Path $work 'truth-a.png')
    $tb = Gray-Of (Join-Path $work 'truth-b.png')
    $start = [int64](Get-Content (Join-Path $frames 'start.txt'))
    $rows = @(Import-Csv (Join-Path $frames 'frames.csv'))
    $pre = @($rows | Where-Object { ($start + [int64]$_.ms) -lt ($changeAt - 100) })
    if ($pre.Count -lt 3) { throw "too few frames before the switch ($tag)" }
    $al = [Sharp]::Align((Join-Path $frames ('frame-{0:D5}.png' -f [int]$pre[$pre.Count - 1].frame)), $ta, $Cw, $Ch, $Pad)
    Note "alignment: offset $($al[0] - $Pad),$($al[1] - $Pad); mean difference $($al[2] / 1000.0) on page A"
    $table = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $t = $start + [int64]$row.ms - $switch
        $png = Join-Path $frames ('frame-{0:D5}.png' -f [int]$row.frame)
        $g = [Sharp]::Gray($png, $al[0], $al[1], $Cw, $Ch)
        [void]$table.Add([pscustomobject]@{ frame = [int]$row.frame; t_ms = $t; diff_b = [Math]::Round([Sharp]::Mae($g, $tb), 3); diff_a = [Math]::Round([Sharp]::Mae($g, $ta), 3); bad_b = [Math]::Round([Sharp]::Bad($g, $tb), 2) })
    }
    $table | Export-Csv -NoTypeInformation -Path (Join-Path $Out "$tag-frames.csv")
    $c0 = $changeAt - $switch
    $before = @($table | Where-Object { $_.t_ms -ge ($c0 - 1400) -and $_.t_ms -le ($c0 - 100) })
    $base = ($before | Sort-Object diff_a | Select-Object -Index ([int]($before.Count / 2))).diff_a
    $after = @($table | Where-Object { $_.t_ms -ge 0 } | Sort-Object t_ms)
    $limit = $base * 1.25 + 0.25
    $firstB = $after | Where-Object { $_.diff_b -lt $_.diff_a } | Select-Object -First 1
    $sharp = $null
    for ($i = 0; $i -lt $after.Count; $i++) {
        $rest = @($after[$i..($after.Count - 1)] | Where-Object { $_.diff_b -gt $limit })
        if ($rest.Count -eq 0) { $sharp = $after[$i]; break }
    }
    $at = @{}
    foreach ($p in @(250, 500, 1000, 2000, 3000, 5000, 8000, 11500)) {
        $f = $after | Sort-Object { [Math]::Abs($_.t_ms - $p) } | Select-Object -First 1
        $at[$p] = $f
    }
    $res = [pscustomobject]@{
        setting = $Set.name; screen = $Mode
        page_a_settled = $base
        new_page_first_seen_ms = $(if ($firstB) { $firstB.t_ms } else { -1 })
        sharp_ms = $(if ($sharp) { $sharp.t_ms } else { -1 })
        diff_0_5s = $at[500].diff_b; diff_1s = $at[1000].diff_b; diff_2s = $at[2000].diff_b; diff_3s = $at[3000].diff_b
        diff_5s = $at[5000].diff_b; diff_8s = $at[8000].diff_b; diff_11_5s = $at[11500].diff_b
        bad_1s = $at[1000].bad_b; bad_11_5s = $at[11500].bad_b
        frames = $table.Count; peer = $peerSet
    }
    [void]$Results.Add($res)
    Note ("RESULT {0} {1}: settled page A {2:N2}; new page first seen {3} ms; sharp from {4} ms; difference at 0.5/1/2/3/5/8/11.5 s: {5}/{6}/{7}/{8}/{9}/{10}/{11}; bad pixels per mille at 1 s {12}, at 11.5 s {13}" -f `
        $Set.name, $Mode, $base, $res.new_page_first_seen_ms, $res.sharp_ms, $res.diff_0_5s, $res.diff_1s, $res.diff_2s, $res.diff_3s, $res.diff_5s, $res.diff_8s, $res.diff_11_5s, $res.bad_1s, $res.bad_11_5s)
    # Pictures to look at: the store PC's own piece of page B and the helper's view at moments.
    $pics = Join-Path $Out 'frames'
    New-Item -ItemType Directory -Force -Path $pics | Out-Null
    [Sharp]::SaveCrop((Join-Path $work 'truth-b.png'), $Cx, $Cy, $Cw, $Ch, (Join-Path $pics "$tag-truth-b.png"))
    foreach ($p in @(250, 500, 1000, 2000, 3000, 5000, 11500)) {
        $f = $at[$p]
        if (-not $f) { $f = $after | Sort-Object { [Math]::Abs($_.t_ms - $p) } | Select-Object -First 1 }
        [Sharp]::SaveCrop((Join-Path $frames ('frame-{0:D5}.png' -f $f.frame)), $al[0], $al[1], $Cw, $Ch, (Join-Path $pics ('{0}-at-{1}ms.png' -f $tag, $f.t_ms)))
    }
    Remove-Item -Recurse -Force $frames -ErrorAction SilentlyContinue
}

$fails = 0
foreach ($set in $Settings) {
    $setModes = if ($set.modes) { $set.modes } else { $Modes }
    foreach ($mode in $setModes) {
        if ($set.mbit -and $mode -eq 'still') { continue }
        try { Measure-One $set $mode }
        catch {
            $fails++
            Note "SESSION $($set.name)-$mode FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            Debug-Shot "fail-$($set.name)-$mode"
            try { Ask @{ op = 'close-remote' } 30 | Out-Null } catch { }
            try { Remove-NetQosPolicy -Name 'BlurSession' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            if ($fails -ge 4) { throw 'four sessions failed' }
        }
    }
}

# ---------------------------------------------------------------- 5. what the store PC chose
Step 'Store PC logs: the codec it used for each session (read after the sessions end)'
Start-Sleep -Seconds 3
$pattern = 'encoder:|usable:|av1 time|skip test av1|codec fallback|Connection opened|update:|new .*encoder|create .*encoder|image_quality|quality'
foreach ($root in @("$SvcRoot\log", 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\log', "$env:APPDATA\RustDesk\log")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.log' | ForEach-Object {
        Note "log file $($_.FullName) ($($_.Length) bytes)"
        $hits = Select-String -Path $_.FullName -Pattern $pattern | Select-Object -First 400
        foreach ($h in $hits) {
            $line = $h.Line -replace '[A-Za-z0-9+/]{40,}={0,2}', '(long value hidden)'
            if ($line.Length -gt 260) { $line = $line.Substring(0, 260) + ' ...' }
            Note "  $line"
        }
    }
}

$Results | Export-Csv -NoTypeInformation -Path (Join-Path $Out 'summary.csv')
$Results | Format-Table setting, screen, page_a_settled, new_page_first_seen_ms, sharp_ms, diff_0_5s, diff_1s, diff_2s, diff_5s, diff_11_5s, bad_1s, bad_11_5s -AutoSize | Out-String -Width 250 | Set-Content -Path (Join-Path $Out 'summary.txt') -Encoding ASCII
Get-Content (Join-Path $Out 'summary.txt') | ForEach-Object { Note $_ }

# ---------------------------------------------------------------- clean-up
try { Send-Page 'quit' 5 | Out-Null } catch { }
Get-Content -Path "$Dir\out\agent.log" -ErrorAction SilentlyContinue | Select-Object -Last 60 | ForEach-Object { Note "agent: $_" }
Ask @{ op = 'quit' } 20 | Out-Null
Copy-Item -Force "$Dir\out\agent.log" $Debug -ErrorAction SilentlyContinue
Remove-Item -Force -Recurse "$Dir\secret" -ErrorAction SilentlyContinue
cmdkey "/delete:TERMSRV/127.0.0.2" | Out-Null
cmd /c "logoff $sid 2>nul"
Start-Sleep -Seconds 5
Remove-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue
Note "throwaway user removed: $(-not (Get-LocalUser -Name $HelperUser -ErrorAction SilentlyContinue))"
Write-Host "RESULT blur measurement: $($Results.Count) sessions measured, $fails failed"
