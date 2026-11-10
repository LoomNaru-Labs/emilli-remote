# Printer check: a plain support script that a helper starts on the store PC (brief
# REMOTE-SESSION-CAPTURE-3, item 2). It is not a part of Emilli Remote. It really asks Windows
# about the print service, the printers, their ports and their queues, shows each step as it
# finishes, and ends with what it found, built from those answers (no fixed text). Each step
# stays on screen at least -StepMs so a viewer can read it. Everything it saw also goes to -Log
# (JSON) for the run's evidence. Used on a GitHub runner only. Plain ASCII (Windows PowerShell 5.1).
param(
    [int] $X = 960, [int] $Y = 16, [int] $W = 940, [int] $H = 780,
    [string] $Log = 'C:\sc\out\check.json',
    [int] $StepMs = 650
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CheckDpi {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    public static int Dpi() {
        POINT p = new POINT(); uint x, y;
        return GetDpiForMonitor(MonitorFromPoint(p, 1), 0, out x, out y) == 0 ? (int)x : 96;
    }
}
'@
# Windows made by this thread draw at the screen's real scale (sharp at 175 %).
[CheckDpi]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$f = [CheckDpi]::Dpi() / 96.0
function Px([double] $v) { return [int][Math]::Round($v * $f) }
function NewFont([double] $size, [switch] $Bold, [string] $Face = 'Segoe UI') {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($Face, [single](Px $size), $style, [System.Drawing.GraphicsUnit]::Pixel)
}

$Green = [System.Drawing.Color]::FromArgb(16, 124, 16)
$Red = [System.Drawing.Color]::FromArgb(196, 43, 28)
$Ink = [System.Drawing.Color]::FromArgb(32, 32, 32)
$Grey = [System.Drawing.Color]::FromArgb(96, 96, 96)
$Ok = [string][char]0x2714
$Bad = [string][char]0x2716
$Info = [string][char]0x2022

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Printer check'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.Size = New-Object System.Drawing.Size($W, $H)
$form.ShowIcon = $false

$m = Px 18
$cw = $form.ClientSize.Width - 2 * $m
function Add-Label([string] $text, $font, $color, [int] $top, [int] $height, [int] $left = $m, [int] $width = $cw) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point($left, $top); $l.Size = New-Object System.Drawing.Size($width, $height)
    $form.Controls.Add($l)
    return $l
}
$y0 = Px 12
Add-Label 'Printer check' (NewFont 24 -Bold) $Ink $y0 (Px 34) | Out-Null
$status = Add-Label 'Starting ...' (NewFont 14) $Grey ($y0 + (Px 36)) (Px 22)
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$bar.Location = New-Object System.Drawing.Point($m, ($y0 + (Px 62)))
$bar.Size = New-Object System.Drawing.Size($cw, (Px 12))
$bar.Minimum = 0; $bar.Maximum = 6; $bar.Value = 0
$form.Controls.Add($bar)
$lineTop = $y0 + (Px 86)
$lineH = Px 28
$marks = @(); $texts = @()
for ($i = 0; $i -lt 6; $i++) {
    $marks += Add-Label '' (NewFont 17 -Face 'Segoe UI Symbol') $Ink ($lineTop + $i * $lineH) $lineH $m (Px 26)
    $texts += Add-Label '' (NewFont 17) $Ink ($lineTop + $i * $lineH) $lineH ($m + (Px 28)) ($cw - (Px 28))
}
$findTop = $lineTop + 6 * $lineH + (Px 8)
$finding = Add-Label '' (NewFont 21 -Bold) $Red $findTop (Px 84)
$ready = Add-Label '' (NewFont 17) $Green ($findTop + (Px 86)) (Px 26)

$form.Show()
$form.Activate()
$form.Refresh()

function Pump([int] $ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } while ((Get-Date) -lt $end)
}

# Whether something answers on the printer's network port (a plain connection, no data sent).
function Test-Answer([string] $HostName, [int] $Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(900)) { return $false }
        $c.EndConnect($iar)
        return $c.Connected
    } catch { return $false } finally { $c.Close() }
}
function PortOf([string] $PortName) {
    $p = Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue
    if ($p -and $p.PrinterHostAddress) { return @($p.PrinterHostAddress, [int]$p.PortNumber) }
    return $null
}

$rec = [ordered]@{ started = (Get-Date).ToString('o'); steps = @() }
$script:k = 0
function Step-Show([string] $checking, [scriptblock] $work) {
    $t0 = Get-Date
    $status.Text = "Checking $checking ..."
    Pump 120
    $r = & $work
    $left = $StepMs - [int]((Get-Date) - $t0).TotalMilliseconds
    if ($left -gt 0) { Pump $left }
    $marks[$script:k].Text = if ($r.ok -eq $true) { $Ok } elseif ($r.ok -eq $false) { $Bad } else { $Info }
    $marks[$script:k].ForeColor = if ($r.ok -eq $true) { $Green } elseif ($r.ok -eq $false) { $Red } else { $Ink }
    $texts[$script:k].Text = $r.text
    $texts[$script:k].ForeColor = if ($r.ok -eq $false) { $Red } else { $Ink }
    $script:k++
    $bar.Value = $script:k
    $rec.steps += [ordered]@{ at = (Get-Date).ToString('o'); shown = $r.text; ok = $r.ok; raw = $r.raw }
    Pump 60
}

