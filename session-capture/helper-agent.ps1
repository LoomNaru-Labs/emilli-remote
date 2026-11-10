# The helper's side of the connected-session screenshots. It runs inside the second Windows
# session on the runner (a local "Helper" user signed in through a Remote Desktop loopback),
# started there by a scheduled task from run-session.ps1, and never on a PC that matters.
#
# It opens Emilli Remote's connection to the store PC (the runner's console session) the way
# a user does, with rustdesk.exe --connect, and then carries out the commands that
# run-session.ps1 drops into <Dir>\cmd as JSON files: place the session window, find the
# remote picture in it, save screenshots, and move and click the real mouse over the remote
# picture (SendInput in this session, so the clicks travel through the remote session).
# Each answer goes to <Dir>\done\<same name>. Plain ASCII on purpose (Windows PowerShell 5.1).
param([string] $Dir = 'C:\sc')
$ErrorActionPreference = 'Stop'
$log = Join-Path $Dir 'out\agent.log'

function Log([string] $m) {
    Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m)
}

try {
    Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $Dir 'bin\SessionLib.cs')
} catch {
    Log "Add-Type failed: $($_.Exception.Message)"
    throw
}

$state = @{ Remote = [IntPtr]::Zero; Left = 0; Top = 0; Scale = 1.0; W = 1920; H = 1080; CropLeft = 0; CropTop = 0 }

function RustDeskWindows {
    $mine = [SL]::MySession()
    [SL]::Windows() | Where-Object { $_.Proc -like 'rustdesk*' -and [SL]::SessionOf($_.Pid) -eq $mine -and $_.Width -gt 200 }
}

function Map([double] $rx, [double] $ry) {
    return @([int][Math]::Round($state.Left + $rx * $state.Scale), [int][Math]::Round($state.Top + $ry * $state.Scale))
}

