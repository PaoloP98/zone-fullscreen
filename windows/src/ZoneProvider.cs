// Answers "which zones does this monitor have right now?" from FancyZones' files.
using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Win32;

namespace ZoneFullscreen
{
    public sealed class ZoneProvider : IZoneSource
    {
        private sealed class CachedFile
        {
            public DateTime Stamp;
            public string Text; // last content that parsed as complete JSON
        }

        private readonly string _dir;
        private readonly Dictionary<string, CachedFile> _files = new Dictionary<string, CachedFile>();

        public ZoneProvider(string fancyZonesDir) { _dir = fancyZonesDir; }

        public static string DefaultDirectory
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                    @"Microsoft\PowerToys\FancyZones");
            }
        }

        /// <summary>Zones for the monitor a window is on, plus a label for the layout in use.</summary>
        public List<Rect> GetZones(Native.MONITORINFOEX info, out string description)
        {
            return GetZones(new MonitorArea(info.rcMonitor.ToRect(), info.rcWork.ToRect(), info.szDevice), out description);
        }

        public List<Rect> GetZones(MonitorArea area, out string description)
        {
            Rect monitor = area.Bounds;
            Rect work = area.Work;

            string applied = Read("applied-layouts.json");
            if (applied == null)
            {
                // FancyZones not installed / never used: split ultrawide monitors in two.
                bool ultrawide = monitor.H > 0 && (double)monitor.W / monitor.H >= 2.3;
                description = ultrawide ? "FancyZones not found: two halves" : "FancyZones not found";
                return ultrawide ? LayoutCalculator.Columns(monitor, 2) : new List<Rect>();
            }

            LayoutSpec spec = FancyZonesReader.FindLayout(applied, GetDeviceKey(area.Device));
            if (spec == null)
                spec = FancyZonesReader.FindDefault(Read("default-layouts.json"), monitor.W >= monitor.H);
            if (spec == null)
            {
                description = "No layout for this monitor";
                return new List<Rect>();
            }

            description = FancyZonesReader.Describe(spec);
            return FancyZonesReader.Resolve(spec, Read("custom-layouts.json"), monitor, work);
        }

        // Re-reads a file only when its timestamp changed; a half-written file keeps the previous content.
        private string Read(string name)
        {
            string path = Path.Combine(_dir, name);
            CachedFile cached;
            _files.TryGetValue(name, out cached);
            try
            {
                if (!File.Exists(path)) return cached != null ? cached.Text : null;
                DateTime stamp = File.GetLastWriteTimeUtc(path);
                if (cached != null && cached.Stamp == stamp) return cached.Text;

                string text;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream))
                    text = reader.ReadToEnd();

                if (!FancyZonesReader.IsValidJson(text)) return cached != null ? cached.Text : null;
                _files[name] = new CachedFile { Stamp = stamp, Text = text };
                return text;
            }
            catch (IOException) { return cached != null ? cached.Text : null; }
            catch (UnauthorizedAccessException) { return cached != null ? cached.Text : null; }
        }

        /// <summary>
        /// FancyZones identifies a monitor by the two middle parts of its device interface name:
        /// \\?\DISPLAY#SAM7119#5&amp;d9183b4&amp;0&amp;UID4352#{guid}
        /// </summary>
        public static DeviceKey GetDeviceKey(string adapterDevice)
        {
            string monitor = "", instance = "";
            for (uint i = 0; i < 8; i++)
            {
                var dd = new Native.DISPLAY_DEVICE();
                dd.cb = System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.DISPLAY_DEVICE));
                if (!Native.EnumDisplayDevices(adapterDevice, i, ref dd, Native.EDD_GET_DEVICE_INTERFACE_NAME)) break;
                string[] parts = (dd.DeviceID ?? "").Split('#');
                if (parts.Length < 3) continue;
                bool active = (dd.StateFlags & Native.DISPLAY_DEVICE_ACTIVE) != 0;
                if (monitor.Length == 0 || active)
                {
                    monitor = parts[1];
                    instance = parts[2];
                }
                if (active) break;
            }
            return new DeviceKey(monitor, instance, CurrentVirtualDesktop());
        }

        private static string CurrentVirtualDesktop()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"))
                {
                    var bytes = key != null ? key.GetValue("CurrentVirtualDesktop") as byte[] : null;
                    if (bytes != null && bytes.Length == 16) return new Guid(bytes).ToString("B").ToUpperInvariant();
                }
            }
            catch (Exception) { }
            return FancyZonesReader.ZeroGuid;
        }
    }
}
