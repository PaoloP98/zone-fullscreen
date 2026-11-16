// Decides when a window that went fullscreen is confined to its zone, and when it is let go.
// No operating-system calls here: windows, zones and settings are reached through the interfaces
// below, so this logic runs unchanged in the unit tests and can be reused on another platform.
using System;
using System.Collections.Generic;
using System.Linq;

namespace ZoneFullscreen
{
    /// <summary>A monitor as the platform reports it.</summary>
    public struct MonitorArea
    {
        public Rect Bounds;   // the whole monitor
        public Rect Work;     // without the taskbar / dock
        public string Device; // the platform's own name for it; only the zone source interprets it

        public MonitorArea(Rect bounds, Rect work, string device)
        {
            Bounds = bounds;
            Work = work;
            Device = device;
        }
    }

    /// <summary>What the logic needs to know about, and do to, windows. One implementation per platform.</summary>
    public interface IWindowPlatform
    {
        /// <summary>An ordinary, visible, top-level application window (not the desktop, a panel, a child...).</summary>
        bool IsCandidate(IntPtr window);
        bool IsAlive(IntPtr window);
        bool IsMinimized(IntPtr window);
        bool IsMaximized(IntPtr window);
        bool IsAlwaysOnTop(IntPtr window);
        bool TryGetPlacement(IntPtr window, out Rect rect, out MonitorArea monitor);
        /// <summary>Lower-case process name without extension; "" when it cannot be read.</summary>
        string ProcessName(IntPtr window);
        /// <summary>
        /// The window takes its fullscreen size back on every focus change (Chromium does), so
        /// confining it from outside flickers; such windows are left to the browser extension.
        /// </summary>
        bool ReassertsFullscreen(IntPtr window);

        /// <summary>
        /// Resize a window that is in its own fullscreen. Must not return before the window has
        /// seen the move: a later "covers the monitor" can then only mean it resized itself back.
        /// </summary>
        void MoveFullscreenWindow(IntPtr window, Rect target, bool alwaysOnTop);
        void ClearAlwaysOnTop(IntPtr window);
        /// <summary>Strip title bar and borders and place the window.</summary>
        void RemoveFrame(IntPtr window, Rect target, bool alwaysOnTop);
        /// <summary>Undo RemoveFrame and place the window.</summary>
        void RestoreFrame(IntPtr window, Rect rect, bool clearAlwaysOnTop);
        void Maximize(IntPtr window);
        void Unmaximize(IntPtr window);
    }

    /// <summary>Where the zones of a monitor come from (FancyZones on Windows).</summary>
    public interface IZoneSource
    {
        List<Rect> GetZones(MonitorArea monitor, out string description);
    }

    public interface IZoneSettings
    {
        bool Enabled { get; }
        /// <summary>Use the whole zone and stay above the taskbar, like real fullscreen does.</summary>
        bool CoverTaskbar { get; }
        /// <summary>Confine windows that re-assert their fullscreen size too (they flicker).</summary>
        bool ConfineReassertingWindows { get; }
        bool IsExcluded(string process);
    }

    public sealed class ZoneKeeper
    {
        private sealed class WinState
        {
            // Last positions seen while NOT fullscreen. "Settled" has survived SettleTime, so it is
            // not a transient frame of the app's own enter-fullscreen transition.
            public bool HasSettled, HasPending;
            public Rect Settled, Pending;
            public DateTime PendingAt;

            public bool Zoned;        // we confined it to ZoneRect
            public Rect ZoneRect;
            public bool MadeTopmost;  // we made it always-on-top (it was not before)
            public DateTime MovedAt;  // when we last put it in its zone
            public bool GaveUp;       // it kept fighting back; leave it until it exits fullscreen

            public bool Forced;       // confined on request: frame removed by us
            public Rect SavedRect;
            public bool SavedMaximized;

            public string Process;    // cached process name, "" when unknown
        }

        public static readonly TimeSpan SettleTime = TimeSpan.FromMilliseconds(150);
        // A resize back to the monitor this soon after our move is the app fighting us; later ones are
        // side effects of focus changes (Chromium re-asserts its fullscreen size then) and are just undone.
        public static readonly TimeSpan RetaliationTime = TimeSpan.FromMilliseconds(150);
        private const double WholeMonitorShare = 0.9;

