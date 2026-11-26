# REMOTE-EASY-5: what the update helper (src/emilli_update/update.ps1) decides in each case of the
# roll-back table, one scenario per process (helper-scenario.ps1: virtual clock, nothing installed,
# no task, no service touched). Run by tests/helper.rs in the crate's cargo test, or directly:
#   pwsh -NoProfile -File ci/emilli-update-tests/helper-tests.ps1      (or powershell on Windows)
# Prints PASS/FAIL per case; exit code = number of failed cases. Plain ASCII.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Forward slashes: these tests also run on Linux (the CI job), and Windows takes them as well.
$helper = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'src/emilli_update/update.ps1'
$scenario = Join-Path $here 'helper-scenario.ps1'
$shell = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ("emilli-helper-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$failed = 0

function Run-Case([string] $Name, [hashtable] $Opts, [hashtable] $Trial = $null) {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'work') | Out-Null
    if ($Trial) {
        $t = [ordered]@{
            from = '1.5.5'; to = '1.5.6'; setup = (Join-Path $dir 'work/Emilli-Remote-Setup-1.5.6.exe'); previous = (Join-Path $dir 'work/previous-setup.exe')
            program = (Join-Path $dir 'prog'); result = (Join-Path $dir 'last-result.json'); reopen = 0; server = '127.0.0.1:21116'; registered = 1
            started = 1800000000; until = 1800000000 + 80 * 3600; phase = 'setup'; reason = ''; resumes = 0
        }
        foreach ($k in $Trial.Keys) { $t[$k] = $Trial[$k] }
        [IO.File]::WriteAllText((Join-Path $dir 'work/trial.json'), ($t | ConvertTo-Json -Compress))
    }
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scenario, '-Dir', $dir, '-Helper', $helper)
    foreach ($k in $Opts.Keys) {
        if ($Opts[$k] -is [bool]) { if ($Opts[$k]) { $args2 += "-$k" } } else { $args2 += @("-$k", [string]$Opts[$k]) }
    }
    $out = & $shell @args2 2>&1 | ForEach-Object { [string]$_ }
    $code = $LASTEXITCODE
    $res = $null
    $rf = Join-Path $dir 'last-result.json'
    if (Test-Path $rf) { $res = Get-Content -Raw $rf | ConvertFrom-Json }
    $skip = $null
    $sf = Join-Path $dir 'skip.json'
    if (Test-Path $sf) { $skip = Get-Content -Raw $sf | ConvertFrom-Json }
    $calls = @(Get-Content -Path (Join-Path $dir 'calls.txt') -ErrorAction SilentlyContinue)
    return @{ code = $code; result = $res; skip = $skip; calls = $calls; trialLeft = (Test-Path (Join-Path $dir 'work/trial.json')); out = $out; log = @(Get-Content -Path (Join-Path $dir 'work/update.log') -ErrorAction SilentlyContinue) }
}
# The virtual second of a call line ("... at 123").
function At($r, [string] $Like) {
    $l = $r.calls | Where-Object { $_ -like $Like } | Select-Object -First 1
    if ($l -and $l -match ' at (-?\d+)$') { return [int]$Matches[1] }
    return $null
}
function Check([string] $Name, [bool] $Ok, $r, [string] $What) {
    if ($Ok) { Write-Host "PASS $Name - $What" }
    else {
        $script:failed++
        Write-Host "FAIL $Name - $What"
        Write-Host "     exit $($r.code); result $(if ($r.result) { $r.result | ConvertTo-Json -Compress } else { 'none' }); skip $(if ($r.skip) { $r.skip.version } else { 'none' }); trial left $($r.trialLeft)"
        $r.calls | ForEach-Object { Write-Host "     call: $_" }
        $r.log | Select-Object -Last 12 | ForEach-Object { Write-Host "     log: $_" }
        $r.out | Select-Object -Last 8 | ForEach-Object { Write-Host "     out: $_" }
    }
}
function Rolled($r, [string] $Reason) { return ($r.code -eq 2 -and $r.result.result -eq 'rolled_back' -and ([string]$r.result.detail).StartsWith($Reason) -and -not $r.trialLeft -and ($r.calls -contains 'task removed')) }
function Kept($r) { return ($r.code -eq 0 -and $r.result.result -eq 'updated' -and $r.result.confirmed -eq 1 -and -not $r.trialLeft -and ($r.calls -contains 'task removed') -and -not ($r.calls | Where-Object { $_ -like 'setup previous*' })) }

