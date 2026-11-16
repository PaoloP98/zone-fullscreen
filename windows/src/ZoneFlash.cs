// A see-through tint that briefly covers a zone and names it, so the user sees at a glance
// which part of the screen they just started sharing. It fades out by itself, lets clicks
// through, and is hidden from screen capture so viewers of the call never see it.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ZoneFullscreen
{
    public sealed class ZoneFlash : Form
    {
        private const double PeakOpacity = 0.62;
        private const int HoldMs = 1600, FadeMs = 500, StepMs = 25;
        private const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
        private const uint WDA_EXCLUDEFROMCAPTURE = 0x11;

        [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

        private readonly string _title, _detail;
        private readonly bool _hideFromCapture;
        private readonly System.Windows.Forms.Timer _timer;
        private int _elapsed;

        /// <param name="zone">Screen rectangle to cover.</param>
        /// <param name="title">Big line, e.g. "Zone 2".</param>
        /// <param name="detail">Small line underneath.</param>
        /// <param name="hideFromCapture">False only for tests that need to photograph it.</param>
        public ZoneFlash(Rect zone, string title, string detail, bool hideFromCapture)
        {
            _title = title;
            _detail = detail;
            _hideFromCapture = hideFromCapture;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.FromArgb(24, 78, 190);
            Opacity = PeakOpacity;
            Bounds = new Rectangle(zone.X, zone.Y, zone.W, zone.H);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);

            _timer = new System.Windows.Forms.Timer { Interval = StepMs };
            _timer.Tick += (s, e) => Step();
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                // Click-through, never focused, no taskbar or Alt+Tab entry.
                cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            if (_hideFromCapture) SetWindowDisplayAffinity(Handle, WDA_EXCLUDEFROMCAPTURE);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            _timer.Start();
        }

        private void Step()
        {
            _elapsed += StepMs;
            if (_elapsed <= HoldMs) return;
            double left = 1.0 - (double)(_elapsed - HoldMs) / FadeMs;
            if (left <= 0)
            {
                _timer.Stop();
                Close();
                return;
            }
            Opacity = PeakOpacity * left;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            Rectangle area = ClientRectangle;

            // A frame along the edge makes the extent of the zone unmistakable.
            const int frame = 10;
            using (var pen = new Pen(Color.White, frame))
                g.DrawRectangle(pen, frame / 2, frame / 2, area.Width - frame, area.Height - frame);

            float titleSize = Math.Max(36f, Math.Min(area.Width / 9f, area.Height / 5f));
            using (var titleFont = new Font("Segoe UI", titleSize, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var detailFont = new Font("Segoe UI", Math.Max(16f, titleSize / 4.5f), FontStyle.Regular, GraphicsUnit.Pixel))
            using (var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                SizeF titleBox = g.MeasureString(_title, titleFont);
                SizeF detailBox = g.MeasureString(_detail, detailFont, area.Width - 80, center);
                float top = (area.Height - titleBox.Height - detailBox.Height) / 2f;
                g.DrawString(_title, titleFont, Brushes.White,
                             new RectangleF(0, top, area.Width, titleBox.Height), center);
                g.DrawString(_detail, detailFont, Brushes.White,
                             new RectangleF(40, top + titleBox.Height, area.Width - 80, detailBox.Height + 8), center);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _timer.Dispose();
            base.Dispose(disposing);
        }
    }
}
