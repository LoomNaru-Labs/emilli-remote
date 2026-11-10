# Round 3, hypothesis B (brief REMOTE-SESSION-CAPTURE-3): does Windows' own printer troubleshooter
# (the legacy one, msdt.exe with the printer pack, or its replacement in Get Help) still run on
# this runner image, and what does it show? Also checks what the "Printers" shortcut of the take
# opens. A fresh GitHub runner only. Plain ASCII (Windows PowerShell 5.1).
param([Parameter(Mandatory)] [string] $Out)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $PSScriptRoot 'SessionLib.cs')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Note([string] $m) { Write-Host "  $m" }
function Windows-Now([string] $When) {
    foreach ($w in [SL]::Windows()) {
        if ($w.Width -gt 50 -and $w.Proc -notin @('explorer') -or $w.Cls -eq 'CabinetWClass') { Note "window ($When): $w $([SL]::ChildTexts($w.Hwnd))" }
    }
}
function Uia-Texts([IntPtr] $h) {
    try {
        $all = [System.Windows.Automation.AutomationElement]::FromHandle($h).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        return (($all | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -Unique -First 60) -join ' | ')
    } catch { return "(UI Automation: $($_.Exception.Message))" }
}

Note "Windows $([Environment]::OSVersion.VersionString); $((Get-CimInstance Win32_OperatingSystem).Caption) build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
$msdt = Join-Path $env:windir 'System32\msdt.exe'
Note "msdt.exe present: $(Test-Path $msdt)"
Note "troubleshooting packs in diagnostics\system: $((Get-ChildItem (Join-Path $env:windir 'diagnostics\system') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')"
Note "Get Help app: $((Get-AppxPackage -AllUsers -Name '*GetHelp*' -ErrorAction SilentlyContinue | ForEach-Object PackageFullName) -join ', ')"
Note "printers: $((Get-Printer | ForEach-Object Name) -join ', ')"

# 1. The legacy printer troubleshooter, run through to its result against a real stuck job (the
#    take's problem: a default printer whose port does not answer, a job in error).
$drv = 'Microsoft Print To PDF'
try { if (-not (Get-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name 'Generic / Text Only' }; $drv = 'Generic / Text Only' } catch { }
Add-PrinterPort -Name 'ProbeDeadPort' -PrinterHostAddress '127.0.0.1' -PortNumber 9
Add-Printer -Name 'Old Receipt Printer' -DriverName $drv -PortName 'ProbeDeadPort'
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord
Get-CimInstance Win32_Printer -Filter "Name='Old Receipt Printer'" | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null
'Receipt 0412' | Out-Printer -Name 'Old Receipt Printer'
$end = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $end -and -not ("$((Get-PrintJob -PrinterName 'Old Receipt Printer' -ErrorAction SilentlyContinue | Select-Object -First 1).JobStatus)" -match 'Error')) { Start-Sleep -Seconds 2 }
Note "stuck job: $(@(Get-PrintJob -PrinterName 'Old Receipt Printer' | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', ')"
if (Test-Path $msdt) {
    $p = Start-Process -FilePath $msdt -ArgumentList '-id PrinterDiagnostic' -PassThru
    $A = [System.Windows.Automation.AutomationElement]
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep -Seconds 6
        $w = [SL]::Windows() | Where-Object { $_.Proc -eq 'msdt' -and $_.Width -gt 200 } | Select-Object -First 1
        [SL]::ShotScreen((Join-Path $Out ("msdt-page-{0:D2}.png" -f $i))) | Out-Null
        if (-not $w) { Note "page $i`: no troubleshooter window"; break }
        Note "page $i`: $w; texts: $(Uia-Texts $w.Hwnd)"
        # A list of printers: choose ours.
        try {
            $item = $A::FromHandle($w.Hwnd).FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, 'Old Receipt Printer')))
            if ($item) {
                $pat = $null
                if ($item.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pat)) { $pat.Select(); Note "  chose 'Old Receipt Printer'" }
            }
        } catch { Note "  choice: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 500
        $n = [SL]::ClickButton($w.Hwnd, 'Next')
        if ($n -eq 0) { $n = [SL]::ClickButton($w.Hwnd, 'Close') ; if ($n -gt 0) { Note '  Close'; break } }
        else { Note '  Next' }
    }
    Get-Process msdt, sdiagnhost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Note "after the troubleshooter: $(@(Get-PrintJob -PrinterName 'Old Receipt Printer' -ErrorAction SilentlyContinue | ForEach-Object { "'$($_.DocumentName)' $($_.JobStatus)" }) -join ', '); Spooler $((Get-Service Spooler).Status)"
}
# 2. The Settings route (Troubleshoot, Printer) and Get Help.
Start-Process 'ms-settings:troubleshoot' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
Windows-Now 'settings troubleshoot'
[SL]::ShotScreen((Join-Path $Out 'settings-troubleshoot.png')) | Out-Null
foreach ($w in [SL]::Windows()) { if ($w.Proc -eq 'ApplicationFrameHost' -or $w.Title -like '*Settings*') { Note "settings texts: $(Uia-Texts $w.Hwnd)" } }
Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# 3. What the take's "Printers" shortcut opens.
Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList 'shell:::{2227A280-3AEA-1069-A2DE-08002B30309D}'
Start-Sleep -Seconds 6
Windows-Now 'printers folder'
[SL]::ShotScreen((Join-Path $Out 'printers-folder.png')) | Out-Null
foreach ($w in [SL]::Windows()) { if ($w.Cls -eq 'CabinetWClass') { Note "Explorer window '$($w.Title)': $(Uia-Texts $w.Hwnd)" } }
Write-Host 'RESULT probe done'
