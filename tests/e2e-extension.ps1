# Checks the browser extension in Edge with a throwaway profile: a test page asks for
# fullscreen on an element after 3 s and leaves it after 9 s; we watch the windows from outside.
# Run:  powershell -NoProfile -File tests\e2e-extension.ps1
param([int]$X = 1736, [int]$Y = 16, [int]$W = 1688, [int]$H = 1360, [int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host 'Edge not found'; exit 2 }

$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Wins {
    delegate bool Proc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(Proc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static List<IntPtr> Of(HashSet<uint> pids) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
            if (IsWindowVisible(h) && pids.Contains(pid) && Title(h).Length > 0) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
}
'@
$N = [ZoneFullscreen.Native]; [void]$N::SetThreadDpiAwarenessContext([IntPtr]-4)
function Edge-Procs { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*zf-ext-profile*' } }
function Show([string]$label) {
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    Edge-Procs | ForEach-Object { [void]$pids.Add([uint32]$_.ProcessId) }
    Write-Host "--- $label"
    foreach ($h in [Wins]::Of($pids)) {
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r)
        Write-Host "    $r  $([Wins]::Title($h))"
    }
}

$page = @'
<!doctype html><title>starting</title>
<body style="margin:0;background:#223;color:#fff;font:20px sans-serif">
<p>ZoneFullscreen extension test</p>
<div style="transform:translateX(0);overflow:hidden;width:400px">
  <div id="box" style="width:300px;height:200px;background:#c33">box</div>
</div>
<script>
var events = 0, box = document.getElementById('box');
document.addEventListener('fullscreenchange', function () { events++; });
setInterval(function () {
  var r = box.getBoundingClientRect(), fs = document.fullscreenElement;
  document.title = 'vp ' + innerWidth + 'x' + innerHeight + ' box ' + Math.round(r.width) + 'x' + Math.round(r.height) +
                   '@' + Math.round(r.left) + ',' + Math.round(r.top) + ' fs=' + (fs ? fs.id : 'none') + ' events=' + events;
}, 200);
setTimeout(function () { box.requestFullscreen(); }, 3000);
setTimeout(function () { document.exitFullscreen(); }, 9000);
</script>
'@
function Start-Server([int]$port, [string]$html) {
    $file = Join-Path $env:TEMP "zf-page-$port.html"
    [IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding $false))
    $code = "`$l = New-Object System.Net.HttpListener; `$l.Prefixes.Add('http://localhost:$port/'); `$l.Start(); while (`$true) { `$c = `$l.GetContext(); `$b = [IO.File]::ReadAllBytes('$file'); `$c.Response.ContentType = 'text/html; charset=utf-8'; `$c.Response.OutputStream.Write(`$b, 0, `$b.Length); `$c.Response.Close() }"
    Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
}
$server = Start-Server $Port $page
$profileDir = Join-Path $env:TEMP 'zf-ext-profile'
$ext = Join-Path $root 'extension'
try {
    Start-Sleep -Milliseconds 800
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --load-extension=`"$ext`" --window-position=$X,$Y --window-size=$W,$H about:blank http://localhost:$Port/"
    Start-Sleep -Milliseconds 5500;  Show 'before (page loaded ~2 s ago)'
    Start-Sleep -Milliseconds 3500;  Show 'while in window-fullscreen'
    Start-Sleep -Milliseconds 5500;  Show 'after leaving'
} finally {
    Edge-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { $server.Kill() }
    Start-Sleep 1
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
