# REMOTE-EASY-3E: every place a person could still see the name of the software Emilli Remote is
# built on, once Emilli Remote Setup has installed the program. For a fresh GitHub "windows-latest"
# runner only (it installs software and changes the display); rd.emillis.net is blocked in the
# runner's hosts file first, so nothing reaches our server.
#
#   1. Emilli Remote Setup runs silently, as a person's double-click would install it.
#   2. Pictures of every page of the program, in English and in Korean: the first screen, every
#      Settings page scrolled from top to bottom, About and what its links and buttons open. The
#      text of every picture is read by OCR (tesseract, English and Korean).
#   3. The installed state: registry, file and folder names on C:, the text files of ours, the
#      file properties of every program file, services, drivers, scheduled tasks, firewall rules,
#      printers and print drivers, shortcuts, start-up entries, installed apps, URL schemes, the
#      event log, processes and window titles.
#
# found.txt gets one line per place:
#   FOUND   <area> | <where> | <text>     the old name where a person can see it
#   ALLOWED <area> | <where> | <text>     the open-source notice (the one place allowed to name it)
#   HIDDEN  <area> | <where> | <text>     the old name only inside files or keys a person never reads
#   INFO    <area> | <where> | <text>     what a person sees there instead (context for the report)
# -Mode inventory never fails. -Mode check ends with an error when there is any FOUND line, or when
# the pages could not be read (no OCR, no picture of a page).
# Plain ASCII on purpose (Windows PowerShell 5.1); Korean words come from character codes.
param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Lib,
    [Parameter(Mandatory)] [string] $Out,
    [ValidateSet('inventory', 'check')] [string] $Mode = 'inventory',
    # An earlier Emilli Remote Setup installed first: the state of a PC that upgrades.
    [string] $Before = '',
    [string] $Tesseract = 'C:\Program Files\Tesseract-OCR\tesseract.exe'
)
$ErrorActionPreference = 'Stop'
$Shots = Join-Path $Out 'shots'
$Ocr = Join-Path $Out 'ocr'
New-Item -ItemType Directory -Force -Path $Out, $Shots, $Ocr | Out-Null
Add-Type -ReferencedAssemblies System.Drawing -Path $Lib
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class NcWheel {
  [DllImport("user32.dll")] static extern void mouse_event(uint f, int x, int y, int d, UIntPtr e);
  public static void Down(int notches) { for (int i = 0; i < notches; i++) { mouse_event(0x0800, 0, 0, -120, UIntPtr.Zero); System.Threading.Thread.Sleep(40); } }
  public static void Up(int notches) { for (int i = 0; i < notches; i++) { mouse_event(0x0800, 0, 0, 120, UIntPtr.Zero); System.Threading.Thread.Sleep(40); } }
}
'@
[SL]::WithCursor = $false

$Bad = '(?i)rust\s*desk|purslane'
# OCR may read s as 5, e as c or 3, l as 1.
$BadOcr = '(?i)ru[s5]t\s*d[e3c][s5]k|pur[s5][l1I]ane'
$InstallDir = 'C:\Program Files\EmilliRemote'
$Exe = Join-Path $InstallDir 'EmilliRemote.exe'
$ProfileDirs = @($env:APPDATA, $env:LOCALAPPDATA,
    'C:\Windows\ServiceProfiles\LocalService\AppData', 'C:\Windows\ServiceProfiles\NetworkService\AppData',
    'C:\Windows\System32\config\systemprofile\AppData', 'C:\ProgramData')

