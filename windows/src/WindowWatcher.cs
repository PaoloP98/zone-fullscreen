// The Windows side of ZoneKeeper: listens for windows moving, appearing and coming to the
// front, and carries out what the keeper decides through Win32 calls.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace ZoneFullscreen
{
    public sealed class WindowWatcher : IWindowPlatform, IDisposable
    {
        private static readonly HashSet<string> IgnoredClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "MultitaskingViewFrame",
            "XamlExplorerHostIslandWindow", "TaskSwitcherWnd", "ForegroundStaging", "Windows.UI.Core.CoreWindow",
        };
        private const long FrameStyles = Native.WS_CAPTION | Native.WS_THICKFRAME;

        private readonly ZoneKeeper _keeper;
        // What a window looked like before we removed its frame.
        private sealed class Stripped
        {
            public long Style;
            public Rect Rect;
            public bool WasTopmost;
            public uint Pid;
        }

        private readonly Dictionary<IntPtr, Stripped> _stripped = new Dictionary<IntPtr, Stripped>();
        private readonly string _logPath;
        // The stripped windows are also written here, so that the next start can give them their
        // frame back if this process dies without the chance to do it.
        private readonly string _statePath;
        private readonly Native.WinEventDelegate _callback; // field keeps the delegate alive for the hooks
        private IntPtr _locationHook, _foregroundHook, _showHook;

        /// <summary>Last ordinary window the user was in (the tray menu steals focus, so we remember).</summary>
        public IntPtr LastForeground { get; private set; }

        /// <summary>False when Windows refused a hook: the app then cannot see windows going fullscreen.</summary>
        public bool HooksInstalled
        {
            get { return _locationHook != IntPtr.Zero && _foregroundHook != IntPtr.Zero && _showHook != IntPtr.Zero; }
        }

        /// <param name="logPath">File that receives a line per action; null or "" for no log.</param>
        /// <param name="statePath">File that remembers frameless windows across a crash; null or "" for none.</param>
        public WindowWatcher(IZoneSource zones, IZoneSettings settings, string logPath, string statePath)
        {
            _logPath = string.IsNullOrEmpty(logPath) ? null : logPath;
            _statePath = string.IsNullOrEmpty(statePath) ? null : statePath;
            _keeper = new ZoneKeeper(this, zones, settings, Log);
            _callback = OnWinEvent;
        }

        public void Start()
        {
            RestoreAbandoned();
            // Windows that are already open must have a known position before they go fullscreen.
            Native.EnumWindows((hwnd, l) => { Observe(hwnd, false); return true; }, IntPtr.Zero);
            IntPtr fg = Native.GetForegroundWindow();
            if (IsCandidate(fg)) LastForeground = fg;

            uint flags = Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS;
            _locationHook = Native.SetWinEventHook(Native.EVENT_OBJECT_LOCATIONCHANGE, Native.EVENT_OBJECT_LOCATIONCHANGE,
                                                   IntPtr.Zero, _callback, 0, 0, flags);
            _foregroundHook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND,
                                                     IntPtr.Zero, _callback, 0, 0, flags);
            // A window placed before it is shown never reports a move afterwards: catch it when it appears.
            _showHook = Native.SetWinEventHook(Native.EVENT_OBJECT_SHOW, Native.EVENT_OBJECT_SHOW,
                                               IntPtr.Zero, _callback, 0, 0, flags);
            Log("started; hooks " + (_locationHook != IntPtr.Zero) + "/" + (_foregroundHook != IntPtr.Zero) + "/" + (_showHook != IntPtr.Zero));
        }

        private void OnWinEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (hwnd == IntPtr.Zero || idObject != 0 || idChild != 0) return; // only the window itself
            try
            {
                if (evt == Native.EVENT_SYSTEM_FOREGROUND)
                {
                    if (IsCandidate(hwnd)) LastForeground = hwnd;
                    Observe(hwnd, false);
                }
                else
                {
                    Observe(hwnd, evt == Native.EVENT_OBJECT_LOCATIONCHANGE);
                }
            }
            catch (Exception e)
            {
                Log("error: " + e.Message); // never let an exception escape into the hook dispatcher
            }
        }

        private void Observe(IntPtr hwnd, bool mayAct)
        {
            _keeper.Observe(hwnd, mayAct, DateTime.UtcNow);
        }

        /// <summary>Hotkey: strip the borders of a window and fit it to its zone; again to undo.</summary>
        public void ToggleForced(IntPtr hwnd) { _keeper.ToggleForced(hwnd); }

        /// <summary>Process name of a window, lower-case without extension; "" when it cannot be read.</summary>
        public string ProcessName(IntPtr hwnd) { return _keeper.ProcessName(hwnd); }

        /// <summary>Forget windows that no longer exist.</summary>
        public void Prune()
        {
            _keeper.Prune();
            List<IntPtr> gone = _stripped.Keys.Where(h => !Native.IsWindow(h)).ToList();
            foreach (IntPtr hwnd in gone) _stripped.Remove(hwnd);
            if (gone.Count > 0) SaveStripped();
        }

        /// <summary>
        /// Give their frame back to windows a previous run left without one (it crashed or was
        /// killed). Called by Start; returns how many windows were restored.
        /// </summary>
        public int RestoreAbandoned()
        {
            if (_statePath == null || !File.Exists(_statePath)) return 0;
            int restored = 0;
            try
            {
                foreach (string line in File.ReadAllLines(_statePath))
                {
                    IntPtr hwnd;
                    Stripped was;
                    if (!TryParseStripped(line, out hwnd, out was)) continue;
                    // Handles are reused: only touch the window if it still belongs to the same
                    // process and still has no frame.
                    uint pid;
                    Native.GetWindowThreadProcessId(hwnd, out pid);
                    if (!Native.IsWindow(hwnd) || pid != was.Pid) continue;
                    long now = Native.GetWindowLong(hwnd, Native.GWL_STYLE);
                    if ((now & FrameStyles) != 0) continue;

                    Native.SetWindowLong(hwnd, Native.GWL_STYLE, now | (was.Style & FrameStyles));
                    uint flags = Native.SWP_FRAMECHANGED | Native.SWP_NOOWNERZORDER | Native.SWP_NOACTIVATE;
                    if (was.WasTopmost) flags |= Native.SWP_NOZORDER;
                    Native.SetWindowPos(hwnd, Native.HWND_NOTOPMOST, was.Rect.X, was.Rect.Y, was.Rect.W, was.Rect.H, flags);
                    restored++;
                    Log("recovered #" + hwnd.ToInt64().ToString("X") + ", left without a frame by a previous run");
                }
                File.Delete(_statePath);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return restored;
        }

        private static bool TryParseStripped(string line, out IntPtr hwnd, out Stripped was)
        {
            hwnd = IntPtr.Zero;
            was = null;
            string[] f = line.Split(' ');
            long handle, style;
            uint pid;
            int x, y, w, h;
            if (f.Length != 8 || !long.TryParse(f[0], out handle) || !uint.TryParse(f[1], out pid) ||
                !long.TryParse(f[2], out style) || !int.TryParse(f[3], out x) || !int.TryParse(f[4], out y) ||
                !int.TryParse(f[5], out w) || !int.TryParse(f[6], out h) || w <= 0 || h <= 0) return false;
            hwnd = new IntPtr(handle);
            was = new Stripped { Pid = pid, Style = style, Rect = new Rect(x, y, w, h), WasTopmost = f[7] == "1" };
            return true;
        }

        private void SaveStripped()
        {
            if (_statePath == null) return;
            try
            {
                if (_stripped.Count == 0) { File.Delete(_statePath); return; }
                File.WriteAllLines(_statePath, _stripped.Select(p => string.Join(" ",
                    p.Key.ToInt64(), p.Value.Pid, p.Value.Style,
                    p.Value.Rect.X, p.Value.Rect.Y, p.Value.Rect.W, p.Value.Rect.H, p.Value.WasTopmost ? "1" : "0")));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>Stop watching and leave no window stuck: undo always-on-top and forced borders.</summary>
        public void Dispose()
        {
            if (_locationHook != IntPtr.Zero) Native.UnhookWinEvent(_locationHook);
            if (_foregroundHook != IntPtr.Zero) Native.UnhookWinEvent(_foregroundHook);
            if (_showHook != IntPtr.Zero) Native.UnhookWinEvent(_showHook);
            _locationHook = _foregroundHook = _showHook = IntPtr.Zero;

            _keeper.ReleaseAll();
            Log("stopped");
        }

        public void Log(string message)
        {
            if (_logPath == null) return;
            try { File.AppendAllText(_logPath, DateTime.Now.ToString("HH:mm:ss.fff") + " " + message + Environment.NewLine); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        // ---- IWindowPlatform: what ZoneKeeper asks of Windows ----

        public bool IsCandidate(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd) || !Native.IsWindowVisible(hwnd)) return false;
            if (Native.GetAncestor(hwnd, Native.GA_ROOT) != hwnd) return false;
            if ((Native.GetWindowLong(hwnd, Native.GWL_STYLE) & Native.WS_CHILD) != 0) return false;
            string cls = Native.ClassName(hwnd);
            if (IgnoredClasses.Contains(cls) || cls.StartsWith("FancyZones", StringComparison.OrdinalIgnoreCase)) return false;
            return !Native.IsCloaked(hwnd);
        }

        bool IWindowPlatform.IsAlive(IntPtr hwnd) { return Native.IsWindow(hwnd); }
        bool IWindowPlatform.IsMinimized(IntPtr hwnd) { return Native.IsIconic(hwnd); }
        bool IWindowPlatform.IsMaximized(IntPtr hwnd) { return Native.IsZoomed(hwnd); }

        bool IWindowPlatform.IsAlwaysOnTop(IntPtr hwnd)
        {
            return (Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE) & Native.WS_EX_TOPMOST) != 0;
        }

        bool IWindowPlatform.TryGetPlacement(IntPtr hwnd, out Rect rect, out MonitorArea monitor)
        {
            monitor = new MonitorArea();
            IntPtr handle;
            Native.MONITORINFOEX info;
            if (!Native.TryGetRect(hwnd, out rect) || !Native.TryGetMonitor(hwnd, out handle, out info)) return false;
            monitor = new MonitorArea(info.rcMonitor.ToRect(), info.rcWork.ToRect(), info.szDevice);
            return true;
        }

        string IWindowPlatform.ProcessName(IntPtr hwnd)
        {
            try
            {
                uint pid;
                Native.GetWindowThreadProcessId(hwnd, out pid);
                if (pid != 0)
                    using (Process p = Process.GetProcessById((int)pid))
                        return p.ProcessName.ToLowerInvariant();
            }
            catch (Exception) { } // exited, or protected process
            return "";
        }

        // Chromium windows (Edge, Chrome, Electron apps) re-assert their fullscreen size on every
        // focus change, tooltip or popup. The browser extension handles them instead.
        bool IWindowPlatform.ReassertsFullscreen(IntPtr hwnd)
        {
            return Native.ClassName(hwnd).StartsWith("Chrome_WidgetWin", StringComparison.OrdinalIgnoreCase);
        }

        // SetWindowPos is synchronous here on purpose: once it returns the window has seen the move.
        void IWindowPlatform.MoveFullscreenWindow(IntPtr hwnd, Rect target, bool alwaysOnTop)
        {
            // NOSENDCHANGING: Chromium-based apps veto any resize while fullscreen from inside
            // WM_WINDOWPOSCHANGING (they snap back to the monitor size), so that message is skipped.
            uint flags = Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER | Native.SWP_NOSENDCHANGING;
            if (!alwaysOnTop) flags |= Native.SWP_NOZORDER;
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, target.X, target.Y, target.W, target.H, flags);
        }

        void IWindowPlatform.ClearAlwaysOnTop(IntPtr hwnd)
        {
            Native.SetWindowPos(hwnd, Native.HWND_NOTOPMOST, 0, 0, 0, 0,
                Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER | Native.SWP_ASYNCWINDOWPOS);
        }

        void IWindowPlatform.RemoveFrame(IntPtr hwnd, Rect target, bool alwaysOnTop)
        {
            long style = Native.GetWindowLong(hwnd, Native.GWL_STYLE);
            var was = new Stripped { Style = style };
            Native.TryGetRect(hwnd, out was.Rect);
            was.WasTopmost = (Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE) & Native.WS_EX_TOPMOST) != 0;
            Native.GetWindowThreadProcessId(hwnd, out was.Pid);
            _stripped[hwnd] = was;
            SaveStripped();
            Native.SetWindowLong(hwnd, Native.GWL_STYLE, style & ~FrameStyles);
            uint flags = Native.SWP_FRAMECHANGED | Native.SWP_NOOWNERZORDER;
            if (!alwaysOnTop) flags |= Native.SWP_NOZORDER;
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, target.X, target.Y, target.W, target.H, flags);
        }

        void IWindowPlatform.RestoreFrame(IntPtr hwnd, Rect r, bool clearAlwaysOnTop)
        {
            Stripped was;
            if (_stripped.TryGetValue(hwnd, out was))
            {
                // Put back only the bits we removed: the window may have been hidden, minimized
                // or disabled since, and those bits must stay as they are now.
                long now = Native.GetWindowLong(hwnd, Native.GWL_STYLE);
                Native.SetWindowLong(hwnd, Native.GWL_STYLE, (now & ~FrameStyles) | (was.Style & FrameStyles));
                _stripped.Remove(hwnd);
                SaveStripped();
            }
            IntPtr after = clearAlwaysOnTop ? Native.HWND_NOTOPMOST : IntPtr.Zero;
            uint flags = Native.SWP_FRAMECHANGED | Native.SWP_NOOWNERZORDER | Native.SWP_NOACTIVATE;
            if (!clearAlwaysOnTop) flags |= Native.SWP_NOZORDER;
            Native.SetWindowPos(hwnd, after, r.X, r.Y, r.W, r.H, flags);
        }

        void IWindowPlatform.Maximize(IntPtr hwnd) { Native.ShowWindow(hwnd, Native.SW_MAXIMIZE); }
        void IWindowPlatform.Unmaximize(IntPtr hwnd) { Native.ShowWindow(hwnd, Native.SW_RESTORE); }
    }
}
