# CI test for Emilli Remote Setup, run on a fresh GitHub "windows-latest" runner only.
# It installs and uninstalls RustDesk and deletes RustDesk's settings folders, so never run
# it on a PC that matters.
#
#   pwsh windows-easy/test-easy-setup.ps1 -Mode store   -Setup <setup.exe> -Work <folder>
#   pwsh windows-easy/test-easy-setup.ps1 -Mode control -Setup <setup.exe> -Work <folder>
#
# One run: clean start, silent Setup, then checks of the service, both settings files
# (service profile and the runner's own profile), the store PC password, --get-id and the
# Setup log; then RustDesk's own uninstall and removal of its settings folders, so the next
# mode starts clean. Every check prints PASS or FAIL; the script fails if any check failed.
param(
    [Parameter(Mandatory)] [ValidateSet('store', 'control')] [string] $Mode,
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Work
)
$ErrorActionPreference = 'Stop'

$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$UserRoot = Join-Path $env:APPDATA 'RustDesk'
$Key = 'EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A='
$Py = Join-Path $PSScriptRoot 'check_rustdesk_config.py'
$script:Passed = 0
$script:Failed = 0

function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) { $script:Passed++; $word = 'PASS' } else { $script:Failed++; $word = 'FAIL' }
    Write-Host ("{0} [{1}] {2} {3}" -f $word, $Mode, $Name, $Detail)
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds 1
    }
    return [bool](& $Condition)
}

function Read-Options([string] $File) {
    if (-not (Test-Path $File)) { return $null }
    return (& python -I $Py options $File | ConvertFrom-Json)
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$log = Join-Path $Work "setup-$Mode.log"
$idFile = Join-Path $Work "id-$Mode.txt"
$pwFile = Join-Path $Work "pw-$Mode.txt"

# 0. Clean start.
Check 'clean start: RustDesk not installed' (-not (Test-Path $Exe))
Check 'clean start: no RustDesk service' ($null -eq (Get-Service RustDesk -ErrorAction SilentlyContinue))
Check 'clean start: no settings folders' (-not (Test-Path $SvcRoot) -and -not (Test-Path $UserRoot))

# 1. Silent Setup.
$argList = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/MODE=$Mode", "/IDFILE=$idFile", "/LOG=$log")
$pw = ''
if ($Mode -eq 'store') {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+-=?@'
    $pw = -join (1..20 | ForEach-Object { $chars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] })
    [System.IO.File]::WriteAllText($pwFile, $pw)
    $argList += "/PWFILE=$pwFile"
}
$watch = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Setup -ArgumentList $argList -Wait -PassThru
Check 'Setup exit code 0' ($proc.ExitCode -eq 0) "(exit $($proc.ExitCode), $([int]$watch.Elapsed.TotalSeconds) s)"
if (Test-Path $log) {
    Write-Host "--- Setup log lines from Emilli Remote Setup ---"
    Select-String -Path $log -SimpleMatch 'Emilli:' | ForEach-Object { Write-Host $_.Line }
    Write-Host "---"
}

# 2. Installed, and the service runs.
Check 'rustdesk.exe installed' (Test-Path $Exe)
$svc = Get-Service RustDesk -ErrorAction SilentlyContinue
Check 'service RustDesk running' ($null -ne $svc -and $svc.Status -eq 'Running') "(status $($svc.Status))"
Check 'service starts automatically' ($null -ne $svc -and $svc.StartType -eq 'Automatic') "(start $($svc.StartType))"

# 3. Our server in both settings files.
foreach ($where in @(@('service profile', $SvcRoot), @('runner user profile', $UserRoot))) {
    $file = Join-Path $where[1] 'config\RustDesk2.toml'
    $o = Read-Options $file
    Check "$($where[0]): RustDesk2.toml exists" ($null -ne $o) "($file)"
    if ($null -eq $o) { continue }
    Check "$($where[0]): ID server rd.emillis.net" ($o.'custom-rendezvous-server' -eq 'rd.emillis.net') "('$($o.'custom-rendezvous-server')')"
    Check "$($where[0]): API server https://rd.emillis.net" ($o.'api-server' -eq 'https://rd.emillis.net') "('$($o.'api-server')')"
    Check "$($where[0]): server key" ($o.key -eq $Key) "('$($o.key)')"
    Check "$($where[0]): relay empty" ([string]::IsNullOrEmpty($o.'relay-server')) "('$($o.'relay-server')')"
}
$svcOpts = Read-Options (Join-Path $SvcRoot 'config\RustDesk2.toml')
$svcMain = Join-Path $SvcRoot 'config\RustDesk.toml'

# 4. Password and password mode.
if ($Mode -eq 'store') {
    Check 'service: verification-method use-permanent-password' ($svcOpts.'verification-method' -eq 'use-permanent-password') "('$($svcOpts.'verification-method')')"
    Check 'service: approve-mode password' ($svcOpts.'approve-mode' -eq 'password') "('$($svcOpts.'approve-mode')')"
    $m = & python -I $Py main $svcMain $pwFile | ConvertFrom-Json
    Check 'service: permanent password stored' ([bool]$m.password_set)
    Check 'service: stored password matches the one given to Setup' ([bool]$m.password_match) "(error '$($m.password_error)')"
    Check 'service: a wrong password does not match' (-not [bool]$m.wrong_password_match)
    $hits = @(Select-String -Path $log -SimpleMatch -Pattern $pw).Count
    Check 'Setup log does not contain the password' ($hits -eq 0) "($hits hits)"
} else {
    Check 'service: password mode left at default' ([string]::IsNullOrEmpty($svcOpts.'verification-method') -and [string]::IsNullOrEmpty($svcOpts.'approve-mode')) "('$($svcOpts.'verification-method')', '$($svcOpts.'approve-mode')')"
    $m = & python -I $Py main $svcMain | ConvertFrom-Json
    Check 'service: no permanent password' (-not [bool]$m.password_set)
}

# 5. The ID: --get-id, the ID Setup reported, and the ID stored by the service agree.
$getId = (& $Exe --get-id | Out-String).Trim()
Check '--get-id prints an ID' ($getId -match '^\d{6,12}$') "('$getId')"
$setupId = if (Test-Path $idFile) { (Get-Content $idFile -Raw).Trim() } else { '' }
Check 'Setup reported the same ID' ($setupId -eq $getId) "('$setupId')"
Check 'service settings hold the same ID' ($m.id -eq $getId) "('$($m.id)', error '$($m.id_error)')"

# 6. Uninstall with RustDesk's own uninstaller, then remove its settings for a clean next run.
Start-Process -FilePath $Exe -ArgumentList '--uninstall' -Wait
$gone = Wait-Until { -not (Test-Path $Exe) -and $null -eq (Get-Service RustDesk -ErrorAction SilentlyContinue) } 120
Check 'uninstall removed rustdesk.exe and the service' $gone
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
foreach ($dir in @($SvcRoot, $UserRoot)) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}
Check 'settings folders removed' (-not (Test-Path $SvcRoot) -and -not (Test-Path $UserRoot))
Remove-Item -Force -ErrorAction SilentlyContinue $pwFile

Write-Host ("RESULT [{0}] passed {1}, failed {2}" -f $Mode, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
