# Emilli Remote Setup (REMOTE-EASY-3) on a fresh Windows runner, no server involved:
#   1. an earlier remote program under the old name is installed first (the unreleased REMOTE-153
#      Setup, which installs the program under the old name, as the plain download of the old
#      guide did), and its PC number is read;
#   2. the new Setup runs silently: one path, no choices;
#   3. checks: service, settings, the PC kept its number, and the old name is nowhere a person
#      looks (installed apps, shortcuts, Start menu, start-up list, services, firewall, printers,
#      file properties, window titles, process names);
#   4. "Uninstall" from Windows' installed apps, then: nothing listed, nothing left running.
# Every check prints "PASS" or "FAIL"; the script ends with an error if any check failed.
param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $OldSetup,
    [Parameter(Mandatory)] [string] $Work
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$script:fails = 0
$script:passes = 0
function Check([string] $name, [bool] $ok, [string] $detail = '') {
    if ($ok) { $script:passes++ } else { $script:fails++ }
    Write-Host ("{0} {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { " ($detail)" } else { '' }))
}
$Bad = '(?i)rust\s*desk'
$NewExe = 'C:\Program Files\EmilliRemote\EmilliRemote.exe'
$OldExe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcProfile = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming'

function Uninstall-Entries {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } |
            Select-Object PSChildName, DisplayName, Publisher, DisplayIcon, UninstallString, InstallLocation
    }
}
function Shortcut-Names {
    $dirs = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'),
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
    foreach ($d in $dirs) {
        if (Test-Path $d) { Get-ChildItem -Path $d -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' -or $_.PSIsContainer } | ForEach-Object { $_.FullName } }
    }
}
function Window-Titles([string[]] $names) {
    Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Wn {
  delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(P f, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  public static List<string> Of(uint[] pids) {
    var r = new List<string>(); var set = new HashSet<uint>(pids);
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (set.Contains(p)) { var s = new StringBuilder(512); GetWindowText(h, s, 512); if (s.Length > 0) r.Add(s.ToString()); } return true; }, IntPtr.Zero);
    return r;
  }
}
'@ -ErrorAction SilentlyContinue
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName } | ForEach-Object { [uint32]$_.Id })
    if ($pids.Count -eq 0) { return @() }
    return [Wn]::Of($pids)
}

Write-Host "Windows $([Environment]::OSVersion.VersionString); user $env:USERNAME"

# ---------------------------------------------------------------- 1. the old name first
$oldPw = Join-Path $Work 'old-pw.txt'
[IO.File]::WriteAllText($oldPw, ('Old' + [Guid]::NewGuid().ToString('N').Substring(0, 12)))
$p = Start-Process -FilePath $OldSetup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MODE=store', "/PWFILE=$oldPw", "/LOG=$Work\old-setup.log")
$p.WaitForExit(600000) | Out-Null
Remove-Item -Force $oldPw
Check 'earlier program installed under the old name (the starting point of 11/12)' ((Test-Path $OldExe) -and [bool](Get-Service -Name RustDesk -ErrorAction SilentlyContinue)) "exit $($p.ExitCode)"
$oldId = (& $OldExe --get-id | Out-String).Trim()
Write-Host "earlier program's PC number: $oldId"
Check 'old name visible before (the test can see it)' ([bool](Uninstall-Entries | Where-Object { $_.DisplayName -match $Bad -or $_.PSChildName -match $Bad })) 'Uninstall key of the old program'