try {
    # Row 1: the new version's service does not start.
    $r = Run-Case 'service-does-not-start' @{ NewServiceOk = 0 }
    Check 'row 1 service does not start' ((Rolled $r 'service') -and $r.skip.version -eq '1.5.6') $r 'rolled back (service), 1.5.6 not tried again by itself'

    # Row 2: the service starts and never reaches the ID server, which this helper reaches.
    $r = Run-Case 'never-registers' @{ RegisterAfter = -1 }
    $back = At $r 'setup previous*'
    Check 'row 2 never registers' ((Rolled $r 'unreachable') -and $r.skip.version -eq '1.5.6' -and $back -ge 300 -and $back -lt 420 -and -not ($r.calls | Where-Object { $_ -like 'result updated*' })) $r "rolled back (unreachable) at $back s after the install, no 'updated' said before"

    # Row 3: registers, then loses its server within the ten minutes (server reachable).
    $r = Run-Case 'registers-then-loses' @{ RegisterAfter = 20; LoseAt = 200; LoseFor = 100000 }
    $back = At $r 'setup previous*'
    $interim = At $r 'result updated (registered)*'
    Check 'row 3 registers then loses it' ((Rolled $r 'lost') -and $r.skip.version -eq '1.5.6' -and $null -ne $interim -and $back -ge 380 -and $back -lt 500) $r "said 'updated' at $interim s, rolled back (lost) at $back s"

    # Row 3, the other side: a gap shorter than three minutes is not a loss.
    $r = Run-Case 'short-gap' @{ RegisterAfter = 20; LoseAt = 200; LoseFor = 90 }
    Check 'row 3 a short gap is kept' ((Kept $r) -and -not $r.skip) $r 'updated and confirmed after the hold, no roll back'

    # Rows 2 and 3 with no connection at all: not a failed update.
    $r = Run-Case 'offline-then-back' @{ RegisterAfter = 20; OfflineFrom = 0; OfflineTo = 7200 }
    $done = At $r 'exit 0*'
    Check 'offline for two hours, then registers' ((Kept $r) -and -not $r.skip -and $done -ge 7800) $r "kept and confirmed at $done s (the clocks waited while offline)"
    $r = Run-Case 'offline-during-hold' @{ RegisterAfter = 20; OfflineFrom = 200; OfflineTo = 4000 }
    Check 'offline during the hold' ((Kept $r) -and -not $r.skip) $r 'kept: an hour offline in the hold is not a loss'
    $r = Run-Case 'offline-for-days' @{ RegisterAfter = 20; OfflineFrom = 0; OfflineTo = 400000 }
    Check 'offline for 72 hours' ($r.code -eq 0 -and $r.result.result -eq 'updated' -and ([string]$r.result.detail) -like 'not confirmed*' -and -not $r.skip -and -not ($r.calls | Where-Object { $_ -like 'setup previous*' })) $r "kept, not confirmed ($($r.result.detail))"

    # The working update: says 'updated' when registered, confirms after the hold.
    $r = Run-Case 'works' @{ RegisterAfter = 20 }
    $interim = At $r 'result updated (registered)*'
    $done = At $r 'exit 0*'
    Check 'a working version' ((Kept $r) -and $interim -ge 20 -and $interim -lt 60 -and $done -ge 600 -and $done -lt 700 -and $r.result.reopen -eq 1) $r "said 'updated' at $interim s, confirmed at $done s"

    # The previous version was not registered either: only the service is checked.
    $r = Run-Case 'previous-not-registered' @{ WasRegistered = 0; RegisterAfter = -1 }
    Check 'previous version not registered' ($r.code -eq 0 -and $r.result.result -eq 'updated' -and ([string]$r.result.detail) -like '*registration not checked*' -and -not $r.skip) $r 'updated, registration not required'

    # Row 4: a restart in the middle.
    $r = Run-Case 'restart-in-setup' @{ AsResume = $true; StartInstalled = 'unknown'; RegisterAfter = 20 } @{ phase = 'setup' }
    Check 'restart during the Setup' ((Kept $r) -and ($r.calls | Where-Object { $_ -like 'setup new-again*' })) $r 'the new Setup runs again, then the trial; updated'
    $r = Run-Case 'restart-in-hold' @{ AsResume = $true; StartInstalled = 'new'; RegisterAfter = 30 } @{ phase = 'hold' }
    Check 'restart during the hold' ((Kept $r) -and -not ($r.calls | Where-Object { $_ -like 'setup new*' })) $r 'the trial starts again from the service; updated'
    $r = Run-Case 'restart-broken-after' @{ AsResume = $true; StartInstalled = 'new'; RegisterAfter = -1 } @{ phase = 'register' }
    Check 'restart, then never registers' ((Rolled $r 'unreachable') -and $r.skip.version -eq '1.5.6') $r 'rolled back (unreachable) after the restart'
    $r = Run-Case 'restart-in-rollback' @{ AsResume = $true; StartInstalled = 'unknown' } @{ phase = 'rollback'; reason = 'service' }
    Check 'restart during the roll back' ((Rolled $r 'service') -and -not $r.skip -and ($r.calls | Where-Object { $_ -like 'setup previous*' })) $r 'the roll back is finished'
    $r = Run-Case 'restarts-keep-coming' @{ AsResume = $true; StartInstalled = 'new'; RegisterAfter = 20 } @{ phase = 'hold'; resumes = 3 }
    Check 'a fourth restart in one trial' ((Rolled $r 'interrupted') -and -not $r.skip) $r 'previous version back, no skip'
    $r = Run-Case 'resume-without-trial' @{ AsResume = $true }
    Check 'start-up task with no trial' ($r.code -eq 0 -and -not $r.result -and ($r.calls -contains 'task removed')) $r 'nothing done, the task removed'

    # Row 6: two updates one after the other: while one is tried, another does not start.
    $r = Run-Case 'second-update-while-trying' @{ RegisterAfter = 20 } @{ phase = 'hold'; until = 4000000000 }
    Check 'a second update while one is tried' ($r.code -eq 4 -and -not $r.result -and -not ($r.calls | Where-Object { $_ -like 'setup*' }) -and $r.trialLeft) $r 'refused, nothing installed, the first trial left alone'

    # No Setup of the running version to go back to: nothing is installed.
    $r = Run-Case 'no-kept-setup' @{ NoKept = $true }
    Check 'no Setup to go back to' ($r.code -eq 1 -and $r.result.result -eq 'failed' -and $r.result.detail -eq 'no-rollback' -and -not ($r.calls | Where-Object { $_ -like 'setup*' })) $r 'failed (no-rollback), nothing installed'
} finally {
    Remove-Item -Recurse -Force -Path $root -ErrorAction SilentlyContinue
}
Write-Host "helper tests: $failed failed"
exit $failed
