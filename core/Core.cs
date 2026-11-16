// Pure logic: no Win32 here, so it can be tested on its own.
// NOTE: this project is compiled by Windows PowerShell's Add-Type, i.e. C# 5 on .NET Framework 4.8.
using System;
using System.Collections.Generic;
using System.Linq;

namespace ZoneFullscreen
{
    /// <summary>Screen rectangle in physical pixels.</summary>
    public struct Rect : IEquatable<Rect>
    {
        public int X, Y, W, H;

        public Rect(int x, int y, int w, int h) { X = x; Y = y; W = w; H = h; }

        public int Right { get { return X + W; } }
        public int Bottom { get { return Y + H; } }
        public bool IsEmpty { get { return W <= 0 || H <= 0; } }
        public long Area { get { return IsEmpty ? 0 : (long)W * H; } }

        public static Rect FromEdges(int left, int top, int right, int bottom)
        {
            return new Rect(left, top, right - left, bottom - top);
        }

        public long OverlapArea(Rect other)
        {
            long w = Math.Min(Right, other.Right) - Math.Max(X, other.X);
            long h = Math.Min(Bottom, other.Bottom) - Math.Max(Y, other.Y);
            return w > 0 && h > 0 ? w * h : 0;
        }

        public bool Contains(int px, int py) { return px >= X && px < Right && py >= Y && py < Bottom; }

        public Rect Intersect(Rect other)
        {
            return FromEdges(Math.Max(X, other.X), Math.Max(Y, other.Y),
                             Math.Min(Right, other.Right), Math.Min(Bottom, other.Bottom));
        }

        public bool Equals(Rect o) { return X == o.X && Y == o.Y && W == o.W && H == o.H; }
        public override bool Equals(object obj) { return obj is Rect && Equals((Rect)obj); }
        public override int GetHashCode() { return ((X * 397 ^ Y) * 397 ^ W) * 397 ^ H; }
        public static bool operator ==(Rect a, Rect b) { return a.Equals(b); }
        public static bool operator !=(Rect a, Rect b) { return !a.Equals(b); }
        public override string ToString() { return string.Format("({0},{1} {2}x{3})", X, Y, W, H); }
    }

    /// <summary>
    /// Recomputes FancyZones template layouts as rectangles, without spacing.
    /// Mirrors PowerToys' LayoutConfigurator.cpp.
    /// </summary>
    public static class LayoutCalculator
    {
        private const int Multiplier = 10000;

        private sealed class GridDef
        {
            public readonly int[] Rows; public readonly int[] Cols; public readonly int[][] Map;
            public GridDef(int[] rows, int[] cols, int[][] map) { Rows = rows; Cols = cols; Map = map; }
        }

        private static readonly int[] Thirds = { 3333, 3334, 3333 };
        private static readonly int[] Halves = { 5000, 5000 };
        private static readonly int[] Wide3 = { 2500, 5000, 2500 };
        private static readonly int[] Quarters = { 2500, 2500, 2500, 2500 };

        // predefinedPriorityGridLayouts from PowerToys, index = zoneCount - 1.
        private static readonly GridDef[] PriorityGrids =
        {
            new GridDef(new[] { 10000 }, new[] { 10000 }, new[] { new[] { 0 } }),
            new GridDef(new[] { 10000 }, new[] { 6667, 3333 }, new[] { new[] { 0, 1 } }),
            new GridDef(new[] { 10000 }, Wide3, new[] { new[] { 0, 1, 2 } }),
            new GridDef(Halves, Wide3, new[] { new[] { 0, 1, 2 }, new[] { 0, 1, 3 } }),
            new GridDef(Halves, Wide3, new[] { new[] { 0, 1, 2 }, new[] { 3, 1, 4 } }),
            new GridDef(Thirds, Wide3, new[] { new[] { 0, 1, 2 }, new[] { 0, 1, 3 }, new[] { 4, 1, 5 } }),
            new GridDef(Thirds, Wide3, new[] { new[] { 0, 1, 2 }, new[] { 3, 1, 4 }, new[] { 5, 1, 6 } }),
            new GridDef(Thirds, Quarters, new[] { new[] { 0, 1, 2, 3 }, new[] { 4, 1, 2, 5 }, new[] { 6, 1, 2, 7 } }),
            new GridDef(Thirds, Quarters, new[] { new[] { 0, 1, 2, 3 }, new[] { 4, 1, 2, 5 }, new[] { 6, 1, 7, 8 } }),
            new GridDef(Thirds, Quarters, new[] { new[] { 0, 1, 2, 3 }, new[] { 4, 1, 5, 6 }, new[] { 7, 1, 8, 9 } }),
            new GridDef(Thirds, Quarters, new[] { new[] { 0, 1, 2, 3 }, new[] { 4, 1, 5, 6 }, new[] { 7, 8, 9, 10 } }),
        };

        public static List<Rect> Columns(Rect area, int n)
        {
            var zones = new List<Rect>();
            for (int i = 0; i < n; i++)
            {
                int left = area.X + (int)((long)i * area.W / n);
                int right = area.X + (int)((long)(i + 1) * area.W / n);
                zones.Add(Rect.FromEdges(left, area.Y, right, area.Bottom));
            }
            return zones;
        }

        public static List<Rect> Rows(Rect area, int n)
        {
            var zones = new List<Rect>();
            for (int i = 0; i < n; i++)
            {
                int top = area.Y + (int)((long)i * area.H / n);
                int bottom = area.Y + (int)((long)(i + 1) * area.H / n);
                zones.Add(Rect.FromEdges(area.X, top, area.Right, bottom));
            }
            return zones;
        }

