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

# 1. The legacy printer troubleshooter.
if (Test-Path $msdt) {
    $p = Start-Process -FilePath $msdt -ArgumentList '-id PrinterDiagnostic' -PassThru
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 3
        Windows-Now "msdt +$(3 * $i) s"
        [SL]::ShotScreen((Join-Path $Out ("msdt-{0:D2}.png" -f (3 * $i)))) | Out-Null
    }
    foreach ($w in [SL]::Windows()) { if ($w.Proc -in @('msdt', 'sdiagnhost')) { Note "troubleshooter texts: $(Uia-Texts $w.Hwnd)" } }
    Get-Process msdt, sdiagnhost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