$S = @{}
Step-Show 'the print service' {
    $svc = Get-Service -Name Spooler
    $S.Spooler = "$($svc.Status)"
    @{ ok = ($svc.Status -eq 'Running'); text = "Print service: $("$($svc.Status)".ToLower())"; raw = "Spooler $($svc.Status), start type $($svc.StartType)" }
}
Step-Show 'the printers' {
    $S.Printers = @(Get-Printer | Sort-Object Name)
    $names = ($S.Printers | ForEach-Object { "$($_.Name) [$($_.PrinterStatus), port $($_.PortName)]" }) -join '; '
    @{ ok = ($S.Printers.Count -gt 0); text = "Printers installed: $($S.Printers.Count)"; raw = $names }
}
Step-Show 'the default printer' {
    $d = Get-CimInstance Win32_Printer -Filter 'Default=TRUE' | Select-Object -First 1
    $S.Default = if ($d) { $d.Name } else { '' }
    @{ ok = $null; text = "Default printer: $(if ($S.Default) { $S.Default } else { 'none' })"; raw = "Win32_Printer Default=TRUE: '$($S.Default)'" }
}
Step-Show 'whether the default printer answers' {
    $dp = $S.Printers | Where-Object { $_.Name -eq $S.Default } | Select-Object -First 1
    $hp = if ($dp) { PortOf $dp.PortName } else { $null }
    $S.DefaultAnswers = if ($hp) { Test-Answer $hp[0] $hp[1] } else { $null }
    $txt = if ($S.DefaultAnswers -eq $true) { 'yes' } elseif ($S.DefaultAnswers -eq $false) { 'no' } else { 'not a network printer' }
    @{ ok = $S.DefaultAnswers; text = "Default printer answers: $txt"; raw = "port $($dp.PortName) $(if ($hp) { "$($hp[0]):$($hp[1])" }) answers=$($S.DefaultAnswers); printer status $($dp.PrinterStatus)" }
}
Step-Show 'its print queue' {
    $S.Jobs = @(Get-PrintJob -PrinterName $S.Default -ErrorAction SilentlyContinue)
    $S.Stuck = @($S.Jobs | Where-Object { "$($_.JobStatus)" -match 'Error|Paused|Blocked|Offline' })
    $txt = if ($S.Jobs.Count -eq 0) { 'empty' } elseif ($S.Stuck.Count -gt 0) { "$($S.Stuck.Count) stuck (status $(("$($S.Stuck[0].JobStatus)" -split ',')[0].Trim()))" } else { "$($S.Jobs.Count) waiting" }
    $raw = ($S.Jobs | ForEach-Object { "job $($_.Id) '$($_.DocumentName)' $($_.JobStatus), submitted $($_.SubmittedTime)" }) -join '; '
    @{ ok = ($S.Stuck.Count -eq 0); text = "Jobs in its queue: $txt"; raw = "Get-PrintJob '$($S.Default)': $(if ($raw) { $raw } else { 'none' })" }
}
Step-Show 'the other printers' {
    $S.Ready = @()
    $raws = @()
    foreach ($p in ($S.Printers | Where-Object { $_.Name -ne $S.Default })) {
        $hp = PortOf $p.PortName
        if (-not $hp) { $raws += "$($p.Name): not a network printer"; continue }
        $a = Test-Answer $hp[0] $hp[1]
        $raws += "$($p.Name): port $($hp[0]):$($hp[1]) answers=$a"
        if ($a) { $S.Ready += $p.Name }
    }
    $txt = if ($S.Ready.Count -gt 0) { ($S.Ready -join ', ') + ' answers' } else { 'none answers' }
    @{ ok = ($S.Ready.Count -gt 0); text = "Other printers: $txt"; raw = ($raws -join '; ') }
}

# The finding, from the answers above.
if ($S.Spooler -ne 'Running') { $found = 'Found: the print service is not running, so nothing prints.' }
elseif ($S.Stuck.Count -gt 0 -and $S.DefaultAnswers -eq $false) {
    $found = "Found: $($S.Stuck.Count) job stuck in the queue of $($S.Default). That printer does not answer, so the job blocks printing."
} elseif ($S.DefaultAnswers -eq $false) { $found = "Found: the default printer, $($S.Default), does not answer." }
elseif ($S.Stuck.Count -gt 0) { $found = "Found: $($S.Stuck.Count) job stuck in the queue of $($S.Default)." }
else { $found = 'No problem found.' }
$status.Text = 'Check finished.'
$finding.Text = $found
if ($found -like 'No problem*') { $finding.ForeColor = $Green }
if ($S.Ready.Count -gt 0 -and $found -notlike 'No problem*') { $ready.Text = (($S.Ready -join ', ') + $(if ($S.Ready.Count -eq 1) { ' is ready.' } else { ' are ready.' })) }
$form.Refresh()
$rec.finished = (Get-Date).ToString('o')
$rec.finding = $found
$rec.ready = $ready.Text
try {
    ($rec | ConvertTo-Json -Depth 5) | Set-Content -Path $Log -Encoding ASCII
    Set-Content -Path ($Log -replace '\.json$', '-done.txt') -Value $rec.finished -Encoding ASCII
} catch { }
[System.Windows.Forms.Application]::Run($form)