$Lines = New-Object System.Collections.ArrayList
$Seen = @{}
function Add-Line([string] $kind, [string] $area, [string] $where, [string] $text) {
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    $line = "$kind $area | $where | $text"
    if ($Seen.ContainsKey($line)) { return }
    $Seen[$line] = 1
    [void]$Lines.Add($line)
    Write-Host $line
}
function Found([string] $area, [string] $where, [string] $text) { Add-Line 'FOUND' $area $where $text }
function Info([string] $area, [string] $where, [string] $text) { Add-Line 'INFO' $area $where $text }
function Step([string] $m) { Write-Host ("STEP {0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Save-Found {
    $Lines | Sort-Object | Set-Content -Path (Join-Path $Out 'found.txt') -Encoding UTF8
}
function K([int[]] $c) { return -join ($c | ForEach-Object { [char]$_ }) }
$script:Problems = New-Object System.Collections.ArrayList
function Problem([string] $m) { [void]$script:Problems.Add($m); Write-Host "PROBLEM $m" }

# ---------------------------------------------------------------- OCR
$script:OcrOk = (Test-Path $Tesseract)
if ($script:OcrOk) {
    $v = (& $Tesseract --version 2>&1 | Select-Object -First 1)
    $langs = (& $Tesseract --list-langs 2>&1 | Out-String)
    Write-Host "OCR: $v; languages: $(($langs -split "`r?`n" | Where-Object { $_ -match '^[a-z_]+$' }) -join ' ')"
    if ($langs -notmatch '(?m)^kor\s*$') { Problem 'OCR has no Korean language data' }
} else { Problem "OCR program not found at $Tesseract" }

# The picture twice as large (tesseract reads 12 px interface text far better that way).
function Scale-Twice([string] $src, [string] $dst) {
    $img = [System.Drawing.Image]::FromFile($src)
    try {
        $b = New-Object System.Drawing.Bitmap ($img.Width * 2), ($img.Height * 2)
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $img.Width * 2, $img.Height * 2)
        $g.Dispose()
        $b.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    } finally { $img.Dispose() }
}
# Reads a picture; returns the words with their place on the screen (picture offset added).
function Read-Picture([string] $png, [int] $offX = 0, [int] $offY = 0) {
    $name = [IO.Path]::GetFileNameWithoutExtension($png)
    $base = Join-Path $Ocr $name
    if (-not $script:OcrOk) { return @() }
    $big = "$base.x2.png"
    Scale-Twice $png $big
    $ErrorActionPreference = 'Continue'
    & $Tesseract $big $base -l 'eng+kor' --psm 3 txt tsv 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    Remove-Item -Force $big -ErrorAction SilentlyContinue
    $words = @()
    if (Test-Path "$base.tsv") {
        $words = @(Get-Content "$base.tsv" -Encoding UTF8 | Select-Object -Skip 1 | ForEach-Object {
            $c = $_ -split "`t"
            if ($c.Count -ge 12 -and $c[0] -eq '5' -and $c[11].Trim()) {
                [pscustomobject]@{ X = $offX + [int]([int]$c[6] / 2); Y = $offY + [int]([int]$c[7] / 2); W = [int]([int]$c[8] / 2); H = [int]([int]$c[9] / 2); Text = $c[11].Trim() }
            }
        })
    }
    $text = if (Test-Path "$base.txt") { Get-Content -Raw "$base.txt" -Encoding UTF8 } else { '' }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match $BadOcr) {
            if ($name -match 'notice') { Add-Line 'ALLOWED' 'page text (OCR)' "$name.png" $l } else { Found 'page text (OCR)' "$name.png" $l }
        }
    }
    return $words
}

# ---------------------------------------------------------------- pictures
$script:ShotCount = 0
function Shot-Window([IntPtr] $h, [string] $name) {
    $path = Join-Path $Shots "$name.png"
    $r = [SL]::ShotWindow($h, $path)
    $script:ShotCount++
    Write-Host "  picture $name ($r)"
    $c = [SL]::Clip($h)
    return @{ Path = $path; Words = @(Read-Picture $path $c[0] $c[1]) }
}
function Shot-Screen([string] $name) {
    $path = Join-Path $Shots "$name.png"
    [void][SL]::ShotScreen($path)
    $script:ShotCount++
    Write-Host "  picture $name (screen)"
    return @{ Path = $path; Words = @(Read-Picture $path 0 0) }
}
function Same-Picture([string] $a, [string] $b) {
    if (-not ((Test-Path $a) -and (Test-Path $b))) { return $false }
    return (Get-FileHash -Algorithm MD5 $a).Hash -eq (Get-FileHash -Algorithm MD5 $b).Hash
}
function Click-At([int] $x, [int] $y) {
    [SL]::Glide($x, $y, 200); Start-Sleep -Milliseconds 120; [SL]::Click($false)
}

