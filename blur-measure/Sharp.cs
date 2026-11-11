// How far a frame of the helper's session window is from what the store PC really shows.
// Grey levels (0..255) of a crop; the error is the mean absolute difference per pixel and the
// share of pixels more than Tol levels off (a text stroke that is smeared or missing).
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class Sharp {
    public const int Tol = 48;

    public static byte[] Gray(string path, int x, int y, int w, int h) {
        using (Bitmap b = new Bitmap(path)) { return Gray(b, x, y, w, h); }
    }

    public static byte[] Gray(Bitmap b, int x, int y, int w, int h) {
        byte[] g = new byte[w * h];
        Rectangle r = new Rectangle(x, y, w, h);
        BitmapData d = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            byte[] row = new byte[w * 4];
            for (int j = 0; j < h; j++) {
                Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)j * d.Stride), row, 0, w * 4);
                for (int i = 0; i < w; i++) {
                    int bb = row[i * 4], gg = row[i * 4 + 1], rr = row[i * 4 + 2];
                    g[j * w + i] = (byte)((rr * 299 + gg * 587 + bb * 114) / 1000);
                }
            }
        } finally { b.UnlockBits(d); }
        return g;
    }

    public static double Mae(byte[] a, byte[] b) {
        long s = 0;
        for (int i = 0; i < a.Length; i++) s += Math.Abs(a[i] - b[i]);
        return (double)s / a.Length;
    }

    // Per mille of pixels more than Tol grey levels off.
    public static double Bad(byte[] a, byte[] b) {
        long n = 0;
        for (int i = 0; i < a.Length; i++) if (Math.Abs(a[i] - b[i]) > Tol) n++;
        return 1000.0 * n / a.Length;
    }

    // The offset (0..2m in each direction) of a w x h crop inside a frame that is 2m larger, at
    // which the frame matches the truth best. Returns { dx, dy, mae x 1000 }.
    public static int[] Align(string framePath, byte[] truth, int w, int h, int m) {
        int best = int.MaxValue, bx = m, by = m;
        using (Bitmap b = new Bitmap(framePath)) {
            byte[] big = Gray(b, 0, 0, w + 2 * m, h + 2 * m);
            int bw = w + 2 * m;
            for (int dy = 0; dy <= 2 * m; dy++) {
                for (int dx = 0; dx <= 2 * m; dx++) {
                    long s = 0;
                    for (int j = 0; j < h; j += 2) {
                        int o = (j + dy) * bw + dx;
                        int t = j * w;
                        for (int i = 0; i < w; i += 2) s += Math.Abs(big[o + i] - truth[t + i]);
                    }
                    int v = (int)(s * 4000 / ((long)w * h));
                    if (v < best) { best = v; bx = dx; by = dy; }
                }
            }
        }
        return new int[] { bx, by, best };
    }

    public static void SaveCrop(string src, int x, int y, int w, int h, string dst) {
        using (Bitmap b = new Bitmap(src))
        using (Bitmap c = b.Clone(new Rectangle(x, y, w, h), PixelFormat.Format32bppArgb)) {
            c.Save(dst, ImageFormat.Png);
        }
    }
}
