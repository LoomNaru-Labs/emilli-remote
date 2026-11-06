# Screenshots of Emilli Remote Setup for the Emilli Remote manual, taken on a fresh GitHub
# "windows-latest" runner only. It runs the Setup interactively (not silent), clicks through
# it, installs and uninstalls RustDesk and deletes RustDesk's settings folders, so never run it
# on a PC that matters.
#
#   powershell -File windows-easy/capture-easy-setup.ps1 -Mode store   -Lang ko -Setup <setup.exe> -Out <folder> -Tag ko
#   powershell -File windows-easy/capture-easy-setup.ps1 -Mode control -Lang en -Setup <setup.exe> -Out <folder> -Tag en@2x
#
# Every page is saved twice: the Setup window alone (<Out>\win-<mode>-NN-<page>-<tag>.png)
# and the whole screen (<Out>\full\...). The store PC password is a random dummy that is never
# printed. This file is plain ASCII on purpose: Windows PowerShell 5.1 reads scripts without a
# byte order mark as ANSI, so controls are found by type and position, not by Korean text.
param(
    [Parameter(Mandatory)] [ValidateSet('store', 'control')] [string] $Mode,
    [Parameter(Mandatory)] [ValidateSet('ko', 'en')] [string] $Lang,
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Out,
    [Parameter(Mandatory)] [string] $Tag
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class Cap {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);

    // Physical pixels for every call, whatever the display scale.
    static void Aware() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

    public static RECT Frame(IntPtr h) {
        Aware();
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
        return r;
    }

    public static void Front(IntPtr h) {
        Aware();
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0043);
        SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0043);
        SetForegroundWindow(h);
    }

    // The window as it is on screen (its visible frame, no shadow), cut from the screen so a
    // window that is busy and not repainting never blocks the capture.
    public static string ShotWindow(IntPtr h, string path) {
        Aware();
        RECT r = Frame(h);
        int sx = GetSystemMetrics(76), sy = GetSystemMetrics(77), sw = GetSystemMetrics(78), sh = GetSystemMetrics(79);
        int left = Math.Max(r.Left, sx), top = Math.Max(r.Top, sy);
        int right = Math.Min(r.Right, sx + sw), bottom = Math.Min(r.Bottom, sy + sh);
        int w = right - left, hh = bottom - top;
        if (w <= 0 || hh <= 0) return "window not on screen";
        using (Bitmap b = new Bitmap(w, hh, PixelFormat.Format24bppRgb)) {
            using (Graphics g = Graphics.FromImage(b)) g.CopyFromScreen(left, top, 0, 0, new Size(w, hh));
            b.Save(path, ImageFormat.Png);
        }
        return w + "x" + hh + " at " + left + "," + top + ", window dpi " + GetDpiForWindow(h);
    }

    public static string ShotScreen(string path) {
        Aware();
        int sx = GetSystemMetrics(76), sy = GetSystemMetrics(77), sw = GetSystemMetrics(78), sh = GetSystemMetrics(79);
        using (Bitmap b = new Bitmap(sw, sh, PixelFormat.Format24bppRgb)) {
            using (Graphics g = Graphics.FromImage(b)) g.CopyFromScreen(sx, sy, 0, 0, new Size(sw, sh));
            b.Save(path, ImageFormat.Png);
        }
        return sw + "x" + sh;
    }

    // A button or radio button click as the control's own BN_CLICKED notification, posted so
    // a click that starts the installation never blocks this script.
    public static void Click(IntPtr control) {
        PostMessage(GetParent(control), 0x0111, new IntPtr(GetDlgCtrlID(control) & 0xFFFF), control);
    }

    public static void SetText(IntPtr edit, string text) { SendMessage(edit, 0x000C, IntPtr.Zero, text); }

    public static IntPtr[] TopWindows(string cls, int[] pids) {
        List<IntPtr> list = new List<IntPtr>();
        HashSet<uint> set = new HashSet<uint>();
        if (pids != null) foreach (int p in pids) set.Add((uint)p);
        EnumWindows(new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256);
            if ((cls == null || s.ToString() == cls) && (pids == null || set.Contains(pid))) list.Add(h);
            return true;
        }), IntPtr.Zero);
        return list.ToArray();
    }
}
'@

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$Exe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SvcRoot = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk'
$UserRoot = Join-Path $env:APPDATA 'RustDesk'
$script:Step = 0
$script:Problems = 0

