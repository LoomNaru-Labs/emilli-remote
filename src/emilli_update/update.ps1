# Emilli Remote update helper (REMOTE-EASY-4, REMOTE-EASY-5). The program writes this file into
# <Program Files>\EmilliRemoteUpdate\work beside the Setup it downloaded and checked (size and
# SHA-256 against the signed version file), and starts it as SYSTEM with no window. It runs outside
# the program, so it carries on while the Setup replaces the program and restarts its service:
#   1. keep a copy of the Setup of the running version (written by the last install) for going back,
#      write trial.json (what is being tried) and a start-up task that carries on after a restart;
#   2. run the new Setup silently (it keeps this PC's number, account and settings);
#   3. the new version must show that it works the way the old one did:
#      a. its service runs, its pipe answers and the program reports the new version, within
#         HealthSeconds;
#      b. when the old version was registered with its ID server at the start (-Registered 1): the
#         new one registers there within RegisterSeconds, then stays registered for HoldSeconds; a
#         gap of LossSeconds in a row counts as lost. Only time when this helper itself reaches the
#         ID server (-Server, a TCP connection) counts: a PC with no connection at all, or with the
#         server down, is not a failed update, and the clock waits (up to OfflineHours);
#   4. otherwise run the kept Setup to put the previous version back, wait for it the same way as
#      3a, and write skip.json so the automatic update does not try that version again;
#   5. write the result (last-result.json): "updated" as soon as the new version registers (so the
#      window can say so), confirmed after the hold; or "rolled_back" / "failed". The program shows
#      it once. The start-up task and trial.json go at the end.
# After a restart the task starts this file again with -Resume: it reads trial.json and finishes a
# roll back that was under way, or runs the new Setup again when the restart came in the middle of it,
# then tries the new version from 3a. After a third restart within one trial the previous version
# goes back, without a skip (the restarts, not the version, are the likely cause).
# Plain ASCII (Windows PowerShell 5.1).
param(
    [string] $Setup = '',
    [string] $Version = '',
    [string] $From = '',
    [string] $Kept = '',
    [string] $Program = '',
    [string] $Result = '',
    [int] $Reopen = 0,
    [string] $Server = '',
    [int] $Registered = 0,
    [switch] $Resume,
    [int] $HealthSeconds = 120,
    [int] $RegisterSeconds = 300,
    [int] $HoldSeconds = 600,
    [int] $LossSeconds = 180,
    [int] $OfflineHours = 72,
    [int] $PollSeconds = 10
)
$ErrorActionPreference = 'Continue'
$Work = if ($Setup) { Split-Path -Parent $Setup } else { $PSScriptRoot }
$Log = Join-Path $Work 'update.log'
$TrialFile = Join-Path $Work 'trial.json'
$TaskName = 'EmilliRemoteUpdate'
$Started = Get-Date
function Log([string] $m) { Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

if (-not ('EmilliUpdatePipe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EmilliUpdatePipe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool WaitNamedPipe(string name, uint timeout);
}
'@
}

function Now-Seconds { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Wait-Poll([int] $Seconds) { Start-Sleep -Seconds $Seconds }

function Program-Version {
    $exe = Join-Path $Program 'EmilliRemote.exe'
    if (-not (Test-Path $exe)) { return '' }
    $v = ''
    try { $v = [string](& $exe --version 2>$null | Where-Object { $_ -match '^\d+(\.\d+)+$' } | Select-Object -First 1) } catch { }
    if (-not $v) { $v = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EmilliRemote' -ErrorAction SilentlyContinue).DisplayVersion }
    return $v.Trim()
}

function Service-Status {
    $svc = Get-Service -Name 'EmilliRemote' -ErrorAction SilentlyContinue
    if ($svc) { return [string]$svc.Status }
    return 'missing'
}

# Healthy: the service runs, its pipe answers, and the program on disk is the wanted version; twice,
# five seconds apart, so a service that starts and falls over does not count.
function Healthy([string] $Want) {
    if ((Service-Status) -ne 'Running') { return $false }
    if (-not [EmilliUpdatePipe]::WaitNamedPipe('\\.\pipe\EmilliRemote\query', 2000)) { return $false }
    if ((Program-Version) -ne $Want) { return $false }
    Start-Sleep -Seconds 5
    return ((Service-Status) -eq 'Running' -and [EmilliUpdatePipe]::WaitNamedPipe('\\.\pipe\EmilliRemote\query', 2000))
}

function Wait-Healthy([string] $Want, [int] $Seconds) {
    $end = (Now-Seconds) + $Seconds
    while ((Now-Seconds) -lt $end) {
        if (Healthy $Want) { return $true }
        Wait-Poll 3
    }
    return (Healthy $Want)
}

# Registered: the program's service-side process has had an answer from its ID server in the last
# minute, with this PC's key confirmed there ("registered" in --emilli-update state; a program that
# does not answer, or answers without the field, is not registered).
function Probe-Registered {
    $exe = Join-Path $Program 'EmilliRemote.exe'
    if (-not (Test-Path $exe)) { return $false }
    try {
        $o = [string](& $exe --emilli-update state 2>$null | Select-Object -First 1)
        $s = $o | ConvertFrom-Json
        return ($s.registered -eq $true)
    } catch { return $false }
}

# Whether this helper itself reaches the ID server (TCP to host:port, 5 s). No: no connection at
# all, or the server is down; the trial's clocks then wait.
function Probe-Server {
    if (-not $Server) { return $false }
    $i = $Server.LastIndexOf(':')
    if ($i -lt 1) { return $false }
    $h = $Server.Substring(0, $i).Trim('[', ']')
    $p = 0
    if (-not [int]::TryParse($Server.Substring($i + 1), [ref]$p)) { return $false }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect($h, $p, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(5000)) { return $false }
        $c.EndConnect($a)
        return $c.Connected
    } catch { return $false } finally { $c.Close() }
}

function Run-Setup([string] $File, [string] $Tag) {
    $p = Start-Process -FilePath $File -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $Work "setup-$Tag.log")") -PassThru
    if (-not $p.WaitForExit(15 * 60 * 1000)) { Log "$Tag Setup still running after 15 minutes"; return -1 }
    return $p.ExitCode
}

function Register-Resume {
    try {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $act = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $Work 'update.ps1')`" -Resume"
        $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 4)
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $pr -Settings $set -Force -ErrorAction Stop | Out-Null
        Log "start-up task $TaskName registered (carries on after a restart)"
    } catch { Log "start-up task not registered: $($_.Exception.Message)" }
}
function Unregister-Resume {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Write-Json([string] $Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
}
function Read-Json([string] $Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json) } catch { return $null }
}

function Save-Trial([string] $Phase, [string] $Reason = '') {
    $script:Trial.phase = $Phase
    $script:Trial.reason = $Reason
    Write-Json $TrialFile $script:Trial
}

function Save-Result([string] $Kind, [string] $Detail, [int] $Confirmed = 1) {
    $r = [ordered]@{
        result = $Kind
        from = $From
        to = $Version
        detail = $Detail
        confirmed = $Confirmed
        at = Now-Seconds
        seconds = [int]((Get-Date) - $Started).TotalSeconds
        reopen = $Reopen
        reopened = 0
        shown = 0
    }
    Write-Json $Result $r
    Log "result $Kind ($Detail) after $($r.seconds) s"
}
# The interim "updated" becomes confirmed; what the program already did with it (reopened, shown)
# stays, so the window does not say it twice.
function Confirm-Result([string] $Detail) {
    $r = Read-Json $Result
    if (-not $r -or $r.result -ne 'updated') { Save-Result 'updated' $Detail; return }
    $r.confirmed = 1
    $r.detail = $Detail
    Write-Json $Result $r
    Log "result updated confirmed ($Detail)"
}

function Quit([int] $Code) { exit $Code }
function Finish([int] $Code) {
    Unregister-Resume
    Remove-Item -Force -Path $TrialFile -ErrorAction SilentlyContinue
    Quit $Code
}

# 3b. Returns 'held', 'never' (no registration while the server was reachable for RegisterSeconds),
# 'lost' (unregistered for LossSeconds in a row while the server was reachable, before the hold
# ended) or 'offline' (OfflineHours without reaching the server). Calls On-Registered once.
function Watch-Registration {
    $reachable = 0; $held = 0; $loss = 0; $offline = 0
    $once = $false
    $last = Now-Seconds
    while ($true) {
        $now = Now-Seconds
        $dt = [Math]::Max(0, $now - $last)
        $last = $now
        if (Probe-Registered) {
            if (-not $once) {
                $once = $true
                Log "the new version registered with its ID server"
                On-Registered
            } else { $held += $dt }
            $loss = 0
            if ($held -ge $HoldSeconds) { return 'held' }
        } elseif (Probe-Server) {
            if (-not $once) {
                $reachable += $dt
                if ($reachable -ge $RegisterSeconds) { return 'never' }
            } else {
                $loss += $dt
                if ($loss -ge $LossSeconds) { return 'lost' }
            }
        } else {
            $offline += $dt
            if ($offline -ge $OfflineHours * 3600) { return 'offline' }
        }
        Wait-Poll $PollSeconds
    }
}
function On-Registered {
    Save-Trial 'hold'
    Save-Result 'updated' 'registered' 0
}

# 4. Back to the previous version. $Skip: the version itself failed (not a restart in the middle).
function Roll-Back([string] $Reason, [bool] $Skip) {
    Save-Trial 'rollback' $Reason
    if ($Skip) { Write-Json (Join-Path (Split-Path -Parent $Result) 'skip.json') ([ordered]@{ version = $Version; reason = $Reason; at = Now-Seconds }) }
    $now = Program-Version
    Log "putting $From back ($Reason): service $(Service-Status), program '$now'"
    $code2 = Run-Setup $script:Previous 'previous'
    Log "previous Setup exit code $code2"
    if (Wait-Healthy $From $HealthSeconds) {
        Save-Result 'rolled_back' "$Reason; program '$now'"
        Finish 2
    }
    Save-Result 'failed' "$Reason; previous setup $code2"
    Finish 3
}

# 3. The new version, from its service on.
function Try-New {
    Save-Trial 'service'
    if (-not (Wait-Healthy $Version $HealthSeconds)) {
        Log "the new version is not healthy after $HealthSeconds s"
        Roll-Back 'service' $true
    }
    if ($Registered -ne 1) {
        Save-Result 'updated' 'service; registration not checked: the previous version was not registered at the start'
        Finish 0
    }
    Save-Trial 'register'
    $outcome = Watch-Registration
    Log "registration watch: $outcome"
    switch ($outcome) {
        'held' { Confirm-Result 'registered and held'; Finish 0 }
        'offline' { Confirm-Result "not confirmed: no connection to the ID server for $OfflineHours hours"; Finish 0 }
        'never' { Roll-Back 'unreachable' $true }
        'lost' { Roll-Back 'lost' $true }
    }
}

function Main {
    if ($Resume) {
        $t = Read-Json $TrialFile
        if (-not $t) { Log 'resumed after a restart: no trial, nothing to do'; Unregister-Resume; Quit 0 }
        $script:Trial = $t
        $script:Setup = $t.setup; $script:Version = $t.to; $script:From = $t.from; $script:Program = $t.program
        $script:Result = $t.result; $script:Reopen = [int]$t.reopen; $script:Server = $t.server
        $script:Registered = [int]$t.registered; $script:Previous = $t.previous
        $script:Trial.resumes = [int]$t.resumes + 1
        Log "resumed after a restart in phase '$($t.phase)' ($From -> $Version), restart $($script:Trial.resumes) of this trial"
        if ($t.phase -eq 'rollback') { Roll-Back ([string]$t.reason) $false }
        if ($script:Trial.resumes -gt 3) { Roll-Back 'interrupted' $false }
        if ($t.phase -eq 'setup') {
            Save-Trial 'setup'
            $code = Run-Setup $Setup 'new-again'
            Log "new Setup (again, after the restart) exit code $code"
        }
        Try-New
        return
    }
    Log "update $From -> $Version with $Setup (ID server '$Server', registered at the start: $Registered)"
    $old = Read-Json $TrialFile
    if ($old -and (Now-Seconds) -lt [long]$old.until) {
        Log "another update is still being tried ($($old.from) -> $($old.to)); this one does not start"
        Quit 4
    }
    # The result of an earlier update goes first. The new version's process looks for this update's
    # result from its start and stops at the first result it finds: an earlier one (already reopened,
    # or older than 30 minutes) ended that wait before this one was written, so the window stayed
    # closed after a second update and came up by itself after the next one (laptop run of
    # 2026-11-25 14:33Z).
    Remove-Item -Force -Path $Result -ErrorAction SilentlyContinue
    $script:Previous = Join-Path $Work 'previous-setup.exe'
    try { Copy-Item -Force -Path $Kept -Destination $script:Previous -ErrorAction Stop } catch {
        Log "no Setup of the running version to go back to: $($_.Exception.Message)"
        Save-Result 'failed' 'no-rollback'
        Quit 1
    }
    $script:Trial = [pscustomobject][ordered]@{
        from = $From; to = $Version; setup = $Setup; previous = $script:Previous; program = $Program
        result = $Result; reopen = $Reopen; server = $Server; registered = $Registered
        started = Now-Seconds; until = (Now-Seconds) + $OfflineHours * 3600 + 7200
        phase = 'setup'; reason = ''; resumes = 0
    }
    Save-Trial 'setup'
    Register-Resume
    $code = Run-Setup $Setup 'new'
    Log "new Setup exit code $code"
    Try-New
}

# Dot-sourced (the helper's tests): functions only.
if ($MyInvocation.InvocationName -ne '.') { Main }
