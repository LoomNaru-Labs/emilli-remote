# The error the store PC shows before the session (brief addendum 2, item 1 b): Windows' own
# message box with the red error icon and an OK button, centred on the screen, in front of the
# document and the print queue. Started by run-take.ps1 on a GitHub runner only; the helper
# closes it with OK through the session. It is drawn at the screen's scale (per-monitor DPI).
# Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $Title,
    [Parameter(Mandatory)] [string] $Text
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ErrorBox {
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);
    // MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST
    public static int Show(string title, string text) {
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        return MessageBoxW(IntPtr.Zero, text, title, 0x0 | 0x10 | 0x10000 | 0x40000);
    }
}
'@
[ErrorBox]::Show($Title, $Text) | Out-Null