New-Item -ItemType Directory -Force -Path $Out, (Join-Path $Out 'full') | Out-Null
$log = Join-Path $Out "setup-$Mode-$Tag.log"

function Note([string] $Text) { Write-Host ("[{0}] {1}" -f $Mode, $Text) }
function Problem([string] $Text) { $script:Problems++; Write-Host ("PROBLEM [{0}] {1}" -f $Mode, $Text) }

function Wait-For([scriptblock] $Probe, [int] $Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { $r = & $Probe } catch { $r = $null }
        if ($r) { return $r }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Shot([IntPtr] $Window, [string] $Page) {
    $script:Step++
    $name = 'win-{0}-{1:00}-{2}-{3}.png' -f $Mode, $script:Step, $Page, $Tag
    [Cap]::Front($Window)
    Start-Sleep -Milliseconds 700
    $w = [Cap]::ShotWindow($Window, (Join-Path $Out $name))
    $s = [Cap]::ShotScreen((Join-Path (Join-Path $Out 'full') $name))
    Note "saved $name (window $w; screen $s)"
}

function Visible($Root, $Type) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Type)
    return @($Root.FindAll($Scope::Descendants, $cond) | Where-Object { -not $_.Current.IsOffscreen })
}

function Hwnd($Element) { return [IntPtr]$Element.Current.NativeWindowHandle }