# ---------------------------------------------------------------- 2. the new Setup
$setupName = Split-Path -Leaf $Setup
Check 'downloaded file name' ($setupName -notmatch $Bad) $setupName
$vi = (Get-Item $Setup).VersionInfo
foreach ($k in @('ProductName', 'FileDescription', 'CompanyName', 'LegalCopyright', 'OriginalFilename', 'InternalName')) {
    Check "Setup file property $k" ([string]$vi.$k -notmatch $Bad) ([string]$vi.$k)
}
$idFile = Join-Path $Work 'id.txt'
$t0 = Get-Date
$p = Start-Process -FilePath $Setup -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/IDFILE=$idFile", "/LOG=$Work\setup.log")
$p.WaitForExit(600000) | Out-Null
Check 'Setup ended with exit code 0' ($p.ExitCode -eq 0) "exit $($p.ExitCode) after $([int]((Get-Date) - $t0).TotalSeconds) s"
Get-Content "$Work\setup.log" | Select-String 'Emilli:' | ForEach-Object { Write-Host "  $($_.Line -replace '^.*Emilli: ', 'setup: ')" }
# Diagnostics: every process started since Setup began (the program's installer and what it ran),
# and the program's own logs.
Get-CimInstance Win32_Process | Where-Object { $_.CreationDate -ge $t0 -or $_.Name -match '(?i)emilli|rust' } | ForEach-Object {
    Write-Host "  running: $($_.Name) pid $($_.ProcessId) parent $($_.ParentProcessId): $(($_.CommandLine -replace '--password\s+\S+', '--password (hidden)'))"
}
foreach ($d in @("$env:APPDATA\EmilliRemote\log", 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\EmilliRemote\log', 'C:\Windows\System32\config\systemprofile\AppData\Roaming\EmilliRemote\log')) {
    foreach ($f in @(Get-ChildItem -Path $d -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 4)) {
        Write-Host "  ---- log $($f.FullName)"
        Get-Content $f.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  | $_" }
    }
}

# ---------------------------------------------------------------- 3. checks
$svc = Get-CimInstance Win32_Service -Filter "Name='EmilliRemote'"
Check 'service EmilliRemote runs automatically as LocalSystem' ($svc -and $svc.State -eq 'Running' -and $svc.StartMode -eq 'Auto' -and $svc.StartName -eq 'LocalSystem') "$($svc.State) $($svc.StartMode) $($svc.StartName)"
Check 'service display name is "Emilli Remote"' ($svc.DisplayName -eq 'Emilli Remote') "'$($svc.DisplayName)'"
$named = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -match $Bad -or $_.DisplayName -match $Bad -or $_.PathName -match $Bad })
Check 'no service shows the old name' ($named.Count -eq 0) (($named | ForEach-Object { $_.Name }) -join ', ')
Check 'earlier program removed' (-not (Test-Path 'C:\Program Files\RustDesk')) ''
$newId = if (Test-Path $idFile) { (Get-Content -Raw $idFile).Trim() } else { '' }
$cliId = (& $NewExe --get-id | Out-String).Trim()
Check 'this PC kept its number from the earlier program' ($oldId -match '^\d{6,12}$' -and $newId -eq $oldId -and $cliId -eq $oldId) "earlier $oldId, Setup $newId, program $cliId"
$cfg = Join-Path $SvcProfile 'EmilliRemote\config\EmilliRemote2.toml'
$text = if (Test-Path $cfg) { Get-Content -Raw $cfg } else { '' }
$q = "[`"']"
Check 'server saved in the service settings' ($text -match "custom-rendezvous-server = ${q}rd\.emillis\.net$q" -and $text -match "api-server = ${q}https://rd\.emillis\.net$q" -and $text -match '(?m)^key = ') $cfg
foreach ($opt in @('custom-rendezvous-server', 'api-server')) {
    Write-Host "  --option $opt -> $((& $NewExe --option $opt | Out-String).Trim())"
}

