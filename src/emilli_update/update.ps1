# Emilli Remote update helper (REMOTE-EASY-4). The program writes this file into
# <Program Files>\EmilliRemoteUpdate\work beside the Setup it downloaded and checked (size and
# SHA-256 against the signed version file), and starts it as SYSTEM with no window. It runs outside
# the program, so it carries on while the Setup replaces the program and restarts its service:
#   1. keep a copy of the Setup of the running version (written by the last install) for going back;
#   2. run the new Setup silently (it keeps this PC's number, account and settings);
#   3. wait until the service runs, its pipe answers and the program reports the new version;
#   4. if that does not happen within HealthSeconds, run the kept Setup to put the previous version
#      back and wait for it the same way;
#   5. write the result (last-result.json), which the program shows once at its next start.
# Plain ASCII (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $From,
    [Parameter(Mandatory)] [string] $Kept,
    [Parameter(Mandatory)] [string] $Program,
    [Parameter(Mandatory)] [string] $Result,
    [int] $Reopen = 0,
    [int] $HealthSeconds = 120
)
$ErrorActionPreference = 'Continue'
$Work = Split-Path -Parent $Setup
$Log = Join-Path $Work 'update.log'
$Started = Get-Date
function Log([string] $m) { Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EmilliUpdatePipe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool WaitNamedPipe(string name, uint timeout);
}
'@

function Program-Version {
    $exe = Join-Path $Program 'EmilliRemote.exe'
    if (-not (Test-Path $exe)) { return '' }
    $v = ''
    try { $v = [string](& $exe --version 2>$null | Where-Object { $_ -match '^\d+(\.\d+)+$' } | Select-Object -First 1) } catch { }
    if (-not $v) { $v = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EmilliRemote' -ErrorAction SilentlyContinue).DisplayVersion }
    return $v.Trim()
}

# Healthy: the service runs, its pipe answers, and the program on disk is the wanted version; twice,
# five seconds apart, so a service that starts and falls over does not count.
function Healthy([string] $Want) {
    $svc = Get-Service -Name 'EmilliRemote' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    if (-not [EmilliUpdatePipe]::WaitNamedPipe('\\.\pipe\EmilliRemote\query', 2000)) { return $false }
    if ((Program-Version) -ne $Want) { return $false }
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name 'EmilliRemote' -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running' -and [EmilliUpdatePipe]::WaitNamedPipe('\\.\pipe\EmilliRemote\query', 2000))
}

function Wait-Healthy([string] $Want, [int] $Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if (Healthy $Want) { return $true }
        Start-Sleep -Seconds 3
    }
    return (Healthy $Want)
}

function Run-Setup([string] $File, [string] $Tag) {
    $p = Start-Process -FilePath $File -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $Work "setup-$Tag.log")") -PassThru
    if (-not $p.WaitForExit(15 * 60 * 1000)) { Log "$Tag Setup still running after 15 minutes"; return -1 }
    return $p.ExitCode
}

function Save-Result([string] $Kind, [string] $Detail) {
    $r = [ordered]@{
        result = $Kind
        from = $From
        to = $Version
        detail = $Detail
        at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        seconds = [int]((Get-Date) - $Started).TotalSeconds
        reopen = $Reopen
        reopened = 0
        shown = 0
    }
    [IO.File]::WriteAllText($Result, ($r | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Log "result $Kind ($Detail) after $($r.seconds) s"
}

Log "update $From -> $Version with $Setup"
# The result of an earlier update goes first. The new version's process looks for this update's
# result from its start and stops at the first result it finds: an earlier one (already reopened,
# or older than 30 minutes) ended that wait before this one was written, so the window stayed
# closed after a second update and came up by itself after the next one (laptop run of
# 2026-11-25 14:33Z).
Remove-Item -Force -Path $Result -ErrorAction SilentlyContinue
$Previous = Join-Path $Work 'previous-setup.exe'
try { Copy-Item -Force -Path $Kept -Destination $Previous -ErrorAction Stop } catch {
    Log "no Setup of the running version to go back to: $($_.Exception.Message)"
    Save-Result 'failed' 'no-rollback'
    exit 1
}

$code = Run-Setup $Setup 'new'
Log "new Setup exit code $code"
if (Wait-Healthy $Version $HealthSeconds) {
    Save-Result 'updated' "setup $code"
    exit 0
}
$now = Program-Version
$svc = Get-Service -Name 'EmilliRemote' -ErrorAction SilentlyContinue
Log "not healthy after $HealthSeconds s: service $(if ($svc) { $svc.Status } else { 'missing' }), program '$now'; putting $From back"
$code2 = Run-Setup $Previous 'previous'
Log "previous Setup exit code $code2"
if (Wait-Healthy $From $HealthSeconds) {
    Save-Result 'rolled_back' "new setup $code, service $(if ($svc) { $svc.Status } else { 'missing' }), program '$now'"
    exit 2
}
Save-Result 'failed' "new setup $code, previous setup $code2"
exit 3
