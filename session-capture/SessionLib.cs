// Helpers for the connected-session screenshots (session-capture/*.ps1), loaded with Add-Type
// by Windows PowerShell 5.1, so C# 5 only. Every call works in physical pixels.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class Win {
    public IntPtr Hwnd; public string Cls; public string Title; public uint Pid; public string Proc;
    public int Left, Top, Width, Height; public bool Visible; public bool Iconic;
    public override string ToString() {
        return string.Format("0x{0:X} pid {1} {2} class '{3}' title '{4}' at {5},{6} size {7}x{8}{9}",
            Hwnd.ToInt64(), Pid, Proc, Cls, Title, Left, Top, Width, Height, Iconic ? " minimized" : "");
    }
}

public static class SL {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SystemParametersInfo(uint a, uint b, string c, uint f);
    [DllImport("user32.dll")] static extern bool SetSysColors(int n, int[] el, int[] rgb);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint sid);

    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTU { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTU u; }

    public static void Aware() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

    // Display scale: the screen's effective DPI now (96 = 100 %, 144 = 150 %), and the DPI a
    // window draws at (96 for a program that does not know about scaling, then Windows stretches it).
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
    public static int MonitorDpi() {
        Aware();
        POINT p = new POINT(); uint x, y;
        return GetDpiForMonitor(MonitorFromPoint(p, 1), 0, out x, out y) == 0 ? (int)x : -1;
    }
    public static int WindowDpi(IntPtr h) { return (int)GetDpiForWindow(h); }

    // Another program's menu and list positions come in that program's own view of the screen
    // (a program that does not know about scaling sees 96 DPI pixels). They are read in the
    // window's own DPI context and mapped to screen pixels through the window's rectangle seen
    // both ways.
    static RECT EnterContextOf(IntPtr h) {
        SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(h));
        RECT r; GetWindowRect(h, out r); return r;
    }
    static int[] LeaveAndMap(IntPtr h, RECT seen, int[] r) {
        Aware();
        if (r == null) return null;
        RECT p; GetWindowRect(h, out p);
        double sx = (double)(p.Right - p.Left) / Math.Max(1, seen.Right - seen.Left);
        double sy = (double)(p.Bottom - p.Top) / Math.Max(1, seen.Bottom - seen.Top);
        return new int[] {
            p.Left + (int)Math.Round((r[0] - seen.Left) * sx), p.Top + (int)Math.Round((r[1] - seen.Top) * sy),
            p.Left + (int)Math.Round((r[2] - seen.Left) * sx), p.Top + (int)Math.Round((r[3] - seen.Top) * sy) };
    }

    // Windows' own mouse pointer size (Settings, Accessibility, Mouse pointer, size 1 to 15),
    // for this signed-in user, applied at once; and the pointer's size in pixels now.
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint f);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int n, out BITMAP b);
    [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    public static string SetPointerSize(int size) {
        int baseSize = 32 + 16 * (size - 1);
        using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Control Panel\Cursors"))
            k.SetValue("CursorBaseSize", baseSize, Microsoft.Win32.RegistryValueKind.DWord);
        using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Accessibility"))
            k.SetValue("CursorSize", size, Microsoft.Win32.RegistryValueKind.DWord);
        bool a = SystemParametersInfo(0x2029, 0, new IntPtr(baseSize), 3);
        bool b = SystemParametersInfo(0x0057, 0, IntPtr.Zero, 3);
        Thread.Sleep(500);
        return "pointer size " + size + " (base " + baseSize + " px; size call " + a + ", reload " + b + "), pointer now " + PointerPixels() + " px";
    }
    public static string PointerPixels() {
        Aware();
        CURSORINFO ci = new CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci) || ci.hCursor == IntPtr.Zero) return "(no pointer)";
        int[] wh = CursorSize(ci.hCursor);
        return wh[0] + "x" + wh[1];
    }
    static int[] CursorSize(IntPtr cursor) {
        ICONINFO ii;
        if (!GetIconInfo(cursor, out ii)) return new int[] { 0, 0 };
        BITMAP bm; int w = 0, h = 0;
        if (ii.hbmColor != IntPtr.Zero && GetObject(ii.hbmColor, Marshal.SizeOf(typeof(BITMAP)), out bm) != 0) { w = bm.bmWidth; h = bm.bmHeight; }
        else if (ii.hbmMask != IntPtr.Zero && GetObject(ii.hbmMask, Marshal.SizeOf(typeof(BITMAP)), out bm) != 0) { w = bm.bmWidth; h = bm.bmHeight / 2; }
        if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
        if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
        return new int[] { w, h };
    }

    // A button of one dialog window, by caption: its screen rectangle.
    public static int[] ButtonRect(IntPtr dialog, string caption) {
        Aware();
        int[] found = null;
        EnumChildWindows(dialog, new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (found == null && IsWindowVisible(h) && ClassOf(h) == "Button" && TitleOf(h).Replace("&", "") == caption) {
                RECT r; GetWindowRect(h, out r); found = new int[] { r.Left, r.Top, r.Right, r.Bottom };
            }
            return true;
        }), IntPtr.Zero);
        return found;
    }

    public static uint SessionOf(uint pid) { uint s; return ProcessIdToSessionId(pid, out s) ? s : 0xFFFFFFFF; }
    public static uint MySession() { return SessionOf((uint)Process.GetCurrentProcess().Id); }

    public static int[] Screen() {
        Aware();
        return new int[] { GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79) };
    }

    static string ClassOf(IntPtr h) { StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    static string TitleOf(IntPtr h) { StringBuilder s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }

    public static RECT Frame(IntPtr h) {
        Aware();
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
        return r;
    }

    static Win Describe(IntPtr h) {
        Win w = new Win(); w.Hwnd = h; w.Cls = ClassOf(h); w.Title = TitleOf(h);
        uint pid; GetWindowThreadProcessId(h, out pid); w.Pid = pid;
        try { w.Proc = Process.GetProcessById((int)pid).ProcessName; } catch { w.Proc = "?"; }
        RECT r = Frame(h); w.Left = r.Left; w.Top = r.Top; w.Width = r.Right - r.Left; w.Height = r.Bottom - r.Top;
        w.Visible = IsWindowVisible(h); w.Iconic = IsIconic(h);
        return w;
    }

    // Visible top-level windows of this desktop, front to back.
    public static Win[] Windows() {
        Aware();
        List<Win> list = new List<Win>();
        EnumWindows(new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (IsWindowVisible(h)) list.Add(Describe(h));
            return true;
        }), IntPtr.Zero);
        return list.ToArray();
    }

    public static Win Info(IntPtr h) { Aware(); return Describe(h); }

    public static void Place(IntPtr h, int x, int y, int w, int hh) {
        Aware();
        ShowWindow(h, 9);
        SetWindowPos(h, IntPtr.Zero, x, y, w, hh, 0x0014);
    }

    public static void Show(IntPtr h, int cmd) { ShowWindow(h, cmd); }

    // Moves a window so that its visible frame starts at x,y; the size stays.
    public static void MoveFrameTo(IntPtr h, int x, int y) {
        Aware();
        RECT r; GetWindowRect(h, out r);
        RECT f = Frame(h);
        SetWindowPos(h, IntPtr.Zero, x - (f.Left - r.Left), y - (f.Top - r.Top), 0, 0, 0x0001 | 0x0004 | 0x0010);
    }

    // Foreground from a background process: a tap of Alt lifts the foreground lock.
    public static void Front(IntPtr h) {
        Aware();
        if (IsIconic(h)) ShowWindow(h, 9);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        BringWindowToTop(h);
        SetForegroundWindow(h);
    }

    // Foreground without the Alt tap (an Alt tap can leave a window in its system-menu mode,
    // where the next typed letters are taken as menu keys).
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
    public static string ForegroundTitle() { return TitleOf(GetForegroundWindow()); }
    public static void FrontNoAlt(IntPtr h) { BringWindowToTop(h); SetForegroundWindow(h); }

    public static void Topmost(IntPtr h, bool on) {
        SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0013);
    }

    // Removes the window's taskbar button (ITaskbarList::DeleteTab); the window stays open.
    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList {
        void HrInit(); void AddTab(IntPtr h); void DeleteTab(IntPtr h); void ActivateTab(IntPtr h); void SetActiveAlt(IntPtr h);
    }
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] class TaskbarList { }
    public static void HideFromTaskbar(IntPtr h) {
        ITaskbarList t = (ITaskbarList)new TaskbarList(); t.HrInit(); t.DeleteTab(h);
    }

    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
    [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);

    // Screen grabs include the mouse pointer where the screen shows it, as screen recorders do
    // (a plain screen copy leaves the pointer out).
    public static bool WithCursor = true;

    public static Bitmap Grab(int x, int y, int w, int h) {
        Aware();
        Bitmap b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            if (WithCursor) {
                CURSORINFO ci = new CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
                if (GetCursorInfo(ref ci) && (ci.flags & 1) != 0 && ci.hCursor != IntPtr.Zero) {
                    ICONINFO ii;
                    if (GetIconInfo(ci.hCursor, out ii)) {
                        // Drawn at the pointer's real size (a larger pointer set in Windows is a
                        // larger bitmap; size 0 could draw the standard 32 px one).
                        BITMAP bm; int cw = 0, chh = 0;
                        if (ii.hbmColor != IntPtr.Zero && GetObject(ii.hbmColor, Marshal.SizeOf(typeof(BITMAP)), out bm) != 0) { cw = bm.bmWidth; chh = bm.bmHeight; }
                        else if (ii.hbmMask != IntPtr.Zero && GetObject(ii.hbmMask, Marshal.SizeOf(typeof(BITMAP)), out bm) != 0) { cw = bm.bmWidth; chh = bm.bmHeight / 2; }
                        IntPtr hdc = g.GetHdc();
                        DrawIconEx(hdc, ci.pt.X - ii.xHotspot - x, ci.pt.Y - ii.yHotspot - y, ci.hCursor, cw, chh, 0, IntPtr.Zero, 3);
                        g.ReleaseHdc(hdc);
                        if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
                        if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
                    }
                }
            }
        }
        return b;
    }

    public static string ShotScreen(string path) {
        int[] s = Screen();
        using (Bitmap b = Grab(s[0], s[1], s[2], s[3])) b.Save(path, ImageFormat.Png);
        return s[2] + "x" + s[3];
    }

    // The window's visible frame (no shadow), clipped to the screen.
    public static int[] Clip(IntPtr h) {
        int[] s = Screen();
        RECT r = Frame(h);
        int left = Math.Max(r.Left, s[0]), top = Math.Max(r.Top, s[1]);
        int right = Math.Min(r.Right, s[0] + s[2]), bottom = Math.Min(r.Bottom, s[1] + s[3]);
        return new int[] { left, top, right - left, bottom - top };
    }

    public static string ShotWindow(IntPtr h, string path) {
        int[] c = Clip(h);
        if (c[2] <= 0 || c[3] <= 0) return "window not on screen";
        using (Bitmap b = Grab(c[0], c[1], c[2], c[3])) b.Save(path, ImageFormat.Png);
        return c[2] + "x" + c[3] + " at " + c[0] + "," + c[1];
    }

    // Saves the window and, from the same grab, the region x,y,w,h given in screen pixels.
    public static string ShotWindowAndRegion(IntPtr h, string windowPath, int x, int y, int w, int hh, string regionPath) {
        int[] c = Clip(h);
        if (c[2] <= 0 || c[3] <= 0) return "window not on screen";
        using (Bitmap b = Grab(c[0], c[1], c[2], c[3])) {
            b.Save(windowPath, ImageFormat.Png);
            Rectangle r = new Rectangle(x - c[0], y - c[1], w, hh);
            r.Intersect(new Rectangle(0, 0, c[2], c[3]));
            if (r.Width > 0 && r.Height > 0)
                using (Bitmap part = b.Clone(r, PixelFormat.Format24bppRgb)) part.Save(regionPath, ImageFormat.Png);
            return c[2] + "x" + c[3] + " at " + c[0] + "," + c[1] + "; region " + r.Width + "x" + r.Height + " at +" + r.X + ",+" + r.Y;
        }
    }

    // Bounding box (screen pixels) of the pixels within tol of the colour, inside the region.
    // Returns left, top, right, bottom, count; count 0 when nothing matched.
    public static int[] ColorBox(int x, int y, int w, int h, int red, int green, int blue, int tol) {
        bool keep = WithCursor; WithCursor = false;
        Bitmap grabbed = Grab(x, y, w, h);
        WithCursor = keep;
        using (Bitmap b = grabbed) {
            BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            byte[] px = new byte[d.Stride * h];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
            b.UnlockBits(d);
            int l = int.MaxValue, t = int.MaxValue, r = -1, bo = -1, n = 0;
            for (int j = 0; j < h; j++) {
                int row = j * d.Stride;
                for (int i = 0; i < w; i++) {
                    int o = row + i * 3;
                    if (Math.Abs(px[o + 2] - red) <= tol && Math.Abs(px[o + 1] - green) <= tol && Math.Abs(px[o] - blue) <= tol) {
                        n++;
                        if (i < l) l = i; if (i > r) r = i; if (j < t) t = j; if (j > bo) bo = j;
                    }
                }
            }
            if (n == 0) return new int[] { 0, 0, 0, 0, 0 };
            return new int[] { x + l, y + t, x + r, y + bo, n };
        }
    }

    // Share (0..1000) of pixels in the region that are not near-black: a black or blank remote
    // picture scores close to 0.
    public static int NonBlack(int x, int y, int w, int h) {
        using (Bitmap b = Grab(x, y, w, h)) {
            int n = 0, all = 0;
            for (int j = 0; j < h; j += 4) for (int i = 0; i < w; i += 4) {
                Color c = b.GetPixel(i, j); all++;
                if (c.R + c.G + c.B > 60) n++;
            }
            return all == 0 ? 0 : n * 1000 / all;
        }
    }

    // Real mouse input (SendInput), moved at a human pace with ease-in-out and a slight arc.
    static void MoveAbs(int x, int y) {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        INPUT[] i = new INPUT[1];
        i[0].type = 0;
        i[0].u.mi.dx = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
        i[0].u.mi.dy = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
        i[0].u.mi.dwFlags = 0x0001 | 0x8000 | 0x4000;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static int[] Cursor() { Aware(); POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }

    public static void Glide(int x, int y, int ms) {
        Aware();
        POINT p; GetCursorPos(out p);
        int steps = Math.Max(1, ms / 15);
        double dx = x - p.X, dy = y - p.Y, len = Math.Sqrt(dx * dx + dy * dy);
        double bend = Math.Min(60.0, len * 0.08);
        for (int s = 1; s <= steps; s++) {
            double t = (double)s / steps;
            double e = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
            double arc = Math.Sin(Math.PI * t) * bend;
            double nx = len > 0 ? -dy / len : 0, ny = len > 0 ? dx / len : 0;
            MoveAbs((int)Math.Round(p.X + dx * e + nx * arc), (int)Math.Round(p.Y + dy * e + ny * arc));
            Thread.Sleep(15);
        }
        MoveAbs(x, y);
    }

    public static void Click(bool right) {
        INPUT[] i = new INPUT[1];
        i[0].type = 0;
        i[0].u.mi.dwFlags = right ? 0x0008u : 0x0002u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(90);
        i[0].u.mi.dwFlags = right ? 0x0010u : 0x0004u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Posts BN_CLICKED for a dialog button found by its caption (used only for the Remote
    // Desktop client's own prompts on the runner, never inside the captured session).
    public static int ClickButton(IntPtr dialog, string caption) {
        int n = 0;
        EnumChildWindows(dialog, new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (ClassOf(h) == "Button" && TitleOf(h).Replace("&", "") == caption && IsWindowVisible(h)) {
                PostMessage(GetParent(h), 0x0111, new IntPtr(GetDlgCtrlID(h) & 0xFFFF), h); n++;
            }
            return true;
        }), IntPtr.Zero);
        return n;
    }

    // Screen rectangle (left, top, right, bottom) of the first visible child window of a class.
    public static int[] ChildRect(IntPtr parent, string cls) {
        Aware();
        int[] found = null;
        EnumChildWindows(parent, new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (found == null && IsWindowVisible(h) && ClassOf(h) == cls) {
                RECT r; GetWindowRect(h, out r); found = new int[] { r.Left, r.Top, r.Right, r.Bottom };
            }
            return true;
        }), IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint item, StringBuilder s, int n, uint flags);
    [DllImport("user32.dll")] static extern bool GetMenuItemRect(IntPtr h, IntPtr menu, uint item, out RECT r);

    // An open pop-up menu's item whose text starts with the given word: its screen rectangle
    // and the texts of all items, for the log.
    public static int[] MenuItemRect(string word, out string texts) {
        Aware();
        texts = "";
        int[] found = null;
        IntPtr menuWnd = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "#32768", null);
        while (menuWnd != IntPtr.Zero) {
            if (IsWindowVisible(menuWnd)) {
                IntPtr menu = SendMessage(menuWnd, 0x01E1, IntPtr.Zero, IntPtr.Zero);
                int n = GetMenuItemCount(menu);
                for (int i = 0; i < n; i++) {
                    StringBuilder s = new StringBuilder(256);
                    GetMenuString(menu, (uint)i, s, 256, 0x400);
                    string t = s.ToString().Replace("&", "");
                    texts += "[" + t + "] ";
                    RECT r;
                    if (found == null && t.StartsWith(word, StringComparison.OrdinalIgnoreCase)) {
                        RECT seen = EnterContextOf(menuWnd);
                        int[] raw = GetMenuItemRect(menuWnd, menu, (uint)i, out r) ? new int[] { r.Left, r.Top, r.Right, r.Bottom } : null;
                        found = LeaveAndMap(menuWnd, seen, raw);
                    }
                }
            }
            menuWnd = FindWindowEx(IntPtr.Zero, menuWnd, "#32768", null);
        }
        return found;
    }

    // A button with this caption in any visible dialog box (class #32770): its screen rectangle.
    public static int[] DialogButtonRect(string caption, out string dialog) {
        Aware();
        dialog = "";
        int[] found = null;
        string d = "";
        EnumWindows(new EnumProc(delegate(IntPtr top, IntPtr l) {
            if (found != null || !IsWindowVisible(top) || ClassOf(top) != "#32770") return true;
            EnumChildWindows(top, new EnumProc(delegate(IntPtr h, IntPtr l2) {
                if (found == null && IsWindowVisible(h) && ClassOf(h) == "Button" && TitleOf(h).Replace("&", "") == caption) {
                    RECT r; GetWindowRect(h, out r); found = new int[] { r.Left, r.Top, r.Right, r.Bottom };
                    d = "'" + TitleOf(top) + "' " + ChildTexts(top);
                }
                return true;
            }), IntPtr.Zero);
            return true;
        }), IntPtr.Zero);
        dialog = d;
        return found;
    }

    public static IntPtr ChildHandle(IntPtr parent, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (found == IntPtr.Zero && IsWindowVisible(h) && ClassOf(h) == cls) found = h;
            return true;
        }), IntPtr.Zero);
        return found;
    }

    // A menu bar item of a window whose text starts with the word: screen rectangle.
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr h);
    public static int[] MenuBarItemRect(IntPtr wnd, string word) {
        Aware();
        IntPtr menu = GetMenu(wnd);
        int n = GetMenuItemCount(menu);
        for (int i = 0; i < n; i++) {
            StringBuilder s = new StringBuilder(256);
            GetMenuString(menu, (uint)i, s, 256, 0x400);
            RECT r;
            if (s.ToString().Replace("&", "").StartsWith(word, StringComparison.OrdinalIgnoreCase)) {
                RECT seen = EnterContextOf(wnd);
                int[] raw = GetMenuItemRect(wnd, menu, (uint)i, out r) ? new int[] { r.Left, r.Top, r.Right, r.Bottom } : null;
                return LeaveAndMap(wnd, seen, raw);
            }
        }
        return null;
    }

    // Items of a list view in another process (text of column 0 and screen rectangle), read
    // through a small buffer in that process, the usual way for a cross-process list view.
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, UIntPtr size, uint type);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr a, byte[] b, UIntPtr n, out UIntPtr w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr a, byte[] b, UIntPtr n, out UIntPtr r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    public static string[] ListViewItems(IntPtr lv) { return ListViewItems(lv, 0); }
    // The same with the text of another column (1 = a print queue's Status column).
    public static string[] ListViewItems(IntPtr lv, int column) {
        Aware();
        List<string> res = new List<string>();
        uint pid; GetWindowThreadProcessId(lv, out pid);
        IntPtr proc = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (proc == IntPtr.Zero) return res.ToArray();
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)4096, 0x3000, 0x04);
        try {
            int count = (int)SendMessage(lv, 0x1004, IntPtr.Zero, IntPtr.Zero);
            UIntPtr io;
            for (int i = 0; i < count; i++) {
                byte[] item = new byte[88];
                BitConverter.GetBytes(column).CopyTo(item, 8);                    // iSubItem
                BitConverter.GetBytes(mem.ToInt64() + 1024).CopyTo(item, 24);    // pszText
                BitConverter.GetBytes(256).CopyTo(item, 32);                       // cchTextMax
                WriteProcessMemory(proc, mem, item, (UIntPtr)item.Length, out io);
                SendMessage(lv, 0x1073, new IntPtr(i), mem);                        // LVM_GETITEMTEXTW
                byte[] text = new byte[512];
                ReadProcessMemory(proc, new IntPtr(mem.ToInt64() + 1024), text, (UIntPtr)text.Length, out io);
                string t = Encoding.Unicode.GetString(text);
                int z = t.IndexOf('\0'); if (z >= 0) t = t.Substring(0, z);
                byte[] rc = new byte[16];                                          // RECT, left = LVIR_BOUNDS (0)
                WriteProcessMemory(proc, new IntPtr(mem.ToInt64() + 512), rc, (UIntPtr)16, out io);
                SendMessage(lv, 0x100E, new IntPtr(i), new IntPtr(mem.ToInt64() + 512)); // LVM_GETITEMRECT
                ReadProcessMemory(proc, new IntPtr(mem.ToInt64() + 512), rc, (UIntPtr)16, out io);
                POINT a = new POINT(); a.X = BitConverter.ToInt32(rc, 0); a.Y = BitConverter.ToInt32(rc, 4);
                POINT b = new POINT(); b.X = BitConverter.ToInt32(rc, 8); b.Y = BitConverter.ToInt32(rc, 12);
                RECT seen = EnterContextOf(lv);
                ClientToScreen(lv, ref a); ClientToScreen(lv, ref b);
                int[] m = LeaveAndMap(lv, seen, new int[] { a.X, a.Y, b.X, b.Y });
                res.Add(t + "|" + m[0] + "|" + m[1] + "|" + m[2] + "|" + m[3]);
            }
        } finally {
            VirtualFreeEx(proc, mem, UIntPtr.Zero, 0x8000);
            CloseHandle(proc);
        }
        return res.ToArray();
    }

    // Real typing: one Unicode key press per character, at the given pace.
    public static void TypeText(string text, int msPerChar) {
        foreach (char ch in text) {
            INPUT[] i = new INPUT[2];
            i[0].type = 1; i[0].u.ki.scan = ch; i[0].u.ki.flags = 0x0004;
            i[1].type = 1; i[1].u.ki.scan = ch; i[1].u.ki.flags = 0x0004 | 0x0002;
            SendInput(2, i, Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(msPerChar);
        }
    }

    public static void PressKey(ushort vk) {
        INPUT[] i = new INPUT[2];
        i[0].type = 1; i[0].u.ki.vk = vk;
        i[1].type = 1; i[1].u.ki.vk = vk; i[1].u.ki.flags = 0x0002;
        SendInput(2, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void PostClose(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    // LVM_GETNEXTITEM with LVNI_SELECTED: the selected row, -1 when none.
    public static int ListViewSelected(IntPtr lv) { return (int)SendMessage(lv, 0x100C, new IntPtr(-1), new IntPtr(2)); }

    // LVM_SETCOLUMNWIDTH: plain numbers, so it works on another process's list view.
    public static void SetColumnWidth(IntPtr lv, int col, int width) { SendMessage(lv, 0x101E, new IntPtr(col), new IntPtr(width)); }

    public static string ChildTexts(IntPtr parent) {
        StringBuilder sb = new StringBuilder();
        EnumChildWindows(parent, new EnumProc(delegate(IntPtr h, IntPtr l) {
            if (IsWindowVisible(h)) sb.Append("[" + ClassOf(h) + ":" + TitleOf(h) + "] ");
            return true;
        }), IntPtr.Zero);
        return sb.ToString();
    }

    // Lossless frame recording of a screen region: one thread grabs at a fixed rate, three
    // threads write the PNGs, frames.csv keeps each frame's real time in milliseconds.
    static Thread recThread;
    static volatile bool recStop;
    static int recFrames, recLate;
    public static void RecordStart(int x, int y, int w, int h, int fps, string dir) { RecordStart(x, y, w, h, fps, dir, 40); }

    // maxSeconds: the frames are held in memory, so a recording stops by itself after this long.
    public static void RecordStart(int x, int y, int w, int h, int fps, string dir, int maxSeconds) {
        recStop = false; recFrames = 0; recLate = 0;
        System.IO.Directory.CreateDirectory(dir);
        // Wall-clock start (Unix ms) so marks taken in another process map onto frames.csv.
        long startUnix = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "start.txt"), startUnix.ToString());
        recThread = new Thread(delegate() {
            Aware();
            // Frames stay in memory while recording (no PNG work competing with the session);
            // they are written out after the stop.
            List<Bitmap> held = new List<Bitmap>();
            StringBuilder times = new StringBuilder("frame,ms\n");
            Stopwatch sw = Stopwatch.StartNew();
            double step = 1000.0 / fps;
            int i = 0;
            while (!recStop && sw.Elapsed.TotalSeconds < maxSeconds) {
                double due = i * step;
                double now = sw.Elapsed.TotalMilliseconds;
                if (now < due) { Thread.Sleep((int)Math.Max(1, due - now)); continue; }
                if (now - due > step) recLate++;
                Bitmap b = Grab(x, y, w, h);
                times.Append(i).Append(',').Append((long)sw.Elapsed.TotalMilliseconds).Append('\n');
                held.Add(b);
                i++;
            }
            System.Threading.Tasks.ParallelOptions po = new System.Threading.Tasks.ParallelOptions();
            po.MaxDegreeOfParallelism = 4;
            System.Threading.Tasks.Parallel.For(0, held.Count, po, delegate(int k) {
                held[k].Save(System.IO.Path.Combine(dir, string.Format("frame-{0:D5}.png", k)), ImageFormat.Png);
                held[k].Dispose();
            });
            recFrames = i;
            System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "frames.csv"), times.ToString());
        });
        recThread.IsBackground = true;
        recThread.Start();
    }

    public static string RecordStop() {
        recStop = true;
        if (recThread != null) recThread.Join();
        return recFrames + " frames, " + recLate + " late";
    }

    // Plain-colour desktop, no picture.
    public static void PlainDesktop(int red, int green, int blue) {
        SetSysColors(1, new int[] { 1 }, new int[] { red | (green << 8) | (blue << 16) });
        SystemParametersInfo(0x0014, 0, "", 0x01 | 0x02);
    }

    // Hides the desktop icons (the list view inside Progman or WorkerW).
    public static int HideDesktopIcons() {
        int n = 0;
        EnumWindows(new EnumProc(delegate(IntPtr h, IntPtr l) {
            IntPtr view = FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (view != IntPtr.Zero) {
                IntPtr list = FindWindowEx(view, IntPtr.Zero, "SysListView32", null);
                if (list != IntPtr.Zero) { ShowWindow(list, 0); n++; }
            }
            return true;
        }), IntPtr.Zero);
        return n;
    }
}
