# REMOTE-EASY-5: one scenario of the update helper (src/emilli_update/update.ps1), run by
# helper-tests.ps1 in its own process. The helper is dot-sourced here, at this file's top level (so
# its script-scope variables are this file's), and everything that would touch the PC is replaced:
# the clock is virtual (Wait-Poll moves it, nothing sleeps), Setups only switch which version is
# "installed", the service, the registration and the ID server answer as the scenario says, and no
# task is registered. Every call that matters is written to <Dir>/calls.txt; the helper's own files
# (result, skip, trial, log) land under <Dir>. Plain ASCII (Windows PowerShell 5.1 and PowerShell 7).
param(
    [Parameter(Mandatory)] [string] $Dir,
    [Parameter(Mandatory)] [string] $Helper,
    [int] $NewServiceOk = 1,
    [int] $RegisterAfter = 20,
    [int] $LoseAt = -1,
    [int] $LoseFor = 0,
    [int] $OfflineFrom = -1,
    [int] $OfflineTo = -1,
    [int] $WasRegistered = 1,
    [string] $StartInstalled = 'old',
    [switch] $AsResume,
    [switch] $NoKept
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'work'), (Join-Path $Dir 'prog') | Out-Null
$kept = Join-Path $Dir 'kept.exe'
if (-not $NoKept) { [IO.File]::WriteAllText($kept, 'kept setup') }
$newSetup = Join-Path $Dir 'work/Emilli-Remote-Setup-1.5.6.exe'
[IO.File]::WriteAllText($newSetup, 'new setup')
$Calls = Join-Path $Dir 'calls.txt'
function Call([string] $m) { Add-Content -Path $Calls -Value $m }

if ($AsResume) {
    . $Helper -Resume
} else {
    . $Helper -Setup $newSetup -Version '1.5.6' -From '1.5.5' -Kept $kept -Program (Join-Path $Dir 'prog') -Result (Join-Path $Dir 'last-result.json') -Reopen 1 -Server '127.0.0.1:21116' -Registered $WasRegistered
}
$ErrorActionPreference = 'Continue'
# The helper's own files go under this scenario's folder (with -Resume it would use its own folder).
$Work = Join-Path $Dir 'work'
$Log = Join-Path $Work 'update.log'
$TrialFile = Join-Path $Work 'trial.json'

$script:T = 1800000000
$script:Installed = $StartInstalled
$script:InstalledAt = $script:T
function Now-Seconds { return $script:T }
function Wait-Poll([int] $Seconds) { $script:T += $Seconds }
function Rel { return ($script:T - $script:InstalledAt) }
function Offline { $r = Rel; return ($OfflineFrom -ge 0 -and $r -ge $OfflineFrom -and $r -lt $OfflineTo) }
function Run-Setup([string] $File, [string] $Tag) {
    Call "setup $Tag at $(Rel)"
    $script:T += 30
    if ($Tag -like 'new*') { $script:Installed = 'new'; $script:InstalledAt = $script:T }
    elseif ($Tag -eq 'previous') { $script:Installed = 'old' }
    return 0
}
function Healthy([string] $Want) {
    $script:T += 5
    if ($Want -eq '1.5.6') { return ($script:Installed -eq 'new' -and $NewServiceOk -eq 1) }
    return ($script:Installed -eq 'old')
}
function Probe-Registered {
    $script:T += 1
    if ($script:Installed -ne 'new' -or (Offline) -or $RegisterAfter -lt 0) { return $false }
    $r = Rel
    if ($r -lt $RegisterAfter) { return $false }
    if ($LoseAt -ge 0 -and $r -ge $LoseAt -and $r -lt ($LoseAt + $LoseFor)) { return $false }
    return $true
}
function Probe-Server { $script:T += 1; return (-not (Offline)) }
function Program-Version { if ($script:Installed -eq 'new') { return '1.5.6' } elseif ($script:Installed -eq 'old') { return '1.5.5' } else { return '' } }
function Service-Status { return 'Running' }
function Register-Resume { Call 'task registered' }
function Unregister-Resume { Call 'task removed' }
$saveResult = ${function:Save-Result}
function Save-Result { Call "result $($args[0]) ($($args[1])) at $(Rel)"; & $saveResult @args }
function Quit([int] $Code) { Call "exit $Code at $(Rel)"; exit $Code }

Main
Call 'main returned'
exit 9
