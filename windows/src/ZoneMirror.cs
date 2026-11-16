// A window that shows a live copy of one screen zone, so that a video-call app can share
// "a window" and its viewers see just that zone instead of the whole ultrawide screen.
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ZoneFullscreen
{
    public sealed class ZoneMirror : Form
    {
        private const int FramesPerSecond = 30;

        private readonly Rect _zone;
        private readonly bool _useMagnifier;
        private readonly bool _offScreen;
        private readonly System.Windows.Forms.Timer _timer;
        private IntPtr _magnifier;   // magnifier mode: the system-drawn child window
        private bool _magInitialized;
        private Bitmap _frame;       // copy mode: the last grabbed picture

        public Rect Zone { get { return _zone; } }

        /// <summary>How long the last frame took on our side, in milliseconds.</summary>
        public double LastCaptureMs { get; private set; }

        /// <summary>True when the system magnifier is doing the work (false: plain screen copies).</summary>
        public bool UsingMagnifier { get { return _magnifier != IntPtr.Zero; } }

        /// <param name="zone">Screen rectangle to mirror.</param>
        /// <param name="offScreen">
        /// True parks the window beyond the edge of the desktop, where nobody sees it.
        /// False keeps it on screen beneath every other window, for call apps that refuse
        /// to capture an off-screen window; <paramref name="parking"/> says where.
        /// </param>
        /// <param name="parking">
        /// Where to sit when on screen. With the magnifier it may be the zone itself (the window is
        /// left out of its own picture); with plain copies it must not overlap the zone.
        /// </param>
        /// <param name="useMagnifier">
        /// True uses the Windows Magnification API (composed by the system, almost free).
        /// False copies the screen ourselves 30 times a second (works everywhere, but costs a CPU core).
        /// </param>
        public ZoneMirror(Rect zone, string title, bool offScreen, Rect parking, bool useMagnifier)
        {
            _zone = zone;
            _offScreen = offScreen;
            _useMagnifier = useMagnifier;
            Text = title;
            FormBorderStyle = FormBorderStyle.None; // the shared picture is exactly the zone, no title bar
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = true;                   // call apps only list windows that have a taskbar entry
            BackColor = Color.Black;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.Opaque, true);

            Rectangle desktop = SystemInformation.VirtualScreen;
            Location = offScreen ? new Point(desktop.Right + 200, desktop.Top) : new Point(parking.X, parking.Y);
            Size = new Size(zone.W, zone.H);

            _timer = new System.Windows.Forms.Timer { Interval = 1000 / FramesPerSecond };
            _timer.Tick += (s, e) => Tick();
        }

        // The magnifier control only works inside a layered window.
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                if (_useMagnifier) cp.ExStyle |= Native.WS_EX_LAYERED;
                return cp;
            }
        }

        // Never take the keyboard away from what the user is doing.
        protected override bool ShowWithoutActivation { get { return true; } }

        private const int WM_WINDOWPOSCHANGING = 0x0046, WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;

        protected override void WndProc(ref Message m)
        {
            // On screen the window lies over the zone it mirrors and looks exactly like what is
            // beneath it, so if anything raised it (call apps bring the shared window to the front)
            // it would silently swallow every click and scroll. Pin it beneath all other windows:
            // whatever z-order is requested, answer "at the bottom".
            if (m.Msg == WM_WINDOWPOSCHANGING && !_offScreen)
            {
                int flagsOffset = 2 * IntPtr.Size + 16; // WINDOWPOS: hwnd, hwndInsertAfter, x, y, cx, cy, flags
                Marshal.WriteIntPtr(m.LParam, IntPtr.Size, Native.HWND_BOTTOM);
                int flags = Marshal.ReadInt32(m.LParam, flagsOffset);
                Marshal.WriteInt32(m.LParam, flagsOffset, flags & ~(int)Native.SWP_NOZORDER);
            }
            if (m.Msg == WM_MOUSEACTIVATE)
            {
                m.Result = new IntPtr(MA_NOACTIVATE); // a click on a bare patch of it must not steal focus
                return;
            }
            base.WndProc(ref m);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            // Windows may have clamped the size to the monitor; and stay beneath everything.
            Native.SetWindowPos(Handle, Native.HWND_BOTTOM, Left, Top, _zone.W, _zone.H, Native.SWP_NOACTIVATE);

            if (_useMagnifier) StartMagnifier();
            if (_magnifier == IntPtr.Zero)
                _frame = new Bitmap(_zone.W, _zone.H, System.Drawing.Imaging.PixelFormat.Format32bppRgb);
            Tick();
        }

        private void StartMagnifier()
        {
            try
            {
                Native.SetLayeredWindowAttributes(Handle, 0, 255, Native.LWA_ALPHA);
                _magInitialized = Native.MagInitialize();
                if (!_magInitialized) return;

                _magnifier = Native.CreateWindowEx(0, "Magnifier", "ZoneFullscreenMagnifier",
                    Native.WS_VISIBLE | (uint)Native.WS_CHILD | Native.MS_SHOWMAGNIFIEDCURSOR,
                    0, 0, _zone.W, _zone.H, Handle, IntPtr.Zero, Native.GetModuleHandle(null), IntPtr.Zero);
                if (_magnifier == IntPtr.Zero) return;

                var identity = new Native.MAGTRANSFORM { v = new float[] { 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
                Native.MagSetWindowTransform(_magnifier, ref identity);
                // Never show ourselves inside the copy, wherever this window sits.
                Native.MagSetWindowFilterList(_magnifier, Native.MW_FILTERMODE_EXCLUDE, 1, new[] { Handle });
            }
            catch (Exception) // Magnification.dll missing or refused: fall back to plain copies
            {
                _magnifier = IntPtr.Zero;
            }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            // A minimized window cannot be captured by the call app.
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        }

        // One frame, then schedule the next so that the rest of the app always gets a turn:
        // a fixed-rate timer would starve the message loop whenever a frame runs long.
        private void Tick()
        {
            _timer.Stop();
            if (IsDisposed) return;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            if (_magnifier != IntPtr.Zero) RefreshMagnifier(); else GrabFrame();
            LastCaptureMs = watch.Elapsed.TotalMilliseconds;
            _timer.Interval = Math.Max(10, 1000 / FramesPerSecond - (int)LastCaptureMs);
            _timer.Start();
        }

        private void RefreshMagnifier()
        {
            var source = new Native.RECT { Left = _zone.X, Top = _zone.Y, Right = _zone.Right, Bottom = _zone.Bottom };
            Native.MagSetWindowSource(_magnifier, source);
            Native.InvalidateRect(_magnifier, IntPtr.Zero, false);
        }

        private void GrabFrame()
        {
            if (_frame == null) return;
            try
            {
                using (Graphics g = Graphics.FromImage(_frame))
                {
                    g.CopyFromScreen(_zone.X, _zone.Y, 0, 0, _frame.Size, CopyPixelOperation.SourceCopy);
                    DrawCursor(g);
                }
                using (Graphics screen = CreateGraphics())
                    screen.DrawImageUnscaled(_frame, 0, 0);
            }
            catch (Exception) { } // secure desktop (UAC, lock screen) or a display change: keep the last frame
        }

        // Screen copies do not include the mouse pointer; viewers need to see it.
        private void DrawCursor(Graphics g)
        {
            var info = new Native.CURSORINFO();
            info.cbSize = Marshal.SizeOf(typeof(Native.CURSORINFO));
            if (!Native.GetCursorInfo(ref info) || (info.flags & Native.CURSOR_SHOWING) == 0) return;
            if (!_zone.Contains(info.ptScreenPos.X, info.ptScreenPos.Y)) return;

            int hotX = 0, hotY = 0;
            Native.ICONINFO icon;
            if (Native.GetIconInfo(info.hCursor, out icon))
            {
                hotX = icon.xHotspot;
                hotY = icon.yHotspot;
                if (icon.hbmMask != IntPtr.Zero) Native.DeleteObject(icon.hbmMask);
                if (icon.hbmColor != IntPtr.Zero) Native.DeleteObject(icon.hbmColor);
            }
            IntPtr hdc = g.GetHdc();
            try
            {
                Native.DrawIconEx(hdc, info.ptScreenPos.X - _zone.X - hotX, info.ptScreenPos.Y - _zone.Y - hotY,
                                  info.hCursor, 0, 0, 0, IntPtr.Zero, Native.DI_NORMAL);
            }
            finally { g.ReleaseHdc(hdc); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (_frame != null) e.Graphics.DrawImageUnscaled(_frame, 0, 0);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _timer.Stop();
                _timer.Dispose();
                if (_frame != null) { _frame.Dispose(); _frame = null; }
            }
            if (_magnifier != IntPtr.Zero) { Native.DestroyWindow(_magnifier); _magnifier = IntPtr.Zero; }
            if (_magInitialized) { Native.MagUninitialize(); _magInitialized = false; }
            base.Dispose(disposing);
        }
    }
}