function Our-Windows {
    $pids = @(Get-Process -Name EmilliRemote -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    @([SL]::Windows() | Where-Object { $pids -contains [int]$_.Pid -and $_.Width -gt 50 -and $_.Height -gt 50 })
}
function Main-Window { Our-Windows | Where-Object { $_.Title -eq 'Emilli Remote' } | Select-Object -First 1 }
function Wait-For([scriptblock] $Condition, [int] $Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) { $v = & $Condition; if ($v) { return $v }; Start-Sleep -Milliseconds 700 }
    return (& $Condition)
}
function Close-App {
    $me = (Get-Process -Id $PID).SessionId
    Get-Process -Name EmilliRemote -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $me } | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force } catch { }
    }
    Start-Sleep -Seconds 3
}
function Set-Language([string] $lang) {
    $local = Join-Path $env:APPDATA 'EmilliRemote\config\EmilliRemote_local.toml'
    New-Item -ItemType Directory -Force -Path (Split-Path $local) | Out-Null
    $text = if (Test-Path $local) { [IO.File]::ReadAllText($local) } else { '' }
    if ($text -match "(?m)^lang\s*=") { $text = $text -replace "(?m)^lang\s*=.*$", "lang = '$lang'" }
    elseif ($text -match '(?m)^\[options\]') { $text = $text -replace '(?m)^\[options\]\s*$', "[options]`nlang = '$lang'" }
    else { $text = $text + "`n[options]`nlang = '$lang'`n" }
    [IO.File]::WriteAllText($local, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Every window of ours that is open now, as a picture (dialogs a click opened).
function Shot-Dialogs([string] $prefix, [IntPtr] $main) {
    $i = 0
    foreach ($win in @(Our-Windows | Where-Object { $_.Hwnd -ne $main })) {
        $i++
        Info 'window title' "$prefix dialog $i" $win.Title
        if ($win.Title -match $Bad) { Found 'window title' "$prefix dialog $i" $win.Title }
        [void](Shot-Window $win.Hwnd "$prefix-window-$i")
    }
}

# Scrolls the page under the pointer to its end, a picture each time.
function Shot-Scrolled([IntPtr] $h, [string] $name, [int] $px, [int] $py) {
    $last = Shot-Window $h "$name-1"
    $all = @($last.Words)
    for ($n = 2; $n -le 10; $n++) {
        [SL]::Glide($px, $py, 120)
        [NcWheel]::Down(5)
        Start-Sleep -Milliseconds 900
        $next = Shot-Window $h "$name-$n"
        if (Same-Picture $last.Path $next.Path) {
            Remove-Item -Force $next.Path
            Get-ChildItem $Ocr -Filter "$name-$n.*" | Remove-Item -Force
            $script:ShotCount--
            break
        }
        $all += @($next.Words)
        $last = $next
    }
    [SL]::Glide($px, $py, 120)
    [NcWheel]::Up(60)
    Start-Sleep -Milliseconds 600
    return $all
}

$W_CANCEL = K 0xCDE8, 0xC18C
$W_OK = K 0xD655, 0xC778
function Close-InWindowDialog([IntPtr] $h, $shot, [switch] $Ok) {
    $b = $shot.Words | Where-Object { $_.Text -match "^(Cancel|$W_CANCEL)$" } | Select-Object -Last 1
    if (-not $b -and $Ok) { $b = $shot.Words | Where-Object { $_.Text -match "^(OK|$W_OK)$" } | Select-Object -Last 1 }
    if ($b) { Click-At ($b.X + [int]($b.W / 2)) ($b.Y + [int]($b.H / 2)) }
    else { [SL]::Front($h); Start-Sleep -Milliseconds 300; [SL]::PressKey(0x1B) }
    Start-Sleep -Seconds 1
    Write-Host "  dialog closed by $(if ($b) { "its '$($b.Text)' button" } else { 'Escape' })"
}

# The words a picture of the settings page shows in its left column (the list of pages).
function Find-Word($words, [string] $pattern, [int] $minX, [int] $maxX, [int] $minY = 0) {
    $words | Where-Object { $_.Text -match $pattern -and $_.X -ge $minX -and $_.X -le $maxX -and $_.Y -ge $minY } | Select-Object -First 1
}

# ---------------------------------------------------------------- installed state
function Scan-Registry([string] $root, [string] $tag) {
    $ErrorActionPreference = 'Continue'
    $o = @(& reg.exe query $root /f rustdesk /s 2>$null)
    $o += @(& reg.exe query $root /f purslane /s 2>$null)
    $ErrorActionPreference = 'Stop'
    $key = ''
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $o) {
        if ($l -match '^HKEY_') {
            $key = $l.Trim()
            if ((Split-Path -Leaf $key) -match $Bad) { [void]$out.Add(@($key, '(key name)')) }
        } elseif ($l -match '^\s{4}(.*?)\s{4}(REG_\w+)\s{4}?(.*)$') {
            if ($l -match $Bad) { [void]$out.Add(@($key, "$($Matches[1]) = $($Matches[3])")) }
        }
    }
    return , $out
}
$RegRoots = @('HKLM\SOFTWARE', 'HKLM\SYSTEM\CurrentControlSet', 'HKCU\SOFTWARE', 'HKU\S-1-5-18\Software', 'HKU\S-1-5-19\Software', 'HKU\S-1-5-20\Software', 'HKU\.DEFAULT\Software')
# Places in the registry a person sees through Windows (installed apps, start-up apps, default
# apps, event viewer, services): a match there is FOUND, elsewhere HIDDEN.
$RegVisible = '(?i)\\Uninstall\\|\\CurrentVersion\\Run|\\StartupApproved\\|\\Services\\EventLog\\|\\Services\\[^\\]+$|\\Classes\\[^\\]+$|\\Classes\\[^\\]+\\shell|\\RegisteredApplications|\\Capabilities|\\App Paths\\|\\Printers\\|\\Print\\Printers|\\AppUserModelId\\|\\Notifications\\Settings'

function Version-Fields([string] $file) {
    $vi = (Get-Item $file).VersionInfo
    $r = @{}
    foreach ($k in @('ProductName', 'FileDescription', 'CompanyName', 'LegalCopyright', 'LegalTrademarks', 'OriginalFilename', 'InternalName', 'Comments', 'ProductVersion', 'FileVersion')) { $r[$k] = [string]$vi.$k }
    return $r
}

function Read-Shared([string] $path) {
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); return , $ms.ToArray() } finally { $fs.Dispose() }
    } catch { return $null }
}

