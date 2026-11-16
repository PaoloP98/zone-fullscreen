# Checks the extension against the real YouTube player (embedded in a local page, or a URL you pass).
# It clicks the player and presses "f", so do not use mouse or keyboard for ~25 s.
# Run:  powershell -NoProfile -File tests\e2e-youtube.ps1 [-Url https://www.youtube.com/watch?v=...]
param([string]$Url = '', [string]$VideoId = 'aqz-KE-bpKQ', [int]$X = 1736, [int]$Y = 16, [int]$W = 1688, [int]$H = 1360, [int]$Port = 8766,
      [int]$ClickX = 400, [int]$ClickY = 420, [string]$ShotDir = '', [int]$FsX = 764, [int]$FsY = 576, [int]$PreX = -1, [int]$PreY = -1, [int]$HoverX = -1, [int]$HoverY = -1)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host 'Edge not found'; exit 2 }

$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Wins2 {
    delegate bool Proc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(Proc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static List<IntPtr> Of(HashSet<uint> pids) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
            if (IsWindowVisible(h) && pids.Contains(pid) && Title(h).Length > 0) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static void Move(int x, int y) { SetCursorPos(x, y); mouse_event(1, 1, 1, 0, UIntPtr.Zero); }
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
}
'@
$N = [ZoneFullscreen.Native]; [void]$N::SetThreadDpiAwarenessContext([IntPtr]-4)
function Edge-Procs { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*zf-yt-profile*' } }
function Windows-Now {
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    Edge-Procs | ForEach-Object { [void]$pids.Add([uint32]$_.ProcessId) }
    [Wins2]::Of($pids) | Where-Object { [Wins2]::Title($_) -notlike 'Disattiva*' }
}
function Show([string]$label) {
    Write-Host "--- $label"
    foreach ($h in Windows-Now) {
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
        Write-Host "    $r  $([Wins2]::Title($h))"
        if ($ShotDir -and $r.W -gt 0) {
            # Picture of the test window only, to see what the player is doing.
            $bmp = New-Object System.Drawing.Bitmap $r.W, $r.H
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($r.X, $r.Y, 0, 0, $bmp.Size); $g.Dispose()
            $small = New-Object System.Drawing.Bitmap $bmp, ([int]($r.W / 2)), ([int]($r.H / 2))
            $small.Save((Join-Path $ShotDir (($label -replace '[^a-z0-9]+', '-') + '.png'))); $small.Dispose(); $bmp.Dispose()
        }
    }
}
function Press([string]$keys) {
    $h = Windows-Now | Select-Object -First 1
    if (-not $h) { Write-Host '    (no window)'; return }
    [void][Wins2]::SetForegroundWindow($h); Start-Sleep -Milliseconds 300
    if ($N::GetForegroundWindow() -ne $h) { Write-Host '    (could not focus Edge)'; return }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
}

$page = @"
<!doctype html><title>starting</title>
<body style="margin:0;background:#223;color:#fff;font:16px sans-serif">
<iframe id="player" width="800" height="450" style="display:block;margin:150px 0 0 0;border:0"
        src="https://www.youtube.com/embed/$VideoId" allow="autoplay; fullscreen; encrypted-media" allowfullscreen></iframe>
<script>
var events = 0, frame = document.getElementById('player');
document.addEventListener('fullscreenchange', function () { events++; });
setInterval(function () {
  var r = frame.getBoundingClientRect(), fs = document.fullscreenElement;
  document.title = 'vp ' + innerWidth + 'x' + innerHeight + ' frame ' + Math.round(r.width) + 'x' + Math.round(r.height) +
                   ' fs=' + (fs ? fs.id : 'none') + ' events=' + events;
}, 200);
</script>
"@
function Start-Server([int]$port, [string]$html) {
    $file = Join-Path $env:TEMP "zf-page-$port.html"
    [IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding $false))
    $code = "`$l = New-Object System.Net.HttpListener; `$l.Prefixes.Add('http://localhost:$port/'); `$l.Start(); while (`$true) { `$c = `$l.GetContext(); `$b = [IO.File]::ReadAllBytes('$file'); `$c.Response.ContentType = 'text/html; charset=utf-8'; `$c.Response.OutputStream.Write(`$b, 0, `$b.Length); `$c.Response.Close() }"
    Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
}
$server = $null
if (-not $Url) {
    $Url = "http://localhost:$Port/"
    $server = Start-Server $Port $page
}
$profileDir = Join-Path $env:TEMP 'zf-yt-profile'
$ext = Join-Path $root 'extension'
try {
    Start-Sleep -Milliseconds 800
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --load-extension=`"$ext`" --window-position=$X,$Y --window-size=$W,$H `"$Url`""
    Start-Sleep -Seconds 8;  Show 'loaded'
    $h = Windows-Now | Select-Object -First 1
    if ($h -and $PreX -ge 0) {   # e.g. the "reject all" button of a cookie dialog
        [void][Wins2]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
        [Wins2]::Click($r.X + $PreX, $r.Y + $PreY); Start-Sleep -Seconds 4
    }
    if ($h -and $HoverX -ge 0) {
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
        [Wins2]::Move($r.X + $HoverX - 30, $r.Y + $HoverY - 30); Start-Sleep -Milliseconds 300; [Wins2]::Move($r.X + $HoverX, $r.Y + $HoverY); Start-Sleep -Milliseconds 700
    }
    if ($h -and $ClickX -ge 0) {
        [void][Wins2]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
        [Wins2]::Click($r.X + $ClickX, $r.Y + $ClickY)      # start playback / focus the player
    }
    Start-Sleep -Milliseconds 800;  Show 'after click on the player'
    # The player's own fullscreen button (bottom right of the 800x450 player); hover first so the controls show.
    $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
    if ($FsX -ge 0) { [Wins2]::Move($r.X + $FsX - 60, $r.Y + $FsY - 40); Start-Sleep -Milliseconds 500 }
    if ($FsX -ge 0) { [Wins2]::Click($r.X + $FsX, $r.Y + $FsY) }
    Start-Sleep -Seconds 4;  Show 'after fullscreen button'
    Press '{ESC}'
    Start-Sleep -Seconds 4;  Show 'after Esc'
} finally {
    Edge-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { $server.Kill() }
    Start-Sleep 1
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
