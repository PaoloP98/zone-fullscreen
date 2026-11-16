// Stand-ins for the operating system, so ZoneKeeper can be tested without real windows.
using System;
using System.Collections.Generic;

namespace ZoneFullscreen.Tests
{
    public sealed class FakeWindow
    {
        public Rect Rect;
        public bool Candidate = true, Alive = true, Minimized, Maximized, AlwaysOnTop, Framed = true, Reasserts;
        public bool RefusesMoves;      // ignores our resize, like a window that vetoes it
        public string Process = "app";
        public int Moves;              // how many times we resized it while fullscreen
        public Rect RestoredRect;      // where it sat before being maximized
    }

    public sealed class FakePlatform : IWindowPlatform
    {
        public readonly Dictionary<IntPtr, FakeWindow> Windows = new Dictionary<IntPtr, FakeWindow>();
        public MonitorArea Monitor;

        public FakeWindow Add(int id, Rect rect)
        {
            var w = new FakeWindow { Rect = rect, RestoredRect = rect };
            Windows[new IntPtr(id)] = w;
            return w;
        }

        private FakeWindow W(IntPtr h) { FakeWindow w; Windows.TryGetValue(h, out w); return w; }

        public bool IsCandidate(IntPtr h) { var w = W(h); return w != null && w.Alive && w.Candidate; }
        public bool IsAlive(IntPtr h) { var w = W(h); return w != null && w.Alive; }
        public bool IsMinimized(IntPtr h) { return W(h).Minimized; }
        public bool IsMaximized(IntPtr h) { return W(h).Maximized; }
        public bool IsAlwaysOnTop(IntPtr h) { return W(h).AlwaysOnTop; }
        public string ProcessName(IntPtr h) { return W(h).Process; }
        public bool ReassertsFullscreen(IntPtr h) { return W(h).Reasserts; }

        public bool TryGetPlacement(IntPtr h, out Rect rect, out MonitorArea monitor)
        {
            var w = W(h);
            rect = w != null ? w.Rect : new Rect();
            monitor = Monitor;
            return w != null && w.Alive;
        }

        public void MoveFullscreenWindow(IntPtr h, Rect target, bool alwaysOnTop)
        {
            var w = W(h);
            w.Moves++;
            if (!w.RefusesMoves) w.Rect = target;
            if (alwaysOnTop) w.AlwaysOnTop = true;
        }

        public void ClearAlwaysOnTop(IntPtr h) { W(h).AlwaysOnTop = false; }

        public void RemoveFrame(IntPtr h, Rect target, bool alwaysOnTop)
        {
            var w = W(h);
            w.Framed = false;
            w.Rect = target;
            if (alwaysOnTop) w.AlwaysOnTop = true;
        }

        public void RestoreFrame(IntPtr h, Rect rect, bool clearAlwaysOnTop)
        {
            var w = W(h);
            w.Framed = true;
            w.Rect = rect;
            if (clearAlwaysOnTop) w.AlwaysOnTop = false;
        }

        public void Maximize(IntPtr h) { var w = W(h); w.RestoredRect = w.Rect; w.Maximized = true; w.Rect = Monitor.Work; }
        public void Unmaximize(IntPtr h) { var w = W(h); w.Maximized = false; w.Rect = w.RestoredRect; }
    }

    public sealed class FakeZones : IZoneSource
    {
        public List<Rect> Zones = new List<Rect>();
        public List<Rect> GetZones(MonitorArea monitor, out string description)
        {
            description = "fake";
            return Zones;
        }
    }

    public sealed class FakeSettings : IZoneSettings
    {
        public FakeSettings() { Enabled = true; CoverTaskbar = true; Excluded = new List<string>(); }
        public bool Enabled { get; set; }
        public bool CoverTaskbar { get; set; }
        public bool ConfineReassertingWindows { get; set; }
        public List<string> Excluded { get; set; }
        public bool IsExcluded(string process) { return Excluded.Contains(process); }
    }

    public sealed class Messages
    {
        public readonly List<string> Lines = new List<string>();
        public Action<string> Sink { get { return Lines.Add; } }
    }
}