function Scan-Files-Text([string] $dir, [string] $tag) {
    if (-not (Test-Path $dir)) { return }
    foreach ($f in @(Get-ChildItem -Path $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Length -gt 300MB) { continue }
        $bytes = Read-Shared $f.FullName
        if ($null -eq $bytes) { Add-Line 'INFO' 'file not readable' $f.FullName 'held open by a running program'; continue }
        $a = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $u = [Text.Encoding]::Unicode.GetString($bytes)
        $na = ([regex]::Matches($a, $Bad)).Count
        $nu = ([regex]::Matches($u, $Bad)).Count
        if ($na + $nu -eq 0) { continue }
        $textLike = $f.Extension -match '^(?i)\.(txt|toml|ini|log|json|xml|html?|inf|md|cfg|conf|csv|rtf)$' -or $f.Extension -eq ''
        if ($textLike) {
            $wide = ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) -or $nu -gt $na
            $text = if ($wide) { $u } else { [Text.Encoding]::UTF8.GetString($bytes) }
            $hits = @(($text -split "`r?`n") | Where-Object { $_ -match $Bad } | Select-Object -First 6)
            $isNotice = $f.Name -match '(?i)notice|licen[cs]e|open.?source'
            foreach ($h in $hits) {
                if ($isNotice) { Add-Line 'ALLOWED' 'file text' $f.FullName $h }
                elseif ($f.Extension -eq '.log') { Add-Line 'HIDDEN' 'log text' $f.FullName $h }
                else { Found 'file text' $f.FullName $h }
            }
        } else {
            $sample = @([regex]::Matches($a, '[ -~]{0,40}(?i:rust\s*desk|purslane)[ -~]{0,40}') | Select-Object -First 4 | ForEach-Object { $_.Value })
            $sample += @([regex]::Matches($u, '[ -~]{0,40}(?i:rust\s*desk|purslane)[ -~]{0,40}') | Select-Object -First 4 | ForEach-Object { $_.Value })
            Add-Line 'HIDDEN' 'inside a program file' $f.FullName "$na byte strings and $nu wide strings, e.g. $($sample -join ' / ')"
        }
    }
}

function Uninstall-Entries {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) { Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } }
}

