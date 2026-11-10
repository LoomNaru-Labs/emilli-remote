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
            return "remote $($c.rx),$($c.ry) -> helper screen $($p[0]),$($p[1]); cursor now $($now -join ',')"
        }
        'click' {
            [SL]::Click([bool]$c.right)
            return "clicked $(if ($c.right) { 'right' } else { 'left' }) at $(([SL]::Cursor()) -join ',')"
        }
        'rec-start' {
            $clip = [SL]::Clip($state.Remote)
            [SL]::RecordStart($clip[0], $clip[1], $clip[2], $clip[3], [int]$c.fps, $c.dir)
            return "recording the session window $($clip -join ',') at $($c.fps) fps"
        }
        'rec-stop' { return [SL]::RecordStop() }
        'sleep' { Start-Sleep -Milliseconds ([int]$c.ms); return 'slept' }
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
    Start-Sleep -Milliseconds 150
}
Log 'agent end'