$entries = @(Uninstall-Entries)
$ours = @($entries | Where-Object { $_.DisplayName -eq 'Emilli Remote' })
Check 'installed apps: exactly one "Emilli Remote"' ($ours.Count -eq 1) (($ours | ForEach-Object { "$($_.PSChildName): $($_.Publisher)" }) -join '; ')
$badEntries = @($entries | Where-Object { ($_.DisplayName + ' ' + $_.Publisher + ' ' + $_.DisplayIcon + ' ' + $_.UninstallString + ' ' + $_.InstallLocation) -match $Bad })
Check 'installed apps: the old name nowhere' ($badEntries.Count -eq 0) (($badEntries | ForEach-Object { $_.DisplayName }) -join ', ')
$links = @(Shortcut-Names)
$links | Where-Object { $_ -match '(?i)emilli' } | ForEach-Object { Write-Host "  shortcut: $_" }
Check 'shortcuts and Start menu: the old name nowhere' (@($links | Where-Object { (Split-Path -Leaf $_) -match $Bad }).Count -eq 0) ''
Check 'desktop shortcut "Emilli Remote"' (Test-Path "$env:PUBLIC\Desktop\Emilli Remote.lnk") ''
Check 'Start menu folder "Emilli Remote"' (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Emilli Remote\Emilli Remote.lnk") ''
$startup = @(Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Check 'start-up list (Task Manager, Startup apps): the old name nowhere' (@($startup | Where-Object { $_ -match $Bad }).Count -eq 0) ($startup -join ', ')
$fw = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Bad })
Check 'firewall rules: the old name nowhere' ($fw.Count -eq 0) (($fw | ForEach-Object { $_.DisplayName }) -join ', ')
$pr = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Bad -or $_.DriverName -match $Bad })
Check 'printers: the old name nowhere' ($pr.Count -eq 0) (($pr | ForEach-Object { $_.Name }) -join ', ')
$vi = (Get-Item $NewExe).VersionInfo
foreach ($k in @('ProductName', 'FileDescription', 'CompanyName', 'OriginalFilename', 'InternalName')) {
    Check "program file property $k (Task Manager, Properties)" ([string]$vi.$k -notmatch $Bad) ([string]$vi.$k)
}
Start-Sleep -Seconds 5
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)emilli|rust' })
$procs | ForEach-Object { Write-Host "  process $($_.ProcessName) (session $($_.SessionId)) '$($_.MainWindowTitle)'" }
Check 'running processes: the old name nowhere' (@($procs | Where-Object { $_.ProcessName -match $Bad }).Count -eq 0) ''
$titles = @(Window-Titles @('EmilliRemote'))
Write-Host "  window titles: $($titles -join ' | ')"
Check 'window titles: the old name nowhere' (@($titles | Where-Object { $_ -match $Bad }).Count -eq 0) ''

# ---------------------------------------------------------------- 4. uninstall from installed apps
$entry = $ours | Select-Object -First 1
if ($entry) {
    $cmd = [string]$entry.UninstallString
    Write-Host "Uninstall: $cmd"
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe, $args2 = $Matches[1], $Matches[2] } else { $exe, $args2 = $cmd, '' }
    $u = Start-Process -FilePath $exe -ArgumentList $args2 -PassThru
    $u.WaitForExit(180000) | Out-Null
    $end = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $end -and ((Get-Service -Name EmilliRemote -ErrorAction SilentlyContinue) -or (Test-Path $NewExe))) { Start-Sleep -Seconds 2 }
}
$after = @(Uninstall-Entries | Where-Object { $_.DisplayName -match '(?i)emilli' -or ($_.DisplayName + ' ' + $_.Publisher) -match $Bad })
Check 'after uninstall: nothing listed in installed apps' ($after.Count -eq 0) (($after | ForEach-Object { $_.DisplayName }) -join ', ')
Check 'after uninstall: service gone' (-not (Get-Service -Name EmilliRemote -ErrorAction SilentlyContinue)) ''
Check 'after uninstall: program folder gone' (-not (Test-Path 'C:\Program Files\EmilliRemote')) ''
$leftLinks = @(Shortcut-Names | Where-Object { (Split-Path -Leaf $_) -match '(?i)emilli' -or (Split-Path -Leaf $_) -match $Bad })
Check 'after uninstall: no shortcut left' ($leftLinks.Count -eq 0) ($leftLinks -join ', ')
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)emilliremote' -or $_.ProcessName -match $Bad })
Check 'after uninstall: nothing running' ($left.Count -eq 0) (($left | ForEach-Object { $_.ProcessName }) -join ', ')

Write-Host ("SUMMARY {0} passed, {1} failed" -f $script:passes, $script:fails)
if ($script:fails -gt 0) { throw "$($script:fails) checks failed" }