function Scan-Installed([string] $phase) {
    Step "installed state ($phase)"
    # Registry
    foreach ($root in $RegRoots) {
        $t0 = Get-Date
        $hits = Scan-Registry $root
        foreach ($h in $hits) {
            if ($h[0] -match $RegVisible) { Found 'registry (shown by Windows)' $h[0] $h[1] } else { Add-Line 'HIDDEN' 'registry' $h[0] $h[1] }
        }
        Write-Host "  registry $root : $($hits.Count) matches in $([int]((Get-Date) - $t0).TotalSeconds) s"
    }
    # File and folder names on C:
    $t0 = Get-Date
    $list = Join-Path $Out "names-on-c-$phase.txt"
    $ErrorActionPreference = 'Continue'
    # One command line for cmd without inner quotes ($Out has no spaces on the runner).
    cmd /c "dir C:\ /s /b /a 2>nul | findstr /i /c:rustdesk /c:purslane > $list"
    $ErrorActionPreference = 'Stop'
    $names = @(Get-Content $list -ErrorAction SilentlyContinue)
    Write-Host "  file and folder names on C: $($names.Count) matches in $([int]((Get-Date) - $t0).TotalSeconds) s"
    foreach ($n in $names) {
        $leaf = Split-Path -Leaf $n
        if ($leaf -notmatch $Bad) { continue }
        if ($n -match '(?i)^C:\\hostedtoolcache\\') { continue }  # the runner's own tools
        if ($n -match '(?i)^C:\\Windows\\Prefetch\\|\\AppData\\Local\\Temp\\|^C:\\Windows\\Temp\\|\\Windows\\WinSxS\\') { Add-Line 'HIDDEN' 'file name' $n $leaf }
        else { Found 'file name' $n $leaf }
    }
    # Text inside the files of ours
    Scan-Files-Text $InstallDir 'program folder'
    foreach ($d in $ProfileDirs) {
        foreach ($sub in @(Get-ChildItem -Path $d -Directory -Force -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)emilli|rustdesk' })) { Scan-Files-Text $sub.FullName 'settings folder' }
    }
    # File properties of every program file
    foreach ($f in @(Get-ChildItem -Path $InstallDir -Recurse -File -Include *.exe, *.dll, *.sys -ErrorAction SilentlyContinue)) {
        $v = Version-Fields $f.FullName
        foreach ($k in $v.Keys) {
            if ($v[$k] -match $Bad) {
                if ($k -eq 'LegalCopyright') { Found 'file properties (Details tab)' "$($f.FullName) $k" $v[$k] } else { Found 'file properties (Details tab, Task Manager)' "$($f.FullName) $k" $v[$k] }
            }
        }
        if ($f.Extension -eq '.exe' -or $f.Name -match '(?i)^lib|emilli') { Info 'file properties' $f.FullName "ProductName '$($v.ProductName)'; FileDescription '$($v.FileDescription)'; CompanyName '$($v.CompanyName)'; Copyright '$($v.LegalCopyright)'; version $($v.FileVersion)" }
    }
    Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue | ForEach-Object { Info 'program folder' $InstallDir $_.Name }
    # Services and drivers
    foreach ($s in @(Get-CimInstance Win32_Service)) {
        $all = "$($s.Name) | $($s.DisplayName) | $($s.Description) | $($s.PathName)"
        if ($all -match $Bad) { Found 'service' $s.Name $all }
        if ($s.PathName -match '(?i)emilli') { Info 'service' $s.Name "shown as '$($s.DisplayName)', description '$($s.Description)', $($s.StartMode), $($s.State)" }
    }
    foreach ($s in @(Get-CimInstance Win32_SystemDriver)) {
        $all = "$($s.Name) | $($s.DisplayName) | $($s.Description) | $($s.PathName)"
        if ($all -match $Bad) { Found 'driver' $s.Name $all }
    }
    $ErrorActionPreference = 'Continue'
    $pnp = (pnputil /enum-drivers 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    foreach ($block in ($pnp -split "(`r?`n){2,}")) { if ($block -match $Bad) { Found 'driver package (pnputil)' 'driver store' $block } }
    # Scheduled tasks
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $acts = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; '
        $all = "$($t.TaskPath)$($t.TaskName) | $($t.Description) | $($t.Author) | $acts"
        if ($all -match $Bad) { Found 'scheduled task' "$($t.TaskPath)$($t.TaskName)" $all }
        if ($acts -match '(?i)emilli') { Info 'scheduled task' "$($t.TaskPath)$($t.TaskName)" $acts }
    }
    # Firewall
    $progs = @{}
    foreach ($a in @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -match '(?i)emilli|rustdesk' })) { $progs[$a.InstanceID] = $a.Program }
    foreach ($r in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        $all = "$($r.DisplayName) | $($r.Description) | $($r.DisplayGroup)"
        if ($all -match $Bad -or ($progs.ContainsKey($r.InstanceID) -and $progs[$r.InstanceID] -match $Bad)) { Found 'firewall rule' $r.Name "$all | $($progs[$r.InstanceID])" }
        if ($progs.ContainsKey($r.InstanceID)) { Info 'firewall rule' $r.Name "'$($r.DisplayName)' $($r.Direction) for $($progs[$r.InstanceID])" }
    }
    # Printers
    foreach ($p in @(Get-Printer -ErrorAction SilentlyContinue)) {
        if ("$($p.Name) | $($p.DriverName) | $($p.PortName) | $($p.Comment)" -match $Bad) { Found 'printer' $p.Name "$($p.Name) | $($p.DriverName) | $($p.PortName)" }
        if ("$($p.Name) $($p.DriverName)" -match '(?i)emilli') { Info 'printer' $p.Name "driver '$($p.DriverName)' port '$($p.PortName)'" }
    }
    foreach ($d in @(Get-PrinterDriver -ErrorAction SilentlyContinue)) { if ("$($d.Name) | $($d.Manufacturer)" -match $Bad) { Found 'print driver' $d.Name "$($d.Name) | $($d.Manufacturer)" } }
    foreach ($p in @(Get-PrinterPort -ErrorAction SilentlyContinue)) { if ("$($p.Name) | $($p.Description)" -match $Bad) { Found 'printer port' $p.Name "$($p.Name) | $($p.Description)" } }
    # Shortcuts (name, target, arguments, description, icon)
    $sh = New-Object -ComObject WScript.Shell
    $dirs = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'),
        "$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu")
    foreach ($d in $dirs) {
        foreach ($l in @(Get-ChildItem -Path $d -Recurse -Force -Filter *.lnk -ErrorAction SilentlyContinue)) {
            $s = $sh.CreateShortcut($l.FullName)
            $all = "$($l.Name) | $($s.TargetPath) $($s.Arguments) | $($s.Description) | $($s.IconLocation) | $($s.WorkingDirectory)"
            if ($all -match $Bad) { Found 'shortcut' $l.FullName $all }
            if ($all -match '(?i)emilli') { Info 'shortcut' $l.FullName $all }
        }
    }
    # Start-up entries (Task Manager, Startup apps) and installed apps
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')) {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($n in @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            if ("$($n.Name) $($n.Value)" -match $Bad) { Found 'start-up entry' $k "$($n.Name) = $($n.Value)" }
            if ("$($n.Name) $($n.Value)" -match '(?i)emilli') { Info 'start-up entry' $k "$($n.Name) = $($n.Value)" }
        }
    }
    foreach ($f in @(Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -match $Bad) { Found 'start-up folder' $f.FullName $f.Name }
    }
    foreach ($e in @(Uninstall-Entries)) {
        $fields = @('DisplayName', 'Publisher', 'DisplayVersion', 'DisplayIcon', 'UninstallString', 'QuietUninstallString', 'InstallLocation', 'URLInfoAbout', 'HelpLink', 'URLUpdateInfo', 'Comments', 'Contact', 'Readme', 'HelpTelephone')
        $all = ($fields | ForEach-Object { "$_=$($e.$_)" }) -join ' | '
        if ($all -match $Bad) { Found 'installed apps' $e.PSChildName $all }
        if ($all -match '(?i)emilli') { Info 'installed apps' $e.PSChildName $all }
    }
    # URL schemes and file types that open our program (Settings, Default apps)
    $ErrorActionPreference = 'Continue'
    $cls = @(& reg.exe query HKLM\SOFTWARE\Classes /f EmilliRemote.exe /s /d 2>$null) + @(& reg.exe query HKCU\SOFTWARE\Classes /f EmilliRemote.exe /s /d 2>$null)
    $ErrorActionPreference = 'Stop'
    foreach ($l in $cls) {
        if ($l -match '^HKEY_[^\\]+\\SOFTWARE\\Classes\\([^\\]+)') {
            $name = $Matches[1]
            $d = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$name" -ErrorAction SilentlyContinue).'(default)'
            Info 'URL scheme or file type' $name "'$d'"
        }
    }
    # Event log (Event Viewer)
    foreach ($log in @('Application', 'System')) {
        foreach ($ev in @(Get-WinEvent -LogName $log -MaxEvents 4000 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match $Bad -or $_.Message -match $Bad })) {
            Found 'event log' "$log, source $($ev.ProviderName), id $($ev.Id)" ([string]$ev.Message)
        }
    }
    # Processes (Task Manager) and window titles
    foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '(?i)emilli|rustdesk' -or $_.ExecutablePath -match '(?i)emilli|rustdesk' })) {
        $desc = if ($p.ExecutablePath -and (Test-Path $p.ExecutablePath)) { (Get-Item $p.ExecutablePath).VersionInfo.FileDescription } else { '' }
        $cmdline = ([string]$p.CommandLine) -replace '--password\s+\S+', '--password (hidden)'
        if ("$($p.Name) $desc" -match $Bad) { Found 'process (Task Manager)' "$($p.Name) pid $($p.ProcessId)" "$desc" }
        if ($cmdline -match $Bad) { Add-Line 'HIDDEN' 'process command line' "$($p.Name) pid $($p.ProcessId)" $cmdline }
        Info 'process (Task Manager)' "$($p.Name) pid $($p.ProcessId) session $($p.SessionId)" "description '$desc'; $cmdline"
    }
    foreach ($w in @([SL]::Windows())) {
        if ($w.Title -match $Bad) { Found 'window title' "$($w.Proc) $($w.Cls)" $w.Title }
    }
}

