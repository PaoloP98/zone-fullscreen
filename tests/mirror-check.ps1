# Checks the "share a zone" mirror window: what a capturer sees in it must match the zone on screen.
# Run:  powershell -NoProfile -File tests\mirror-check.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class Cap {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(long point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    // Top-level window that would receive a click at this screen point.
    public static IntPtr TopLevelAt(int x, int y) { return GetAncestor(WindowFromPoint(((long)y << 32) | (uint)x), 2); }
    // What a compositor-based capturer (as call apps use) gets for this window, wherever it is.
    public static Bitmap Window(IntPtr hwnd, int w, int h) {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); PrintWindow(hwnd, dc, 2); g.ReleaseHdc(dc); }
        return bmp;
    }
    public static Bitmap Screen(int x, int y, int w, int h) {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, bmp.Size);
        return bmp;
    }
    // Share of sampled pixels that match within a small tolerance, and share that are pure black.
    public static string Compare(Bitmap a, Bitmap b) {
        var r = new Rectangle(0, 0, a.Width, a.Height);
        BitmapData da = a.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb), db = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        int same = 0, black = 0, n = 0;
        try {
            for (int y = 5; y < a.Height; y += 23) for (int x = 5; x < a.Width; x += 23) {
                int p = Marshal.ReadInt32(da.Scan0, y * da.Stride + x * 4), q = Marshal.ReadInt32(db.Scan0, y * db.Stride + x * 4);
                int d = Math.Abs((p & 255) - (q & 255)) + Math.Abs(((p >> 8) & 255) - ((q >> 8) & 255)) + Math.Abs(((p >> 16) & 255) - ((q >> 16) & 255));
                n++; if (d <= 12) same++; if ((p & 0xFFFFFF) == 0) black++;
            }
        } finally { a.UnlockBits(da); b.UnlockBits(db); }
        return (100 * same / n) + "% matching, " + (100 * black / n) + "% black, " + n + " samples";
    }
}
'@
$N = [ZoneFullscreen.Native]; [void]$N::SetThreadDpiAwarenessContext([IntPtr]-4)
$mon = [IntPtr]::Zero; $info = New-Object ZoneFullscreen.Native+MONITORINFOEX; [void]$N::TryGetPrimaryMonitor([ref]$mon, [ref]$info)
$desc = ''; $zones = (New-Object ZoneFullscreen.ZoneProvider ([ZoneFullscreen.ZoneProvider]::DefaultDirectory)).GetZones($info, [ref]$desc)
Write-Host "layout: $desc -> $($zones -join ' ')"
if ($zones.Count -lt 2) { Write-Host 'fewer than 2 zones: nothing to check'; exit 2 }
$zone = $zones[$zones.Count - 1]
function Pump([int]$ms) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $ms) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }

# An ordinary window inside the zone, standing in for whatever the user is working in.
$fake = Start-Process powershell -PassThru -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'FakeFullscreen.ps1')`" -Title ZfUnder -X $($zone.X + 200) -Y 200 -W 900 -H 700 -CloseMs 25000"
$other = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
while ($other -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 100; Get-Process powershell | Where-Object MainWindowTitle -eq 'ZfUnder' | ForEach-Object { $other = $_.MainWindowHandle } }
$probe = New-Object System.Drawing.Point ($zone.X + 600), 500
foreach ($magnifier in $true, $false) {
foreach ($offScreen in $true, $false) {
    # as the app does: the magnifier window sits in the zone itself, a copying window beside it
    $parking = if ($magnifier) { $zone } else { New-Object ZoneFullscreen.Rect ($zone.X - $zone.W), $zone.Y, $zone.W, $zone.H }
    $m = New-Object ZoneFullscreen.ZoneMirror $zone, 'ZoneFullscreen - test', $offScreen, $parking, $magnifier
    try {
        Write-Host "magnifier=$magnifier offScreen=$offScreen : showing..."
        $m.Show(); Pump 1200
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($m.Handle, [ref]$r)
        Write-Host "   magnifier in use: $($m.UsingMagnifier); window at $r, state $($m.WindowState), one frame takes $([Math]::Round($m.LastCaptureMs, 1)) ms"
        $screen = [Cap]::Screen($zone.X, $zone.Y, $zone.W, $zone.H)
        Pump 100
        $win = [Cap]::Window($m.Handle, $zone.W, $zone.H)
        Write-Host "   capture of the window vs the zone on screen: $([Cap]::Compare($win, $screen))"
        if (-not $offScreen) {
            # Call apps raise the window they share. It must stay beneath the others or it swallows clicks.
            [void][Cap]::BringWindowToTop($m.Handle); [void][Cap]::SetForegroundWindow($m.Handle)
            [void]$N::SetWindowPos($m.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0003)   # HWND_TOP, no move/size
            Pump 300
            $hit = [Cap]::TopLevelAt($probe.X, $probe.Y)
            Write-Host "   after trying to raise it, a click in the zone reaches: $(if ($hit -eq $m.Handle) { 'THE MIRROR (bad)' } elseif ($hit -eq $other) { 'the window beneath (good)' } else { 'another window (good)' })"
        }
        $win.Dispose(); $screen.Dispose()
    } finally { $m.Close(); $m.Dispose() }
}
}
if (-not $fake.HasExited) { $fake.Kill() }
