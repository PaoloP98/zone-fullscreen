// Reads FancyZones' own files to learn which zones are applied to a monitor.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;

namespace ZoneFullscreen
{
    public sealed class LayoutSpec
    {
        public readonly string Type;
        public readonly int ZoneCount;
        public readonly string Uuid;
        public LayoutSpec(string type, int zoneCount, string uuid) { Type = type ?? ""; ZoneCount = zoneCount; Uuid = uuid ?? ""; }
    }

    /// <summary>Identifies a monitor the way FancyZones does in applied-layouts.json.</summary>
    public sealed class DeviceKey
    {
        public readonly string Monitor;
        public readonly string Instance;
        public readonly string VirtualDesktop;
        public DeviceKey(string monitor, string instance, string virtualDesktop)
        {
            Monitor = monitor ?? ""; Instance = instance ?? ""; VirtualDesktop = virtualDesktop ?? "";
        }
    }

    public static class FancyZonesReader
    {
        public const string ZeroGuid = "{00000000-0000-0000-0000-000000000000}";

        /// <summary>True when the text is a complete JSON document (FancyZones may be mid-write).</summary>
        public static bool IsValidJson(string json)
        {
            return Parse(json) != null;
        }

        /// <summary>Layout applied to the given monitor, or null if none / unreadable.</summary>
        public static LayoutSpec FindLayout(string appliedJson, DeviceKey key)
        {
            LayoutSpec current = null, zero = null, first = null;
            foreach (object item in List(Parse(appliedJson), "applied-layouts"))
            {
                var entry = item as IDictionary<string, object>;
                var dev = Obj(entry, "device");
                var lay = Obj(entry, "applied-layout");
                if (dev == null || lay == null) continue;
                if (!Same(Str(dev, "monitor"), key.Monitor) || !Same(Str(dev, "monitor-instance"), key.Instance)) continue;

                var spec = new LayoutSpec(Str(lay, "type"), Int(lay, "zone-count"), Str(lay, "uuid"));
                string vd = Str(dev, "virtual-desktop");
                if (first == null) first = spec;
                if (current == null && Same(vd, key.VirtualDesktop)) current = spec;
                if (zero == null && Same(vd, ZeroGuid)) zero = spec;
            }
            return current ?? zero ?? first;
        }

        /// <summary>What FancyZones applies to a monitor that has no entry yet (default-layouts.json).</summary>
        public static LayoutSpec FindDefault(string defaultJson, bool horizontal)
        {
            string wanted = horizontal ? "horizontal" : "vertical";
            foreach (object item in List(Parse(defaultJson), "default-layouts"))
            {
                var entry = item as IDictionary<string, object>;
                if (!Same(Str(entry, "monitor-configuration"), wanted)) continue;
                var lay = Obj(entry, "layout");
                if (lay == null) return null;
                return new LayoutSpec(Str(lay, "type"), Int(lay, "zone-count"), Str(lay, "uuid"));
            }
            return null;
        }

        /// <summary>Zone rectangles for a layout. Empty when the layout has no usable zones.</summary>
        public static List<Rect> Resolve(LayoutSpec spec, string customJson, Rect monitor, Rect workArea)
        {
            switch (spec.Type.ToLowerInvariant())
            {
                case "columns": return LayoutCalculator.Columns(monitor, spec.ZoneCount);
                case "rows": return LayoutCalculator.Rows(monitor, spec.ZoneCount);
                case "grid": return LayoutCalculator.Grid(monitor, spec.ZoneCount);
                case "priority-grid": return LayoutCalculator.PriorityGrid(monitor, spec.ZoneCount);
                case "custom": return ResolveCustom(spec.Uuid, customJson, monitor, workArea);
                default: return new List<Rect>(); // focus, blank, unknown
            }
        }

        public static string Describe(LayoutSpec spec)
        {
            if (spec == null) return "none";
            switch (spec.Type.ToLowerInvariant())
            {
                case "columns": return "Columns (" + spec.ZoneCount + " zones)";
                case "rows": return "Rows (" + spec.ZoneCount + " zones)";
                case "grid": return "Grid (" + spec.ZoneCount + " zones)";
                case "priority-grid": return "Priority grid (" + spec.ZoneCount + " zones)";
                case "custom": return "Custom";
                case "focus": return "Focus (not handled)";
                case "blank": return "No layout";
                default: return spec.Type;
            }
        }

        private static List<Rect> ResolveCustom(string uuid, string customJson, Rect monitor, Rect workArea)
        {
            foreach (object item in List(Parse(customJson), "custom-layouts"))
            {
                var layout = item as IDictionary<string, object>;
                if (!Same(Str(layout, "uuid"), uuid)) continue;
                var info = Obj(layout, "info");
                if (info == null) break;

                if (Same(Str(layout, "type"), "grid"))
                {
                    int[][] map = List(info, "cell-child-map").Select(row => IntArray(row)).ToArray();
                    return LayoutCalculator.FromGrid(monitor,
                        IntArray(Raw(info, "rows-percentage")), IntArray(Raw(info, "columns-percentage")), map);
                }
                if (Same(Str(layout, "type"), "canvas"))
                {
                    var rects = new List<Rect>();
                    foreach (object z in List(info, "zones"))
                    {
                        var zone = z as IDictionary<string, object>;
                        if (zone != null) rects.Add(new Rect(Int(zone, "X"), Int(zone, "Y"), Int(zone, "width"), Int(zone, "height")));
                    }
                    return LayoutCalculator.Canvas(workArea, Int(info, "ref-width"), Int(info, "ref-height"), rects);
                }
                break;
            }
            return new List<Rect>();
        }

        // ---- tolerant JSON helpers: wrong shapes yield empty values, never exceptions ----

        private static IDictionary<string, object> Parse(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return null;
            try
            {
                var serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = int.MaxValue;
                return serializer.DeserializeObject(json) as IDictionary<string, object>;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static bool Same(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }

        private static object Raw(IDictionary<string, object> o, string name)
        {
            object v;
            return o != null && o.TryGetValue(name, out v) ? v : null;
        }

        private static IDictionary<string, object> Obj(IDictionary<string, object> o, string name)
        {
            return Raw(o, name) as IDictionary<string, object>;
        }

        private static IEnumerable<object> List(IDictionary<string, object> o, string name)
        {
            var list = Raw(o, name) as IEnumerable;
            if (list == null || list is string) return Enumerable.Empty<object>();
            return list.Cast<object>();
        }

        private static string Str(IDictionary<string, object> o, string name)
        {
            return Raw(o, name) as string ?? "";
        }

        private static int Int(IDictionary<string, object> o, string name) { return ToInt(Raw(o, name)); }

        private static int ToInt(object v)
        {
            if (v == null || v is string || v is bool) return 0;
            try { return (int)Convert.ToDouble(v); }
            catch (Exception) { return 0; }
        }

        private static int[] IntArray(object v)
        {
            var list = v as IEnumerable;
            if (list == null || v is string) return new int[0];
            return list.Cast<object>().Select(ToInt).ToArray();
        }
    }
}
