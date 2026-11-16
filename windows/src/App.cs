// Tray icon, menu, hotkey, settings and the entry point.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ZoneFullscreen
{
    public sealed class AppConfig : IZoneSettings
    {
        bool IZoneSettings.Enabled { get { return Enabled; } }
        bool IZoneSettings.CoverTaskbar { get { return CoverTaskbar; } }
        bool IZoneSettings.ConfineReassertingWindows { get { return Chromium; } }

        public bool Enabled = true;
        public bool CoverTaskbar = true;
        public bool Chromium = false; // confine Chromium-based windows too (they flicker; see WindowWatcher)
        public bool MirrorCopy = false;     // shared zone: copy the screen ourselves instead of using the system magnifier
        public List<string> Excluded = new List<string>();

        private string _path;

        public bool IsExcluded(string process)
        {
            return !string.IsNullOrEmpty(process) && Excluded.Contains(process, StringComparer.OrdinalIgnoreCase);
        }

        public static AppConfig Load(string path)
        {
            var config = new AppConfig();
            config._path = path;
            try
            {
                if (!File.Exists(path)) return config;
                var data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path)) as IDictionary<string, object>;
                if (data == null) return config;
                object v;
                if (data.TryGetValue("enabled", out v) && v is bool) config.Enabled = (bool)v;
                if (data.TryGetValue("coverTaskbar", out v) && v is bool) config.CoverTaskbar = (bool)v;
                if (data.TryGetValue("chromium", out v) && v is bool) config.Chromium = (bool)v;
                if (data.TryGetValue("mirrorCopy", out v) && v is bool) config.MirrorCopy = (bool)v;
                if (data.TryGetValue("excluded", out v) && v is object[])
                    config.Excluded = ((object[])v).OfType<string>().Select(s => s.Trim().ToLowerInvariant())
                                                   .Where(s => s.Length > 0).Distinct().ToList();
            }
            catch (Exception) { } // unreadable settings: start from defaults
            return config;
        }

        public void Save()
        {
            if (_path == null) return;
            try
            {
                var data = new Dictionary<string, object>
                {
                    { "enabled", Enabled }, { "coverTaskbar", CoverTaskbar }, { "chromium", Chromium }, { "mirrorCopy", MirrorCopy },{ "excluded", Excluded },
                };
                File.WriteAllText(_path, new JavaScriptSerializer().Serialize(data));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>Invisible window that receives the global hotkey.</summary>
    internal sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        private const int HotkeyId = 1;
        private readonly Action _pressed;
        public bool Registered { get; private set; }

        public HotkeyWindow(Action pressed)
        {
            _pressed = pressed;
            CreateHandle(new CreateParams());
            Registered = Native.RegisterHotKey(Handle, HotkeyId,
                Native.MOD_CONTROL | Native.MOD_WIN | Native.MOD_NOREPEAT, Native.VK_F11);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == HotkeyId) _pressed();
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Registered) Native.UnregisterHotKey(Handle, HotkeyId);
            DestroyHandle();
        }
    }

    internal sealed class TrayApp : ApplicationContext
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "ZoneFullscreen";

        private readonly AppConfig _config;
        private readonly ZoneProvider _zones;
        private readonly WindowWatcher _watcher;
        private readonly HotkeyWindow _hotkey;
        private readonly NotifyIcon _tray;
        private readonly System.Windows.Forms.Timer _pruneTimer;
        private readonly string _launcher;
        private IntPtr _iconHandle;
        private ZoneMirror _mirror; // the zone currently offered to video-call apps, if any
        private bool _cleaned;

        public TrayApp(string launcher, string logPath)
        {
            _launcher = launcher;
            string dir = Path.GetDirectoryName(launcher) ?? ".";
            _config = AppConfig.Load(Path.Combine(dir, "config.json"));
            _zones = new ZoneProvider(ZoneProvider.DefaultDirectory);
            _watcher = new WindowWatcher(_zones, _config, logPath, Path.Combine(dir, "frameless-windows.txt"));
            _hotkey = new HotkeyWindow(() => _watcher.ToggleForced(Native.GetForegroundWindow()));

            var menu = new ContextMenuStrip();
            menu.Opening += (s, e) => BuildMenu(menu);
            _tray = new NotifyIcon { Icon = MakeIcon(), Text = "ZoneFullscreen", ContextMenuStrip = menu, Visible = true };

            _pruneTimer = new System.Windows.Forms.Timer { Interval = 30000 };
            _pruneTimer.Tick += (s, e) => _watcher.Prune();
            _pruneTimer.Start();

            Application.ThreadException += OnThreadException;
            _watcher.Start();
            if (!_watcher.HooksInstalled)
                _tray.ShowBalloonTip(10000, "ZoneFullscreen",
                    "Windows refused to let ZoneFullscreen watch windows, so it cannot work. Try restarting it.",
                    ToolTipIcon.Error);
            MigrateAutostart();
        }

        private void BuildMenu(ContextMenuStrip menu)
        {
            menu.Items.Clear();

            menu.Items.Add(new ToolStripMenuItem("Layout: " + PrimaryLayout()) { Enabled = false });
            menu.Items.Add(new ToolStripMenuItem(_hotkey.Registered
                ? "Ctrl+Win+F11: fit the active window to its zone"
                : "Ctrl+Win+F11 unavailable (already in use)") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Enabled",_config.Enabled, () => _config.Enabled = !_config.Enabled));
            menu.Items.Add(Toggle("Cover the taskbar", _config.CoverTaskbar,
                                  () => _config.CoverTaskbar = !_config.CoverTaskbar));
            menu.Items.Add(Toggle("Also Edge/Chrome without the extension (flickers)", _config.Chromium,
                                  () => _config.Chromium = !_config.Chromium));
            menu.Items.Add(BuildShareMenu());

            string active = _watcher.ProcessName(_watcher.LastForeground);
            if (active.Length > 0 && !_config.IsExcluded(active))
            {
                menu.Items.Add(new ToolStripMenuItem("Exclude \"" + active + "\"", null, (s, e) =>
                {
                    _config.Excluded.Add(active);
                    _config.Save();
                }));
            }
            if (_config.Excluded.Count > 0)
            {
                var excluded = new ToolStripMenuItem("Excluded programs (click to re-enable)");
                foreach (string name in _config.Excluded.ToList())
                {
                    string captured = name;
                    excluded.DropDownItems.Add(new ToolStripMenuItem(captured, null, (s, e) =>
                    {
                        _config.Excluded.Remove(captured);
                        _config.Save();
                    }));
                }
                menu.Items.Add(excluded);
            }

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Toggle("Start with Windows", IsAutostart(), () => SetAutostart(!IsAutostart())));
            menu.Items.Add(new ToolStripMenuItem("Exit", null, (s, e) => ExitThread()));
        }

        private ToolStripMenuItem Toggle(string text, bool on, Action flip)
        {
            return new ToolStripMenuItem(text, null, (s, e) => { flip(); _config.Save(); }) { Checked = on };
        }

        // "Share a zone": opens a window mirroring the zone; the user then picks that window
        // in the call app's "share a window" list.
        private ToolStripMenuItem BuildShareMenu()
        {
            var share = new ToolStripMenuItem(_mirror == null ? "Share a zone (for video calls)" : "Zone sharing is on");
            share.Checked = _mirror != null;

            Native.MONITORINFOEX info;
            string layout;
            List<Rect> zones = Native.TryGetMonitorAtCursor(out info) ? _zones.GetZones(info, out layout) : new List<Rect>();
            Rect monitor = info.rcMonitor.ToRect();

            for (int i = 0; i < zones.Count; i++)
            {
                // Leave the taskbar out: a slice of it at the bottom of the shared picture means nothing to viewers.
                Rect zone = zones[i].Intersect(info.rcWork.ToRect());
                if (zone.IsEmpty) continue;
                int number = i + 1;
                bool active = _mirror != null && _mirror.Zone == zone;
                var item = new ToolStripMenuItem("Zone " + number + "  (" + zone.W + "×" + zone.H + ")", null,
                    (s, e) => { if (active) StopSharing(); else StartSharing(zone, number, monitor); });
                item.Checked = active;
                share.DropDownItems.Add(item);
            }
            if (zones.Count == 0)
                share.DropDownItems.Add(new ToolStripMenuItem("No zones on this monitor") { Enabled = false });

            share.DropDownItems.Add(new ToolStripSeparator());
            if (_mirror != null)
                share.DropDownItems.Add(new ToolStripMenuItem("Stop sharing", null, (s, e) => StopSharing()));
            share.DropDownItems.Add(Toggle("Compatible method (if others see black; uses more CPU)", _config.MirrorCopy,
                                           () => _config.MirrorCopy = !_config.MirrorCopy));
            if (_mirror != null)
                share.DropDownItems.Add(new ToolStripMenuItem("In the call app, pick the window \"" + _mirror.Text + "\"") { Enabled = false });
            return share;
        }

        private void StartSharing(Rect zone, int number, Rect monitor)
        {
            StopSharing();
            // Fast method: the system magnifier, which only works on screen. The window sits in the zone
            // itself beneath everything and leaves itself out of the picture, so it is never noticed.
            // Compatible method: we copy the screen ourselves; that works off screen, out of the way.
            bool magnifier = !_config.MirrorCopy;
            _mirror = new ZoneMirror(zone, "ZoneFullscreen - Zone " + number, !magnifier, zone, magnifier);
            _mirror.FormClosed += (s, e) => { if (ReferenceEquals(s, _mirror)) _mirror = null; };
            _mirror.Show();
            // Show on screen, for a moment, exactly which area is now on offer.
            var flash = new ZoneFlash(zone, "Zone " + number,
                "Ready to share: in the call, pick the window \"" + _mirror.Text + "\"", true);
            flash.FormClosed += (s, e) => flash.Dispose();
            flash.Show();
        }

        private void StopSharing()
        {
            if (_mirror == null) return;
            ZoneMirror mirror = _mirror;
            _mirror = null;
            mirror.Close();
            mirror.Dispose();
        }

        private string PrimaryLayout()
        {
            IntPtr monitor;
            Native.MONITORINFOEX info;
            if (!Native.TryGetPrimaryMonitor(out monitor, out info)) return "?";
            string description;
            _zones.GetZones(info, out description);
            return description;
        }

        private string AutostartCommand()
        {
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            // Bypass applies to this one process: without it the default policy refuses to run the script.
            return "\"" + powershell + "\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + _launcher + "\"";
        }

        private string AutostartValue()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey))
                return key == null ? null : key.GetValue(RunValue) as string;
        }

        // Any command that starts this launcher counts, so entries written by older versions still show as on.
        private bool IsAutostart()
        {
            string value = AutostartValue();
            return value != null && value.IndexOf("\"" + _launcher + "\"", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // Rewrite an entry that no longer matches: written by an older version (it lacked
        // -ExecutionPolicy), or pointing at a folder this copy has since been moved out of.
        private void MigrateAutostart()
        {
            try
            {
                string value = AutostartValue();
                if (value != null && !string.Equals(value, AutostartCommand(), StringComparison.OrdinalIgnoreCase))
                    SetAutostart(true);
            }
            catch (Exception) { } // registry not writable: the old entry keeps working where it did
        }

        private void SetAutostart(bool on)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (key == null) return;
                if (on) key.SetValue(RunValue, AutostartCommand());
                else key.DeleteValue(RunValue, false);
            }
        }

        // Two side-by-side panes: the icon is drawn here so the app ships as text files only.
        private Icon MakeIcon()
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                using (var left = new SolidBrush(Color.FromArgb(52, 120, 246)))
                using (var right = new SolidBrush(Color.FromArgb(235, 235, 240)))
                {
                    g.Clear(Color.Transparent);
                    g.FillRectangle(left, 2, 6, 13, 20);
                    g.FillRectangle(right, 17, 6, 13, 20);
                }
                _iconHandle = bmp.GetHicon();
                return Icon.FromHandle(_iconHandle);
            }
        }

        // An error in a menu action or timer must not take the app down with windows still modified:
        // report it and keep running.
        private void OnThreadException(object sender, ThreadExceptionEventArgs e)
        {
            try
            {
                _watcher.Log("error: " + e.Exception);
                _tray.ShowBalloonTip(8000, "ZoneFullscreen", "Error: " + e.Exception.Message, ToolTipIcon.Error);
            }
            catch (Exception) { }
        }

        // Runs once, however the app ends ("Exit" or an exception out of the message loop).
        private void Cleanup()
        {
            if (_cleaned) return;
            _cleaned = true;
            Application.ThreadException -= OnThreadException;
            try
            {
                _watcher.Dispose(); // first: this is what gives windows back their borders and z-order
            }
            finally
            {
                _pruneTimer.Stop();
                StopSharing();
                _hotkey.Dispose();
                _tray.Visible = false;
                _tray.Dispose();
                if (_iconHandle != IntPtr.Zero) Native.DestroyIcon(_iconHandle);
            }
        }

        protected override void ExitThreadCore()
        {
            Cleanup();
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) Cleanup();
            base.Dispose(disposing);
        }
    }

    public static class Program
    {
        /// <param name="launcher">Full path of the script that started us (settings live next to it).</param>
        /// <param name="logPath">Optional file that receives a line per action; null for no log.</param>
        /// <returns>False when another instance is already running.</returns>
        public static bool Run(string launcher, string logPath)
        {
            bool isNew;
            using (var mutex = new Mutex(true, @"Local\ZoneFullscreen.SingleInstance", out isNew))
            {
                if (!isNew) return false;

                // Work in physical pixels on every monitor, whatever the host process declared.
                try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
                catch (EntryPointNotFoundException) { }

                Application.EnableVisualStyles();
                using (var app = new TrayApp(launcher, string.IsNullOrEmpty(logPath) ? null : logPath))
                    Application.Run(app);
                GC.KeepAlive(mutex);
                return true;
            }
        }
    }
}