# ---------------------------------------------------------------- the pages, one language
$TabOrder = @('General', 'Security', 'Network', 'Display', 'Account', 'Printer', 'About')
$script:TabPoints = @{}
$script:UnlockPoints = @{}
$script:Tabs = $TabOrder
$script:NoticePoint = $null
$script:NetRows = @(@('server', 120), @('proxy', 169))

function Visit-Pages([string] $lang) {
    Step "the program's pages in $lang"
    Close-App
    Set-Language $lang
    Start-Process -FilePath $Exe | Out-Null
    $main = Wait-For { Main-Window } 60
    if (-not $main) { Problem "$lang : the main window did not open"; [void](Shot-Screen "$lang-00-no-main-window"); return }
    [SL]::Show($main.Hwnd, 9)
    [SL]::Front($main.Hwnd)
    Start-Sleep -Seconds 4
    $main = Main-Window
    Info 'window title' "$lang main window" $main.Title
    [void](Shot-Window $main.Hwnd "$lang-01-first-screen")
    [void](Shot-Screen "$lang-01-first-screen-whole-screen")

    # A number typed on the first screen and Enter: the session window and what it says when the
    # server cannot be reached (rd.emillis.net is blocked here).
    $f = [SL]::Clip($main.Hwnd)
    Click-At ($f[0] + 394) ($f[1] + 135)
    Start-Sleep -Milliseconds 600
    [void][SL]::TypeKeys('123456789', 30)
    Start-Sleep -Milliseconds 400
    [void](Shot-Window $main.Hwnd "$lang-02-number-typed")
    [SL]::PressKey(0x0D)
    Start-Sleep -Seconds 12
    Shot-Dialogs "$lang-02-connect" $main.Hwnd
    foreach ($win in @(Our-Windows | Where-Object { $_.Hwnd -ne $main.Hwnd })) { [SL]::PostClose($win.Hwnd) }
    Start-Sleep -Seconds 3
    Shot-Dialogs "$lang-02-connect-closing" $main.Hwnd
    foreach ($win in @(Our-Windows | Where-Object { $_.Hwnd -ne $main.Hwnd })) { [SL]::PostClose($win.Hwnd) }
    Start-Sleep -Seconds 2
    [SL]::Front($main.Hwnd)
    Start-Sleep -Seconds 1
    [void](Shot-Window $main.Hwnd "$lang-02-first-screen-after-connect")

    # Settings: the menu icon at the right end of the tab bar, left of the window buttons
    # (690,13 in the 786 px wide window), then the window as large as the screen.
    $f = [SL]::Clip($main.Hwnd)
    Click-At ($f[0] + $f[2] - 96) ($f[1] + 13)
    Start-Sleep -Seconds 3
    [SL]::Show($main.Hwnd, 3)
    Start-Sleep -Seconds 3
    $main = Main-Window
    $f = [SL]::Clip($main.Hwnd)
    $page = Shot-Window $main.Hwnd "$lang-03-settings"
    if ($lang -eq 'en') {
        foreach ($t in $TabOrder) {
            $word = Find-Word $page.Words "^$t`$" ($f[0]) ($f[0] + 230) ($f[1] + 30)
            if ($word) { $script:TabPoints[$t] = @(($word.X + [int]($word.W / 2)), ($word.Y + [int]($word.H / 2))) }
            else { Write-Host "  settings page list: '$t' not read on the picture" }
        }
        # General is drawn as selected and is often not read: it is the row above Security. A page
        # not read otherwise is a page this build does not have (1.5.4 has no Printer page).
        if (-not $script:TabPoints.ContainsKey('General') -and $script:TabPoints.ContainsKey('Security')) {
            $q = $script:TabPoints['Security']; $script:TabPoints['General'] = @($q[0], ($q[1] - 42))
        }
        $known = @($TabOrder | Where-Object { $script:TabPoints.ContainsKey($_) })
        if ($known.Count -ge 2) {
            $script:Tabs = $known
        } else {
            Problem 'the list of settings pages was not read; pages placed by their known size'
            for ($i = 0; $i -lt $TabOrder.Count; $i++) { $script:TabPoints[$TabOrder[$i]] = @(($f[0] + 70), ($f[1] + 28 + 62 + 21 + 42 * $i)) }
            $script:Tabs = $TabOrder
        }
        Write-Host "  settings pages at: $(($script:Tabs | ForEach-Object { "$_ $($script:TabPoints[$_] -join ',')" }) -join '; ')"
        Info 'settings pages' $lang ($script:Tabs -join ', ')
    }
    $px = $f[0] + [int](($f[2] + 230) / 2)
    $py = $f[1] + [int]($f[3] / 2)
    $n = 3
    foreach ($t in $script:Tabs) {
        $n++
        $pt = $script:TabPoints[$t]
        Click-At $pt[0] $pt[1]
        Start-Sleep -Seconds 2
        $name = "{0}-{1:D2}-settings-{2}" -f $lang, $n, $t.ToLower()
        $words = @(Shot-Scrolled $main.Hwnd $name $px $py)
        # Locked pages: "Unlock ... Settings" opens the rest (a UAC check; the runner's user is an
        # administrator). Found on the English page, the same place in Korean.
        if ($t -eq 'Security' -or $t -eq 'Network') {
            if ($lang -eq 'en') {
                $u = $words | Where-Object { $_.Text -match '^Unlock' -and $_.X -gt ($f[0] + 230) } | Select-Object -First 1
                if ($u) { $script:UnlockPoints[$t] = @(($u.X + [int]($u.W / 2)), ($u.Y + [int]($u.H / 2))) }
                else { $script:UnlockPoints[$t] = @(($f[0] + 478), ($f[1] + 61)) }  # white on blue, not read
            }
            if ($script:UnlockPoints.ContainsKey($t)) {
                $q = $script:UnlockPoints[$t]
                Click-At $q[0] $q[1]
                Start-Sleep -Seconds 5
                Shot-Dialogs "$name-unlock" $main.Hwnd
                $main = Main-Window
                [SL]::Front($main.Hwnd)
                Start-Sleep -Seconds 1
                $uw = @(Shot-Scrolled $main.Hwnd "$name-unlocked" $px $py)
                if ($t -eq 'Network') {
                    # The two dialogs of the network page: servers, proxy (rows read on the English
                    # page; else where they are once the unlock button is gone).
                    if ($lang -eq 'en') {
                        $r1 = $uw | Where-Object { $_.Text -match '^ID/Relay' } | Select-Object -First 1
                        $r2 = $uw | Where-Object { $_.Text -match '^Socks5' } | Select-Object -First 1
                        $script:NetRows = @(@('server', $(if ($r1) { $r1.Y + [int]($r1.H / 2) - $f[1] } else { 120 })), @('proxy', $(if ($r2) { $r2.Y + [int]($r2.H / 2) - $f[1] } else { 169 })))
                        Write-Host "  network rows at: $(($script:NetRows | ForEach-Object { "$($_[0]) $($_[1])" }) -join '; ')"
                    }
                    foreach ($row in $script:NetRows) {
                        Click-At ($f[0] + 320) ($f[1] + $row[1])
                        Start-Sleep -Seconds 2
                        $d = Shot-Window $main.Hwnd "$name-$($row[0])-dialog"
                        Shot-Dialogs "$name-$($row[0])" $main.Hwnd
                        Close-InWindowDialog $main.Hwnd $d
                    }
                }
            } else { Write-Host "  $t : no unlock button read" }
        }
        # About: the open-source notice (1.5.4), the one page allowed to name the original work.
        if ($t -eq 'About') {
            if ($lang -eq 'en') {
                $o = $words | Where-Object { $_.Text -match '^Open-source$|^notice$' -and $_.X -gt ($f[0] + 230) } | Select-Object -First 1
                if ($o) { $script:NoticePoint = @(($o.X + [int]($o.W / 2)), ($o.Y + [int]($o.H / 2))) }
            }
            if ($script:NoticePoint) {
                Click-At $script:NoticePoint[0] $script:NoticePoint[1]
                Start-Sleep -Seconds 2
                $d = Shot-Window $main.Hwnd "$name-notice"
                Close-InWindowDialog $main.Hwnd $d -Ok
            } else { Write-Host "  About: no open-source notice link on this build" }
        }
    }
    Shot-Dialogs "$lang-90-after-pages" $main.Hwnd
    Info 'pages' $lang "$script:ShotCount pictures so far"
}