function Read-Log {
    if (-not (Test-Path $log)) { return '' }
    $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

# 0. Clean start.
if (Test-Path $Exe) { Problem 'RustDesk is already installed before Setup' }

# 1. Setup, interactive, in the chosen language.
$proc = Start-Process -FilePath $Setup -ArgumentList "/LANG=$Lang", "/LOG=$log" -PassThru
$wizHwnd = Wait-For { $w = [Cap]::TopWindows('TWizardForm', $null); if ($w.Count -gt 0) { $w[0] } } 90
if (-not $wizHwnd) { [Cap]::ShotScreen((Join-Path $Out "no-wizard-$Mode-$Tag.png")) | Out-Null; throw 'The Setup window did not appear' }
Start-Sleep -Seconds 2
$wiz = $AE::FromHandle($wizHwnd)
Note "Setup window '$($wiz.Current.Name)'"

# Page 1: the two choices, as Setup opens and with the choice made.
Shot $wizHwnd 'choice'
$radios = @(Visible $wiz $CT::RadioButton | Sort-Object { $_.Current.BoundingRectangle.Top })
if ($radios.Count -ne 2) { throw "Expected 2 choices, found $($radios.Count)" }
$pick = if ($Mode -eq 'store') { $radios[0] } else { $radios[1] }
[Cap]::Click((Hwnd $pick))
Start-Sleep -Seconds 1
$selected = $pick.GetCurrentPropertyValue([System.Windows.Automation.SelectionItemPattern]::IsSelectedProperty)
if (-not $selected) { Problem 'the choice did not register as selected' }
Shot $wizHwnd 'choice-selected'

# The Next button keeps its window while its caption changes (Next, Install, Finish); in both
# languages its first caption ends with ">".
$buttons = @(Visible $wiz $CT::Button | Sort-Object { $_.Current.BoundingRectangle.Left })
Note ("buttons: " + (($buttons | ForEach-Object { "'" + $_.Current.Name + "'" }) -join ', '))
$next = @($buttons | Where-Object { $_.Current.Name.TrimEnd().EndsWith('>') })
if ($next.Count -ne 1) {
    # Bottom row, left to right, on the first page: Next, Cancel.
    if ($buttons.Count -lt 2) { throw "Cannot find the Next button" }
    $next = @($buttons[$buttons.Count - 2])
    Problem 'Next button found by position, not by its caption'
}
$nextHwnd = Hwnd $next[0]
[Cap]::Click($nextHwnd)
Start-Sleep -Seconds 2

# Page 2 (store PC only): the password, empty and then typed (the fields show dots).
if ($Mode -eq 'store') {
    Shot $wizHwnd 'password'
    $edits = @(Visible $wiz $CT::Edit | Sort-Object { $_.Current.BoundingRectangle.Top })
    if ($edits.Count -ne 2) { throw "Expected 2 password fields, found $($edits.Count)" }
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $pw = -join (1..12 | ForEach-Object { $chars | Get-Random })
    foreach ($e in $edits) { [Cap]::SetText((Hwnd $e), $pw) }
    $pw = $null
    Start-Sleep -Milliseconds 500
    Shot $wizHwnd 'password-typed'
    [Cap]::Click($nextHwnd)
}

# Installing page, then the last page with the ID. Setup's log says when its steps are done.
Start-Sleep -Seconds 4
Shot $wizHwnd 'installing'
if (-not (Wait-For { (Read-Log) -match 'Emilli: step 1' } 30)) {
    Problem 'the installation did not start after Next; saving the page and pressing Next again'
    Shot $wizHwnd 'unexpected-page'
    [Cap]::Click($nextHwnd)
}
$end = Wait-For { $t = Read-Log; if ($t -match 'Emilli: (done|FAILED)') { $Matches[1] } } 600
if ($end -ne 'done') { Problem "Setup did not report done (got '$end')" }
Start-Sleep -Seconds 3
$copy = Wait-For { @(Visible $wiz $CT::Button | Where-Object { $_.Current.Name -match 'Copy' }) } 30
if (-not $copy) { Problem 'no Copy button on the last page' }
$idText = @(Visible $wiz $CT::Text | Where-Object { $_.Current.Name -match '^\d{1,3}( \d{3})+$' })
if ($idText.Count -eq 1) { Note "ID on the last page: $($idText[0].Current.Name)" } else { Problem 'no ID in large digits on the last page' }
Shot $wizHwnd 'done-id'
[Cap]::Click($nextHwnd)
if (-not $proc.WaitForExit(60000)) { Problem 'Setup did not close after Finish' }
Note "Setup exit code $($proc.ExitCode)"
Select-String -Path $log -SimpleMatch 'Emilli:' | ForEach-Object { Write-Host $_.Line }

# The installed RustDesk's main window, opened the way the user opens it.
if (Test-Path $Exe) {
    Start-Process -FilePath $Exe
    $main = Wait-For {
        $pids = @(Get-Process rustdesk -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        if ($pids.Count -gt 0) {
            [Cap]::TopWindows($null, [int[]]$pids) | Where-Object {
                $r = [Cap]::Frame($_); ($r.Right - $r.Left) -gt 400 -and ($r.Bottom - $r.Top) -gt 300
            } | Select-Object -First 1
        }
    } 90
    if ($main) {
        Start-Sleep -Seconds 12
        Shot $main 'rustdesk-main'
    } else {
        Problem 'the RustDesk main window did not appear'
        [Cap]::ShotScreen((Join-Path $Out "no-rustdesk-window-$Mode-$Tag.png")) | Out-Null
    }
} else {
    Problem 'RustDesk is not installed after Setup'
}

# Uninstall with RustDesk's own uninstaller and remove its settings, so the next run starts clean.
if (Test-Path $Exe) {
    $un = Start-Process -FilePath $Exe -ArgumentList '--uninstall' -PassThru
    [void]$un.WaitForExit(180000)
}
$gone = Wait-For { (-not (Test-Path $Exe)) -and ($null -eq (Get-Service RustDesk -ErrorAction SilentlyContinue)) } 120
if (-not $gone) { Problem 'uninstall did not remove RustDesk' }
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
foreach ($dir in @($SvcRoot, $UserRoot)) { if (Test-Path $dir) { Remove-Item -Recurse -Force $dir } }

Write-Host ("RESULT [{0}] {1} pages saved, {2} problems" -f $Mode, $script:Step, $script:Problems)
if ($script:Problems -gt 0) { exit 1 }