        public static List<Rect> Grid(Rect area, int n)
        {
            if (n <= 0) return new List<Rect>();
            int rows = 1;
            while (n / rows >= rows) rows++;
            rows--;
            int cols = n / rows;
            if (n % rows != 0) cols++;

            var map = new int[rows][];
            int index = 0;
            for (int r = 0; r < rows; r++)
            {
                map[r] = new int[cols];
                for (int c = 0; c < cols; c++)
                {
                    map[r][c] = index++;
                    if (index == n) index--;
                }
            }
            return FromGrid(area, EqualPercents(rows), EqualPercents(cols), map);
        }

        public static List<Rect> PriorityGrid(Rect area, int n)
        {
            if (n <= 0) return new List<Rect>();
            if (n > PriorityGrids.Length) return Grid(area, n);
            GridDef def = PriorityGrids[n - 1];
            return FromGrid(area, def.Rows, def.Cols, def.Map);
        }

        /// <summary>Zones of a grid layout: each zone is the bounding box of the cells carrying its id.</summary>
        public static List<Rect> FromGrid(Rect area, int[] rowPct, int[] colPct, int[][] map)
        {
            var result = new List<Rect>();
            if (rowPct == null || colPct == null || map == null) return result;
            if (rowPct.Length == 0 || colPct.Length == 0 || map.Length != rowPct.Length) return result;
            foreach (int[] row in map)
                if (row == null || row.Length != colPct.Length) return result;

            int[] ys = Offsets(rowPct, area.Y, area.H);
            int[] xs = Offsets(colPct, area.X, area.W);

            // id -> { firstRow, firstCol, lastRow, lastCol }
            var bounds = new SortedDictionary<int, int[]>();
            for (int r = 0; r < map.Length; r++)
            {
                for (int c = 0; c < map[r].Length; c++)
                {
                    int[] b;
                    if (bounds.TryGetValue(map[r][c], out b))
                    {
                        b[0] = Math.Min(b[0], r); b[1] = Math.Min(b[1], c);
                        b[2] = Math.Max(b[2], r); b[3] = Math.Max(b[3], c);
                    }
                    else
                    {
                        bounds[map[r][c]] = new[] { r, c, r, c };
                    }
                }
            }

            foreach (int[] b in bounds.Values)
            {
                Rect zone = Rect.FromEdges(xs[b[1]], ys[b[0]], xs[b[3] + 1], ys[b[2] + 1]);
                if (!zone.IsEmpty) result.Add(zone);
            }
            return result;
        }

        /// <summary>Canvas zones are stored against a reference size and scaled to the work area.</summary>
        public static List<Rect> Canvas(Rect workArea, int refW, int refH, IEnumerable<Rect> zones)
        {
            var result = new List<Rect>();
            if (refW <= 0 || refH <= 0) return result;
            foreach (Rect z in zones)
            {
                Rect scaled = Rect.FromEdges(
                    workArea.X + (int)((long)z.X * workArea.W / refW),
                    workArea.Y + (int)((long)z.Y * workArea.H / refH),
                    workArea.X + (int)((long)z.Right * workArea.W / refW),
                    workArea.Y + (int)((long)z.Bottom * workArea.H / refH));
                if (!scaled.IsEmpty) result.Add(scaled);
            }
            return result;
        }

        private static int[] EqualPercents(int n)
        {
            var p = new int[n];
            for (int i = 0; i < n; i++) p[i] = Multiplier * (i + 1) / n - Multiplier * i / n;
            return p;
        }

        // Edge positions; the last edge is pinned to the far side so zones always tile the area.
        private static int[] Offsets(int[] pct, int origin, int total)
        {
            var edges = new int[pct.Length + 1];
            long sum = 0;
            foreach (int p in pct) sum += Math.Max(p, 0);
            if (sum <= 0) sum = 1;
            long cum = 0;
            for (int i = 0; i < pct.Length; i++)
            {
                edges[i] = origin + (int)(cum * total / sum);
                cum += Math.Max(pct[i], 0);
            }
            edges[pct.Length] = origin + total;
            return edges;
        }
    }

    public static class ZonePicker
    {
        /// <summary>
        /// The zone a window belongs to: largest overlap, ties broken by the zone containing
        /// the window's center. Returns false when the window touches no zone.
        /// </summary>
        public static bool TryPick(IList<Rect> zones, Rect window, out Rect picked)
        {
            picked = new Rect();
            bool found = false, bestHasCenter = false;
            long bestArea = 0;
            int cx = window.X + window.W / 2, cy = window.Y + window.H / 2;

            foreach (Rect zone in zones)
            {
                long area = zone.OverlapArea(window);
                if (area == 0) continue;
                bool hasCenter = zone.Contains(cx, cy);
                if (area > bestArea || (area == bestArea && hasCenter && !bestHasCenter))
                {
                    picked = zone;
                    bestArea = area;
                    bestHasCenter = hasCenter;
                    found = true;
                }
            }
            return found;
        }
    }

    /// <summary>Stops resize wars: allows a few interventions per window in a short time span.</summary>
    public sealed class FightGuard
    {
        private readonly int _max;
        private readonly TimeSpan _span;
        private readonly Dictionary<IntPtr, List<DateTime>> _hits = new Dictionary<IntPtr, List<DateTime>>();

        public FightGuard() : this(3, TimeSpan.FromSeconds(2)) { }
        public FightGuard(int max, TimeSpan span) { _max = max; _span = span; }

        public bool Allow(IntPtr hwnd, DateTime now)
        {
            List<DateTime> hits;
            if (!_hits.TryGetValue(hwnd, out hits)) _hits[hwnd] = hits = new List<DateTime>();
            hits.RemoveAll(t => now - t > _span);
            if (hits.Count >= _max) return false;
            hits.Add(now);
            return true;
        }

        public void Reset(IntPtr hwnd) { _hits.Remove(hwnd); }
    }
}