# ---------------------------------------------------------------- run
Write-Host "Windows $([Environment]::OSVersion.VersionString); user $env:USERNAME; mode $Mode"
$s = [SL]::Screen()
Write-Host "screen $($s[2])x$($s[3]); DPI $([SL]::MonitorDpi())"
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`r`n127.0.0.1 rd.emillis.net`r`n::1 rd.emillis.net"
ipconfig /flushdns | Out-Null
$vi = (Get-Item $Setup).VersionInfo
Info 'Setup file' (Split-Path -Leaf $Setup) "ProductName '$($vi.ProductName)'; FileDescription '$($vi.FileDescription)'; CompanyName '$($vi.CompanyName)'; version $($vi.ProductVersion); SHA-256 $((Get-FileHash -Algorithm SHA256 $Setup).Hash.ToLower())"
foreach ($k in @('ProductName', 'FileDescription', 'CompanyName', 'LegalCopyright', 'OriginalFilename', 'InternalName', 'Comments')) {
    if ([string]$vi.$k -match $Bad) { Found 'Setup file properties' $k ([string]$vi.$k) }
}

$beforeId = ''
if ($Before) {
    Step "the earlier Setup first ($(Split-Path -Leaf $Before)): a PC that upgrades"
    $p = Start-Process -FilePath $Before -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$Out\setup-before.log")
    $p.WaitForExit(600000) | Out-Null
    $beforeId = (& $Exe --get-id | Out-String).Trim()
    $beforeVer = (Get-Item $Exe).VersionInfo.ProductVersion
    $beforeFiles = @(Get-ChildItem -Path $InstallDir -Force | ForEach-Object { $_.Name })
    Info 'upgrade' 'before' "Setup exit $($p.ExitCode); program $beforeVer; PC number $beforeId; program folder: $($beforeFiles -join ', ')"
    Start-Sleep -Seconds 5
}