        private readonly Dictionary<IntPtr, WinState> _states = new Dictionary<IntPtr, WinState>();
        private readonly FightGuard _guard = new FightGuard(5, TimeSpan.FromSeconds(2));
        // Second budget that slow retaliation never refills: an app that takes the monitor back on a
        // timer (or on every focus change, endlessly) is given up on instead of flickering forever.
        private readonly FightGuard _longGuard = new FightGuard(10, TimeSpan.FromSeconds(30));
        private readonly IWindowPlatform _platform;
        private readonly IZoneSource _zones;
        private readonly IZoneSettings _settings;
        private readonly Action<string> _log;

        public ZoneKeeper(IWindowPlatform platform, IZoneSource zones, IZoneSettings settings, Action<string> log)
        {
            _platform = platform;
            _zones = zones;
            _settings = settings;
            _log = log ?? (message => { });
        }

        public bool IsZoned(IntPtr window) { WinState s; return _states.TryGetValue(window, out s) && s.Zoned; }
        public bool IsForced(IntPtr window) { WinState s; return _states.TryGetValue(window, out s) && s.Forced; }
        public bool HasGivenUp(IntPtr window) { WinState s; return _states.TryGetValue(window, out s) && s.GaveUp; }

        /// <summary>
        /// Call whenever a window moved, appeared or came to the front. It only acts when
        /// <paramref name="mayAct"/> is set (the window actually moved); otherwise it just takes note.
        /// </summary>
        public void Observe(IntPtr window, bool mayAct, DateTime now)
        {
            WinState state;
            bool known = _states.TryGetValue(window, out state);
            if (!_platform.IsCandidate(window)) return;
            if (known && state.Forced) return;
            if (_platform.IsMinimized(window)) return;

            Rect rect;
            MonitorArea monitor;
            if (!_platform.TryGetPlacement(window, out rect, out monitor)) return;
            Rect monitorRect = monitor.Bounds;

            if (!known) _states[window] = state = new WinState();

            // Chromium parks a fullscreen window that lost focus at the monitor size minus one pixel row.
            bool parked = rect.X == monitorRect.X && rect.Y == monitorRect.Y &&
                          rect.W == monitorRect.W && rect.H == monitorRect.H - 1;

            if (rect != monitorRect && !parked)
            {
                if (state.Zoned)
                {
                    if (rect == state.ZoneRect) return; // the echo of our own move
                    ReleaseZoned(window, state);        // the app left fullscreen and restored itself
                    _log("released " + Describe(window, state) + " -> " + rect);
                }
                if (state.GaveUp)
                {
                    state.GaveUp = false;
                    _guard.Reset(window);
                    _longGuard.Reset(window);
                }
                if (state.HasPending && now - state.PendingAt >= SettleTime)
                {
                    state.Settled = state.Pending;
                    state.HasSettled = true;
                }
                state.Pending = rect;
                state.PendingAt = now;
                state.HasPending = true;
                return;
            }

            // ---- the window now covers the whole monitor ----
            if (state.GaveUp) return; // left alone until it exits fullscreen

            if (state.Zoned)
            {
                // The app took the whole monitor back after we confined it.
                if (now - state.MovedAt >= RetaliationTime) _guard.Reset(window);
                if (_settings.Enabled && _guard.Allow(window, now) && _longGuard.Allow(window, now))
                {
                    MoveToZone(window, state.ZoneRect);
                    state.MovedAt = now;
                    _log("re-zoned " + Describe(window, state) + " (it went back to " + rect + ")");
                }
                else
                {
                    ReleaseZoned(window, state);
                    state.GaveUp = true;
                    _log("gave up on " + Describe(window, state));
                }
                return;
            }
            if (!mayAct || parked || !_settings.Enabled) return;
            if (_platform.IsMaximized(window)) return; // maximized before fullscreen: it owned the whole screen already

            Rect origin;
            if (state.HasPending && now - state.PendingAt >= SettleTime) origin = state.Pending;
            else if (state.HasSettled) origin = state.Settled;
            else if (state.HasPending) origin = state.Pending;
            else { _log("skipped " + Describe(window, state) + ": no known position before fullscreen"); return; }

            if (origin.OverlapArea(monitorRect) >= WholeMonitorShare * monitorRect.Area) return; // it already spanned the screen
            if (_settings.IsExcluded(ProcessName(window, state))) return;
            if (!_settings.ConfineReassertingWindows && _platform.ReassertsFullscreen(window)) return;

            string layout;
            List<Rect> zones = _zones.GetZones(monitor, out layout);
            Rect zone;
            if (zones.Count < 2 || !ZonePicker.TryPick(zones, origin, out zone)) return;

            Rect target = _settings.CoverTaskbar ? zone : zone.Intersect(monitor.Work);
            if (target.IsEmpty || target == monitorRect) return;

            _guard.Reset(window);
            _guard.Allow(window, now);
            _longGuard.Reset(window);

            state.MadeTopmost = _settings.CoverTaskbar && !_platform.IsAlwaysOnTop(window);
            state.Zoned = true;
            state.ZoneRect = target;
            state.MovedAt = now;
            MoveToZone(window, target);
            _log("zoned " + Describe(window, state) + " from " + origin + " to " + target + " [" + layout + "]");
        }

