# Display size and scale for the Setup screenshots on a GitHub "windows-latest" runner.
# Lists the display modes the runner offers, switches to -Width x -Height, then asks Windows
# for -Scale percent (the same setting as Settings, Display, Scale) without signing out.
# Prints what it got; it never fails the job, because the screenshots show the real result.
#
#   powershell -File windows-capture/capture-display.ps1 -Width 1920 -Height 1080 -Scale 175
param(
    [int] $Width = 1920,
    [int] $Height = 1080,
    [int] $Scale = 175
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);

    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public int outputTechnology; public int rotation;
        public int scaling; public uint refreshNum; public uint refreshDen; public int scanLineOrdering; public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] public struct MODE_INFO { public int infoType; public uint id; public LUID adapterId; public long u0, u1, u2, u3, u4, u5; }
    [StructLayout(LayoutKind.Sequential)] public struct HEADER { public int type; public uint size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential)] public struct DPI_GET { public HEADER header; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }
    [StructLayout(LayoutKind.Sequential)] public struct DPI_SET { public HEADER header; public int scaleRel; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref DPI_GET req);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref DPI_SET req);

    static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    public static string Modes() {
        SortedSet<long> seen = new SortedSet<long>();
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++) seen.Add((long)dm.dmPelsWidth * 100000 + dm.dmPelsHeight);
        List<string> names = new List<string>();
        foreach (long k in seen) names.Add((k / 100000) + "x" + (k % 100000));
        return string.Join(" ", names);
    }

    public static string Current() {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref dm);
        return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
    }

    public static int SetSize(int w, int h) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref dm);
        dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;
        return ChangeDisplaySettingsEx(null, ref dm, IntPtr.Zero, 1, IntPtr.Zero);
    }

    static PATH_SOURCE Source() {
        uint np, nm;
        GetDisplayConfigBufferSizes(2, out np, out nm);
        PATH_INFO[] p = new PATH_INFO[np]; MODE_INFO[] m = new MODE_INFO[nm];
        int r = QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero);
        if (r != 0 || np == 0) throw new Exception("QueryDisplayConfig failed: " + r);
        return p[0].sourceInfo;
    }

    static DPI_GET GetScale() {
        PATH_SOURCE s = Source();
        DPI_GET g = new DPI_GET();
        g.header.type = -3; g.header.size = (uint)Marshal.SizeOf(typeof(DPI_GET));
        g.header.adapterId = s.adapterId; g.header.id = s.id;
        int r = DisplayConfigGetDeviceInfo(ref g);
        if (r != 0) throw new Exception("DisplayConfigGetDeviceInfo failed: " + r);
        return g;
    }

    static int At(int i) { return (i >= 0 && i < Steps.Length) ? Steps[i] : -1; }

    public static string Scale() {
        DPI_GET g = GetScale();
        int rec = Math.Abs(g.minScaleRel);
        return "current " + At(rec + g.curScaleRel) + "%, recommended " + At(rec) + "%, allowed " + At(rec + g.minScaleRel) + "% to " + At(rec + g.maxScaleRel) + "%";
    }

    public static int SetScale(int percent) {
        DPI_GET g = GetScale();
        int rec = Math.Abs(g.minScaleRel);
        int want = Array.IndexOf(Steps, percent) - rec;
        if (want > g.maxScaleRel) want = g.maxScaleRel;
        PATH_SOURCE s = Source();
        DPI_SET d = new DPI_SET();
        d.header.type = -4; d.header.size = (uint)Marshal.SizeOf(typeof(DPI_SET));
        d.header.adapterId = s.adapterId; d.header.id = s.id; d.scaleRel = want;
        return DisplayConfigSetDeviceInfo(ref d);
    }
}
'@

Write-Host "Display modes offered: $([Disp]::Modes())"
Write-Host "Display size now $([Disp]::Current())"
$r = [Disp]::SetSize($Width, $Height)
Start-Sleep -Seconds 3
Write-Host "Switch to ${Width}x${Height}: result $r (0 = done); display size now $([Disp]::Current())"
try {
    Write-Host "Scale before: $([Disp]::Scale())"
    $r = [Disp]::SetScale($Scale)
    Start-Sleep -Seconds 5
    Write-Host "Ask for $Scale%: result $r (0 = done); scale after: $([Disp]::Scale())"
} catch {
    Write-Host "Scale not changed: $($_.Exception.Message)"
}