Step 'Emilli Remote Setup, silently'
$t0 = Get-Date
$p = Start-Process -FilePath $Setup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$Out\setup.log")
$p.WaitForExit(600000) | Out-Null
Write-Host "Setup exit $($p.ExitCode) after $([int]((Get-Date) - $t0).TotalSeconds) s"
if (-not (Test-Path $Exe)) { Problem 'the program was not installed'; Save-Found; throw 'not installed' }
Start-Sleep -Seconds 10
if ($Before) {
    $afterId = (& $Exe --get-id | Out-String).Trim()
    $afterVer = (Get-Item $Exe).VersionInfo.ProductVersion
    $svc = Get-CimInstance Win32_Service -Filter "Name='EmilliRemote'"
    $cfg = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\EmilliRemote\config\EmilliRemote2.toml'
    $server = if (Test-Path $cfg) { [string](Select-String -Path $cfg -Pattern '^custom-rendezvous-server' | Select-Object -First 1).Line } else { '' }
    $afterFiles = @(Get-ChildItem -Path $InstallDir -Force | ForEach-Object { $_.Name })
    Info 'upgrade' 'after' "program $afterVer; PC number $afterId; service $($svc.State) as '$($svc.DisplayName)'; $server; program folder: $($afterFiles -join ', ')"
    if (-not ($beforeId -match '^\d{6,12}$' -and $afterId -eq $beforeId)) { Problem "upgrade: the PC number changed ($beforeId -> $afterId)" }
    if (-not ($svc -and $svc.State -eq 'Running')) { Problem 'upgrade: the service is not running' }
    if ($server -notmatch 'rd\.emillis\.net') { Problem "upgrade: the server setting was lost ($server)" }
    $left = @($afterFiles | Where-Object { $_ -match $Bad })
    if ($left.Count -gt 0) { Problem "upgrade: files under the old name are left: $($left -join ', ')" }
}

$main = Wait-For { Main-Window } 20
if ($main) { Write-Host 'the main window is open after Setup' }
Visit-Pages 'en'
Visit-Pages 'ko'
Scan-Installed 'after-install'
Close-App

Save-Found
$found = @($Lines | Where-Object { $_ -like 'FOUND *' }).Count
$allowed = @($Lines | Where-Object { $_ -like 'ALLOWED *' }).Count
$hidden = @($Lines | Where-Object { $_ -like 'HIDDEN *' }).Count
Write-Host ("SUMMARY {0} found where a person sees it, {1} in the open-source notice, {2} hidden, {3} pictures, OCR {4}" -f $found, $allowed, $hidden, $script:ShotCount, $(if ($script:OcrOk) { 'on' } else { 'off' }))
foreach ($m in $script:Problems) { Write-Host "PROBLEM $m" }
if ($Mode -eq 'check') {
    if ($found -gt 0) { throw "$found places show the old name" }
    if ($script:Problems.Count -gt 0) { throw "$($script:Problems.Count) problems: the pages were not all read" }
}