function Run($c) {
    switch ($c.op) {
        'hello' {
            $s = [SL]::Screen()
            return "session $([SL]::MySession()) user $env:USERNAME screen $($s[2])x$($s[3])"
        }
        'dpi' { return "screen DPI $([SL]::MonitorDpi())" }
        # Windows' own pointer shapes at a larger size in the helper's session.
        'pointer' { return [SL]::SetPointerPixels([int]$c.px) }
        # The pointer shown now (over the session window: the store PC's pointer as the app draws it).
        'cursor' { return "pointer now $([SL]::PointerPixels())" }
        # A plain pointer move on the helper's screen (no click).
        'glide' { [SL]::Glide([int]$c.x, [int]$c.y, [int]$c.ms); return "pointer at $($c.x),$($c.y)" }
        # Whether the recording draws the helper's own pointer (see SL.WithCursor).
        'rec-cursor' { [SL]::WithCursor = [bool]$c.on; return "own pointer in the recording: $([SL]::WithCursor)" }
        'windows' {
            return (([SL]::Windows() | ForEach-Object { $_.ToString() }) -join "`n")
        }
        'connect' {
            $pw = (Get-Content -Path (Join-Path $Dir 'secret\pw.txt') -TotalCount 1).Trim()
            $before = @(RustDeskWindows | ForEach-Object { $_.Hwnd })
            Start-Process -FilePath $c.exe -ArgumentList @('--connect', $c.peer, '--password', $pw)
            $pw = $null
            $seen = @{}
            for ($i = 0; $i -lt [int]$c.seconds; $i++) {
                Start-Sleep -Seconds 1
                foreach ($w in RustDeskWindows) {
                    $k = "$($w.Hwnd)|$($w.Title)"
                    if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; Log "window: $w" }
                }
                $cands = @(RustDeskWindows | Where-Object { $before -notcontains $_.Hwnd })
                $remote = $cands | Where-Object { $_.Title -like "*$($c.peer)*" } | Select-Object -First 1
                if ($remote -and $i -ge 3) {
                    $state.Remote = $remote.Hwnd
                    return "remote window $remote"
                }
            }
            $all = (RustDeskWindows | ForEach-Object { $_.ToString() }) -join "`n"
            $cands = @(RustDeskWindows | Where-Object { $before -notcontains $_.Hwnd } | Sort-Object { $_.Width * $_.Height } -Descending)
            if ($cands.Count -gt 0) {
                $state.Remote = $cands[0].Hwnd
                return "no window titled with the peer; took the largest new one $($cands[0]); all: $all"
            }
            throw "no session window after $($c.seconds) s; RustDesk windows: $all"
        }
        'tidy' {
            # Minimizes this session's other RustDesk windows (the main window) behind the session.
            $n = 0
            foreach ($w in RustDeskWindows) { if ($w.Hwnd -ne $state.Remote) { [SL]::Show($w.Hwnd, 6); $n++ } }
            return "minimized $n"
        }
        'place' {
            if ($c.max) { [SL]::Show($state.Remote, 3) } else { [SL]::Place($state.Remote, [int]$c.x, [int]$c.y, [int]$c.w, [int]$c.h) }
            Start-Sleep -Milliseconds 800
            [SL]::Front($state.Remote)
            Start-Sleep -Milliseconds 500
            return "placed: $([SL]::Info($state.Remote))"
        }
        'front' {
            [SL]::Front($state.Remote)
            return "front: $([SL]::Info($state.Remote))"
        }
        'locate' {
            # The remote desktop has a plain wallpaper of a known colour along its top and left
            # edges, so its picture inside the session window is the box of that colour.
            $clip = [SL]::Clip($state.Remote)
            $box = [SL]::ColorBox($clip[0], $clip[1], $clip[2], $clip[3], [int]$c.r, [int]$c.g, [int]$c.b, [int]$c.tol)
            if ($box[4] -eq 0) {
                # First guess only; run-session.ps1 measures the real place with pointer moves.
                $state.Left = $clip[0]; $state.Top = $clip[1] + 32; $state.Scale = 1.0; $state.W = [int]$c.rw; $state.H = [int]$c.rh
                $state.CropLeft = $state.Left; $state.CropTop = $state.Top
                return "wallpaper colour not found in the session window $($clip -join ','); first guess $($state.Left),$($state.Top)"
            }
            $w = $box[2] - $box[0] + 1
            $scale = $w / [double]$c.rw
            if ([Math]::Abs($scale - 1.0) -lt 0.004) { $scale = 1.0 }
            $state.Left = $box[0]; $state.Top = $box[1]; $state.Scale = $scale; $state.W = [int]$c.rw; $state.H = [int]$c.rh
            $state.CropLeft = $box[0]; $state.CropTop = $box[1]
            $nb = [SL]::NonBlack($box[0], $box[1], [int]($c.rw * $scale), [int]($c.rh * $scale))
            return "window $($clip -join ','); wallpaper box $($box[0]),$($box[1]) to $($box[2]),$($box[3]) ($($box[4]) px); picture at $($box[0]),$($box[1]) scale $scale; not black $nb/1000"
        }
        'calib' {
            # Pointer mapping only; the crop keeps the picture edges found by 'locate'.
            $state.Left = [double]$c.left; $state.Top = [double]$c.top; $state.Scale = [double]$c.scale
            return "pointer mapping: picture at $($state.Left),$($state.Top) scale $($state.Scale); crop at $($state.CropLeft),$($state.CropTop)"
        }
        'shot' {
            $w = [int][Math]::Round($state.W * $state.Scale); $h = [int][Math]::Round($state.H * $state.Scale)
            $x0 = [int]$state.CropLeft; $y0 = [int]$state.CropTop
            $a = Join-Path $c.dir "$($c.name).png"
            $b = Join-Path $c.dir "$($c.name)-remote-only.png"
            $r = [SL]::ShotWindowAndRegion($state.Remote, $a, $x0, $y0, $w, $h, $b)
            $nb = [SL]::NonBlack($x0, $y0, $w, $h)
            if ($c.screen) { [SL]::ShotScreen((Join-Path $c.dir "$($c.name)-helper-screen.png")) | Out-Null }
            return "$($c.name): $r; remote picture not black $nb/1000"
        }
        'screen' {
            return [SL]::ShotScreen((Join-Path $c.dir "$($c.name).png"))
        }
        'move' {
            $p = Map ([double]$c.rx) ([double]$c.ry)
            [SL]::Glide($p[0], $p[1], [int]$c.ms)
            $now = [SL]::Cursor()
            # Round 3: the click in the same command (one round trip less per action).
            $did = ''
            if ($c.click) {
                Start-Sleep -Milliseconds 120
                switch ([string]$c.click) {
                    'left' { [SL]::Click($false) }
                    'right' { [SL]::Click($true) }
                    'double' { [SL]::DoubleClick() }
                }
                $did = "; $($c.click) click"
            }
            return "remote $($c.rx),$($c.ry) -> helper screen $($p[0]),$($p[1]); cursor now $($now -join ',')$did"
        }
        'click' {
            if ($c.pause) { Start-Sleep -Milliseconds ([int]$c.pause) }
            [SL]::Click([bool]$c.right)
            return "clicked $(if ($c.right) { 'right' } else { 'left' }) at $(([SL]::Cursor()) -join ',')"
        }
        'hide-icons' { return "desktop icons hidden: $([SL]::HideDesktopIcons())" }
        'warm' {
            # A first connection without the password, only so that the app remembers where its
            # session window goes; it is closed again at the password prompt.
            $before = @(RustDeskWindows | ForEach-Object { $_.Hwnd })
            $proc = Start-Process -FilePath $c.exe -ArgumentList @('--connect', $c.peer) -PassThru
            $w = $null
            for ($i = 0; $i -lt 40 -and -not $w; $i++) {
                Start-Sleep -Milliseconds 500
                $w = RustDeskWindows | Where-Object { $_.Title -like "*$($c.peer)*" -and $before -notcontains $_.Hwnd } | Select-Object -First 1
            }
            if (-not $w) { throw 'no session window for the warm-up' }
            Start-Sleep -Seconds 2
            [SL]::Place($w.Hwnd, [int]$c.x, [int]$c.y, [int]$c.w, [int]$c.h)
            Start-Sleep -Seconds 2
            $placed = [SL]::Info($w.Hwnd)
            [SL]::PostClose($w.Hwnd)
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if (-not (RustDeskWindows | Where-Object { $_.Hwnd -eq $w.Hwnd })) { break }
            }
            $left = @(RustDeskWindows | Where-Object { $_.Hwnd -eq $w.Hwnd }).Count
            if ($left -gt 0) { Stop-Process -Id $w.Pid -Force; Start-Sleep -Seconds 2; return "warm-up window placed $placed; it did not close, its process was stopped" }
            Start-Sleep -Seconds 1
            return "warm-up window placed $placed and closed"
        }
        'open-main' {
            $before = @(RustDeskWindows | ForEach-Object { $_.Hwnd })
            Start-Process -FilePath $c.exe | Out-Null
            $m = $null
            for ($i = 0; $i -lt 60 -and -not $m; $i++) {
                Start-Sleep -Milliseconds 500
                $m = RustDeskWindows | Where-Object { $_.Cls -eq 'FLUTTER_RUNNER_WIN32_WINDOW' -and $before -notcontains $_.Hwnd } | Select-Object -First 1
            }
            if (-not $m) { throw "no main window; RustDesk windows: $((RustDeskWindows | ForEach-Object { $_.ToString() }) -join ' / ')" }
            Start-Sleep -Seconds 3
            $m = [SL]::Info($m.Hwnd)
            $state.Main = $m.Hwnd
            $nx = [int]$c.x + [int](([int]$c.w - $m.Width) / 2); $ny = [int]$c.y + [int](([int]$c.h - $m.Height) / 2)
            [SL]::MoveFrameTo($m.Hwnd, $nx, $ny)
            Start-Sleep -Milliseconds 800
            [SL]::Front($m.Hwnd)
            Start-Sleep -Milliseconds 800
            return "main window $([SL]::Info($m.Hwnd))"
        }
        'find-connect' {
            # The Connect button is the app's filled accent-blue button under the address field
            # (flutter/lib/desktop/pages/connection_page.dart: a 320-pixel field, then Connect and a
            # 28-pixel menu button, right-aligned).
            $clip = [SL]::Clip($state.Main)
            $x0 = $clip[0] + [int]($clip[2] * 0.3); $h0 = [int]($clip[3] * 0.6)
            $box = [SL]::ColorBox($x0, $clip[1], $clip[0] + $clip[2] - $x0, $h0, 0, 113, 255, 45)
            if ($box[4] -eq 0) { throw "no Connect button colour in the main window $($clip -join ',')" }
            $state.ConnectX = [int](($box[0] + $box[2]) / 2); $state.ConnectY = [int](($box[1] + $box[3]) / 2)
            $state.FieldX = $box[2] + 36 - 160; $state.FieldY = $box[1] - 36
            return "Connect button $($box[0]),$($box[1]) to $($box[2]),$($box[3]) ($($box[4]) px); field point $($state.FieldX),$($state.FieldY)"
        }
        'click-at' {
            $x = if ($c.what -eq 'field') { $state.FieldX } elseif ($c.what -eq 'connect') { $state.ConnectX } else { [int]$c.x }
            $y = if ($c.what -eq 'field') { $state.FieldY } elseif ($c.what -eq 'connect') { $state.ConnectY } else { [int]$c.y }
            [SL]::Glide($x, $y, [int]$c.ms)
            Start-Sleep -Milliseconds 200
            [SL]::Click($false)
            return "clicked $($c.what) at $x,$y"
        }
        'type' { [SL]::TypeText([string]$c.text, [int]$c.ms); return "typed $($c.text.Length) characters" }
        'type-secret' {
            $fg = [SL]::ForegroundTitle()
            if (-not [SL]::IsForeground($state.Remote)) { [SL]::FrontNoAlt($state.Remote); Start-Sleep -Milliseconds 400 }
            if ($c.clickx) { [SL]::Glide([int]$c.clickx, [int]$c.clicky, 400); Start-Sleep -Milliseconds 150; [SL]::Click($false); Start-Sleep -Milliseconds 300 }
            Log "type-secret: foreground before '$fg', now '$([SL]::ForegroundTitle())'"
            $pw = (Get-Content -Path (Join-Path $Dir 'secret\pw.txt') -TotalCount 1).Trim()
            [SL]::TypeText($pw, [int]$c.ms)
            $n = $pw.Length; $pw = $null
            Start-Sleep -Milliseconds 250
            [SL]::PressKey(0x0D)
            return "typed the password ($n characters) and Enter"
        }
        'wait-remote' {
            $w = $null
            for ($i = 0; $i -lt [int]$c.seconds * 10 -and -not $w; $i++) {
                Start-Sleep -Milliseconds 100
                $w = RustDeskWindows | Where-Object { $_.Title -like "*$($c.peer)*" } | Select-Object -First 1
            }
            if (-not $w) { throw 'no session window' }
            $state.Remote = $w.Hwnd
            return "session window $w"
        }
        'park' {
            $i = [SL]::Info($state.Remote)
            $note = 'already in place'
            if ($i.Left -ne [int]$c.vx -or $i.Top -ne [int]$c.vy -or $i.Width -ne [int]$c.vw) {
                [SL]::Place($state.Remote, [int]$c.x, [int]$c.y, [int]$c.w, [int]$c.h); $note = "moved from $($i.Left),$($i.Top) $($i.Width)x$($i.Height)"
            }
            return "$note; $([SL]::Info($state.Remote)); foreground '$([SL]::ForegroundTitle())'"
        }
        'close-remote' {
            [SL]::PostClose($state.Remote)
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if (-not (RustDeskWindows | Where-Object { $_.Hwnd -eq $state.Remote })) { return 'session window closed' }
            }
            return 'session window still open'
        }
        'lang' {
            # The app's own language option for this user (RustDesk_local.toml), Windows unchanged.
            $f = Join-Path $env:APPDATA 'RustDesk\config\RustDesk_local.toml'
            New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
            $text = if (Test-Path $f) { [System.IO.File]::ReadAllText($f) } else { '' }
            if ($text -match "(?m)^lang\s*=") { $text = $text -replace "(?m)^lang\s*=.*$", "lang = '$($c.lang)'" }
            elseif ($text -match "(?m)^\[options\]\s*$") { $text = $text -replace "(?m)^\[options\]\s*$", "[options]`nlang = '$($c.lang)'" }
            else { $text = $text.TrimEnd() + "`n`n[options]`nlang = '$($c.lang)'`n" }
            [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($false)))
            return "lang '$($c.lang)' in $f"
        }
        'rec-start' {
            $clip = if ($c.w) { @([int]$c.x, [int]$c.y, [int]$c.w, [int]$c.h) } else { [SL]::Clip($state.Remote) }
            [SL]::RecordStart($clip[0], $clip[1], $clip[2], $clip[3], [int]$c.fps, $c.dir)
            return "recording the session window $($clip -join ',') at $($c.fps) fps"
        }
        'rec-stop' { return [SL]::RecordStop() }
        'sleep' { Start-Sleep -Milliseconds ([int]$c.ms); return 'slept' }
        # ---- Round 3 (brief REMOTE-SESSION-CAPTURE-3) ----
        # A double-click where the pointer is (through the session when it is over the picture).
        'dclick' { [SL]::DoubleClick(); return "double-clicked at $(([SL]::Cursor()) -join ',')" }
        # The session window's toolbar starts collapsed to a small handle at the top centre of
        # the picture (fullscreen and "Show Toolbar" icons, flutter/lib/desktop/widgets/
        # remote_toolbar.dart, _DraggableShowHide). The helper clicks "Show Toolbar" (the handle's
        # rightmost icon); the toolbar's blue buttons appear above it: Control, Display, Keyboard,
        # Chat, Record, then the red Close (_buildToolbar; Pin is grey while not pinned).
        'toolbar-show' {
            $clip = [SL]::Clip($state.Remote)
            $cx = $clip[0] + [int]($clip[2] / 2)
            $hb = @([SL]::Clusters($cx - 130, $clip[1] + 30, 260, 28, 'blue', 2))
            Log "toolbar handle icons: $(($hb | ForEach-Object { $_ -join ',' }) -join ' / ')"
            if ($hb.Count -eq 0) { throw 'no toolbar handle at the top of the session window' }
            $t = $hb[$hb.Count - 1]
            $tx = [int](($t[0] + $t[2]) / 2); $ty = [int](($t[1] + $t[3]) / 2)
            [SL]::Glide($tx, $ty, [int]$c.ms); Start-Sleep -Milliseconds 150; [SL]::Click($false)
            $btn = @(); $red = @()
            for ($i = 0; $i -lt 20 -and ($btn.Count -lt 4 -or $red.Count -lt 1); $i++) {
                Start-Sleep -Milliseconds 100
                $btn = @([SL]::Clusters($cx - 420, $clip[1] + 30, 840, 50, 'blue', 10) | Where-Object { ($_[2] - $_[0]) -ge 18 -and ($_[3] - $_[1]) -ge 20 })
                $red = @([SL]::Clusters($cx - 420, $clip[1] + 30, 840, 50, 'red', 10) | Where-Object { ($_[2] - $_[0]) -ge 18 })
            }
            $desc = "show-toolbar at $tx,$ty; blue buttons $(($btn | ForEach-Object { '[' + ($_[0..3] -join ',') + ']' }) -join ' '); red $(($red | ForEach-Object { '[' + ($_[0..3] -join ',') + ']' }) -join ' ')"
            Log $desc
            if ($red.Count -lt 1 -or $btn.Count -lt 2) { throw "the toolbar did not open: $desc" }
            # Chat: the blue button before the last blue one (Record) left of the red Close.
            $left = @($btn | Where-Object { $_[2] -lt $red[0][0] } | Sort-Object { $_[0] })
            if ($left.Count -lt 2) { throw "too few buttons left of Close: $desc" }
            $ch = $left[$left.Count - 2]
            $state.ChatL = $ch[0]; $state.ChatT = $ch[1]; $state.ChatR = $ch[2]; $state.ChatB = $ch[3]
            return "$desc; chat button $($ch[0..3] -join ',')"
        }
        # Chat, then "Text chat", the first of the two rows of its menu ("Text chat", "Voice call");
        # the rows are read from the screen (attempt 2: a row-height guess hit "Voice call").
        # The chat window (250x350, flutter/lib/models/chat_model.dart) opens at the Chat button.
        'chat-open' {
            $bx = [int](($state.ChatL + $state.ChatR) / 2); $by = [int](($state.ChatT + $state.ChatB) / 2)
            [SL]::Glide($bx, $by, [int]$c.ms); Start-Sleep -Milliseconds 100
            [SL]::Keep($state.ChatL - 30, $state.ChatB + 2, 320, 160)
            [SL]::Click($false)
            $menu = $null
            for ($i = 0; $i -lt 25 -and -not $menu; $i++) {
                Start-Sleep -Milliseconds 60
                $b = [SL]::ChangedBox(30)
                if ($b[4] -gt 300 -and ($b[2] - $b[0]) -ge 60 -and ($b[3] - $b[1]) -ge 40) { $menu = $b }
            }
            if (-not $menu) { throw "the Chat menu did not open (changed $(([SL]::ChangedBox(30)) -join ','))" }
            Start-Sleep -Milliseconds 250
            $menu = [SL]::ChangedBox(30)
            $rows = @([SL]::Bands($menu[0] + 8, $menu[1] + 2, [Math]::Max(20, [Math]::Min(90, $menu[2] - $menu[0] - 12)), [Math]::Max(10, $menu[3] - $menu[1] - 2), 'dark', 2) | Where-Object { ($_[1] - $_[0]) -ge 5 -and ($_[1] - $_[0]) -le 30 })
            Log "chat menu box $($menu -join ','); text rows $(($rows | ForEach-Object { '[' + ($_ -join ',') + ']' }) -join ' ')"
            if ($rows.Count -lt 2) { [SL]::PressKey(0x1B); throw "the Chat menu's two rows were not found (box $($menu -join ','), rows $($rows.Count))" }
            $state.OvL = $state.ChatL - 40; $state.OvT = $state.ChatB + 40
            $mx = $menu[0] + 46; $my = [int](($rows[0][0] + $rows[0][1]) / 2)
            [SL]::Glide($mx, $my, 380); Start-Sleep -Milliseconds 120
            [SL]::Keep($state.OvL, $state.OvT, 330, 330)
            [SL]::Click($false)
            $box = $null
            # Opened = changes spread over a box the chat window's size (the menu closing alone
            # changes a small strip at the top of this area); white may lie on white inside.
            for ($i = 0; $i -lt 25; $i++) {
                Start-Sleep -Milliseconds 80
                $b = [SL]::ChangedBox(30)
                if ($b[4] -gt 0 -and ($b[2] - $b[0]) -ge 180 -and ($b[3] - $b[1]) -ge 200) { Start-Sleep -Milliseconds 250; $box = [SL]::ChangedBox(30); break }
            }
            if (-not $box) { $b = [SL]::ChangedBox(30); throw "the chat window did not open (changed $($b -join ','))" }
            $state.ChatBox = $box
            return "Text chat clicked at $mx,$my; chat window area changed: $($box -join ',')"
        }
        # Types the message into the chat window's input (it has the focus when it opens).
        'chat-type' {
            $text = if ($c.cp) { -join ($c.cp | ForEach-Object { [char][int]$_ }) } else { [string]$c.text }
            [SL]::TypeText($text, [int]$c.ms)
            return "typed $($text.Length) characters"
        }
        # The send button (MyTheme.accent blue, the right end of the input row, shown once there
        # is text; Enter only adds a line there, dash_chat_2 sendOnEnter is false).
        'chat-send' {
            $b = $state.ChatBox
            $x0 = $state.OvL; $w0 = 330
            $y0 = [Math]::Max($state.OvT, $b[3] - 90); $h0 = [Math]::Max(20, [Math]::Min(100, $b[3] - $y0 + 8))
            $cl = @([SL]::Clusters($x0, $y0, $w0, $h0, 'blue', 4) | Where-Object { ($_[2] - $_[0]) -ge 8 -and ($_[2] - $_[0]) -le 40 })
            Log "send button candidates in $x0,$y0 ${w0}x${h0}: $(($cl | ForEach-Object { '[' + ($_[0..3] -join ',') + ']' }) -join ' ')"
            if ($cl.Count -eq 0) { throw 'no send button found' }
            $s = $cl | Sort-Object { $_[2] } | Select-Object -Last 1
            $sx = [int](($s[0] + $s[2]) / 2); $sy = [int](($s[1] + $s[3]) / 2)
            [SL]::Glide($sx, $sy, [int]$c.ms); Start-Sleep -Milliseconds 150; [SL]::Click($false)
            return "send clicked at $sx,$sy"
        }
        'quit' { return 'bye' }
        default { throw "unknown op $($c.op)" }
    }
}

Log "agent start: session $([SL]::MySession()) user $env:USERNAME"
$cmdDir = Join-Path $Dir 'cmd'
$doneDir = Join-Path $Dir 'done'
$deadline = (Get-Date).AddMinutes(40)
while ((Get-Date) -lt $deadline) {
    $files = Get-ChildItem -Path $cmdDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name
    $quit = $false
    foreach ($f in $files) {
        $donePath = Join-Path $doneDir $f.Name
        if (Test-Path $donePath) { continue }
        $c = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json
        $ans = @{ ok = $true; result = '' }
        try { $ans.result = [string](Run $c) } catch { $ans.ok = $false; $ans.result = $_.Exception.Message }
        Log "$($f.Name) $($c.op): $(if ($ans.ok) { 'ok' } else { 'FAILED' }) $($ans.result)"
        $tmp = "$donePath.tmp"
        ($ans | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Force $tmp $donePath
        if ($c.op -eq 'quit') { $quit = $true }
    }
    if ($quit) { break }
    Start-Sleep -Milliseconds 90
}
Log 'agent end'
