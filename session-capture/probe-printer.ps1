# Which printer faults does Windows itself show as an error? On a GitHub runner only: adds
# throwaway printers with ports that fail in different ways, prints one page to each and logs the
# job and printer status Windows reports, with a picture of each queue window.
#
#   powershell -File session-capture/probe-printer.ps1 -Out <folder>
# Plain ASCII on purpose (Windows PowerShell 5.1).
param([Parameter(Mandatory)] [string] $Out)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'SessionLib.cs')
Add-Type -AssemblyName System.Drawing
Set-Service -Name Spooler -StartupType Automatic
Start-Service -Name Spooler
$driver = 'Generic / Text Only'
if (-not (Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $driver }

$cases = @(
    @{ Name = 'Probe 1 file port, folder missing'; Port = 'C:\NoSuchFolder\probe1.prn' },
    @{ Name = 'Probe 2 tcp refused'; Port = 'Probe2Port'; Host = '127.0.0.1'; Num = 9 },
    @{ Name = 'Probe 3 tcp unreachable'; Port = 'Probe3Port'; Host = '192.0.2.1'; Num = 9100 },
    @{ Name = 'Probe 4 tcp unreachable with SNMP'; Port = 'Probe4Port'; Host = '192.0.2.2'; Num = 9100; Snmp = $true },
    @{ Name = 'Probe 5 paused printer'; Port = 'Probe5Port'; Host = '127.0.0.1'; Num = 9; Pause = $true },
    @{ Name = 'Probe 6 work offline'; Port = 'Probe6Port'; Host = '127.0.0.1'; Num = 9; Offline = $true }
)
foreach ($c in $cases) {
    try {
        if ($c.Host) {
            if ($c.Snmp) { Add-PrinterPort -Name $c.Port -PrinterHostAddress $c.Host -PortNumber $c.Num -SNMP 1 -SNMPCommunity 'public' }
            else { Add-PrinterPort -Name $c.Port -PrinterHostAddress $c.Host -PortNumber $c.Num }
        } else { Add-PrinterPort -Name $c.Port }
        Add-Printer -Name $c.Name -DriverName $driver -PortName $c.Port
        $wp = Get-CimInstance Win32_Printer -Filter "Name='$($c.Name)'"
        if ($c.Pause) { $wp | Invoke-CimMethod -MethodName Pause | Out-Null }
        if ($c.Offline) { $wp.WorkOffline = $true; Set-CimInstance -InputObject $wp }
        $pd = New-Object System.Drawing.Printing.PrintDocument
        $pd.PrinterSettings.PrinterName = $c.Name
        $pd.DocumentName = 'Quote_November.txt'
        $pd.PrintController = New-Object System.Drawing.Printing.StandardPrintController
        $pd.add_PrintPage({ param($sender, $ev) $ev.Graphics.DrawString('Quote for November', (New-Object System.Drawing.Font('Consolas', 11)), [System.Drawing.Brushes]::Black, 100, 100); $ev.HasMorePages = $false })
        $pd.Print()
        Write-Host "PROBE added '$($c.Name)' on $($c.Port)"
    } catch { Write-Host "PROBE '$($c.Name)' set-up failed: $($_.Exception.Message)" }
}
foreach ($t in @(5, 20, 45, 90)) {
    Start-Sleep -Seconds ($t - $(if ($prev) { $prev } else { 0 }))
    $prev = $t
    foreach ($c in $cases) {
        $jobs = @(Get-PrintJob -PrinterName $c.Name -ErrorAction SilentlyContinue)
        $pr = Get-Printer -Name $c.Name -ErrorAction SilentlyContinue
        Write-Host ("PROBE t={0}s '{1}': printer status '{2}', {3} job(s): {4}" -f $t, $c.Name, $pr.PrinterStatus, $jobs.Count, (($jobs | ForEach-Object { "'$($_.JobStatus)'" }) -join ', '))
    }
}
$i = 0
foreach ($c in $cases) {
    $i++
    Start-Process -FilePath rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /o /n `"$($c.Name)`""
    $w = $null
    for ($k = 0; $k -lt 20 -and -not $w; $k++) { Start-Sleep -Milliseconds 500; $w = [SL]::Windows() | Where-Object { $_.Proc -eq 'rundll32' -and $_.Title -like "$($c.Name)*" } | Select-Object -First 1 }
    if ($w) {
        [SL]::Place($w.Hwnd, 100, 100, 1100, 400); [SL]::Front($w.Hwnd); Start-Sleep -Seconds 2
        Write-Host "PROBE window '$($w.Title)': $([SL]::ShotWindow($w.Hwnd, (Join-Path $Out "probe-$i.png")))"
        [SL]::PostClose($w.Hwnd)
    } else { Write-Host "PROBE no queue window for '$($c.Name)'" }
}
Write-Host "PROBE whole screen: $([SL]::ShotScreen((Join-Path $Out 'probe-screen.png')))"
foreach ($w in [SL]::Windows()) { if ($w.Cls -eq '#32770') { Write-Host "PROBE dialog: $w $([SL]::ChildTexts($w.Hwnd))" } }