        private void MoveToZone(IntPtr window, Rect target)
        {
            // Always-on-top keeps the window above the taskbar, like real fullscreen on its own monitor.
            _platform.MoveFullscreenWindow(window, target, _settings.CoverTaskbar);
            Rect after;
            MonitorArea monitor;
            if (_platform.TryGetPlacement(window, out after, out monitor) && after != target)
                _log("move refused: window is at " + after);
        }

        private void ReleaseZoned(IntPtr window, WinState state)
        {
            if (state.MadeTopmost) _platform.ClearAlwaysOnTop(window);
            state.Zoned = false;
            state.MadeTopmost = false;
        }

        /// <summary>On request: strip the frame of a window and fit it to its zone; again to undo.</summary>
        public void ToggleForced(IntPtr window)
        {
            if (!_platform.IsCandidate(window)) return;
            WinState state;
            if (!_states.TryGetValue(window, out state)) _states[window] = state = new WinState();

            if (state.Forced)
            {
                RestoreForced(window, state);
                return;
            }
            if (state.Zoned) return; // already confined by the app's own fullscreen

            Rect rect;
            MonitorArea monitor;
            if (!_platform.TryGetPlacement(window, out rect, out monitor)) return;

            string layout;
            List<Rect> zones = _zones.GetZones(monitor, out layout);
            Rect zone;
            if (zones.Count < 2 || !ZonePicker.TryPick(zones, rect, out zone)) return;
            Rect target = _settings.CoverTaskbar ? zone : zone.Intersect(monitor.Work);
            if (target.IsEmpty) return;

            state.SavedMaximized = _platform.IsMaximized(window);
            if (state.SavedMaximized)
            {
                _platform.Unmaximize(window);
                MonitorArea ignored;
                _platform.TryGetPlacement(window, out rect, out ignored);
            }
            state.SavedRect = rect;
            state.MadeTopmost = _settings.CoverTaskbar && !_platform.IsAlwaysOnTop(window);
            state.Forced = true;

            _platform.RemoveFrame(window, target, _settings.CoverTaskbar);
            _log("forced " + Describe(window, state) + " to " + target);
        }

        private void RestoreForced(IntPtr window, WinState state)
        {
            _platform.RestoreFrame(window, state.SavedRect, state.MadeTopmost);
            if (state.SavedMaximized) _platform.Maximize(window);
            state.Forced = false;
            state.MadeTopmost = false;
            _log("restored " + Describe(window, state));
        }

        /// <summary>Process name of a window, lower-case without extension; "" when it cannot be read.</summary>
        public string ProcessName(IntPtr window)
        {
            WinState state;
            _states.TryGetValue(window, out state);
            return ProcessName(window, state);
        }

        private string ProcessName(IntPtr window, WinState state)
        {
            if (state != null && state.Process != null) return state.Process;
            string name = _platform.ProcessName(window) ?? "";
            if (state != null) state.Process = name;
            return name;
        }

        /// <summary>Forget windows that no longer exist.</summary>
        public void Prune()
        {
            foreach (IntPtr window in _states.Keys.Where(w => !_platform.IsAlive(w)).ToList())
            {
                _states.Remove(window);
                _guard.Reset(window);
                _longGuard.Reset(window);
            }
        }

        /// <summary>Leave no window stuck: give forced windows their frame back, undo always-on-top.</summary>
        public void ReleaseAll()
        {
            foreach (var pair in _states)
            {
                if (!_platform.IsAlive(pair.Key)) continue;
                if (pair.Value.Forced) RestoreForced(pair.Key, pair.Value);
                else if (pair.Value.Zoned) ReleaseZoned(pair.Key, pair.Value);
            }
        }

        private string Describe(IntPtr window, WinState state)
        {
            return ProcessName(window, state) + "#" + window.ToInt64().ToString("X");
        }
    }
}
