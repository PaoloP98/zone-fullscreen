# Diagnostic: drives a real YouTube watch page through the browser's debugging protocol and
# reports what the extension did inside the page. Uses Edge with a throwaway profile.
# Run:  powershell -NoProfile -File tests\cdp-youtube.ps1 [-ShotDir <folder>]
param([string]$Url = 'https://www.youtube.com/watch?v=aqz-KE-bpKQ', [int]$DebugPort = 9333,
      [int]$X = 1736, [int]$Y = 16, [int]$W = 1688, [int]$H = 1360, [string]$ShotDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host 'Edge not found'; exit 2 }

$script:ws = $null; $script:msgId = 0
function Cdp-Connect {
    $targets = Invoke-RestMethod "http://localhost:$DebugPort/json"
    $page = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like '*youtube.com/watch*' } | Select-Object -First 1
    if (-not $page) { throw "no YouTube page among: $(($targets | ForEach-Object url) -join ', ')" }
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
}
function Cdp-Send([string]$method, $params = @{}) {
    $script:msgId++
    $json = @{ id = $script:msgId; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $script:ws.SendAsync((New-Object 'ArraySegment[byte]' (, $bytes)), 'Text', $true, [Threading.CancellationToken]::None).Wait()
    $buffer = New-Object byte[] 1048576
    while ($true) {   # skip events until the reply with our id arrives
        $sb = New-Object Text.StringBuilder
        do {
            $res = $script:ws.ReceiveAsync((New-Object 'ArraySegment[byte]' (, $buffer)), [Threading.CancellationToken]::None).Result
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $res.Count))
        } while (-not $res.EndOfMessage)
        $msg = $sb.ToString() | ConvertFrom-Json
        if ($msg.id -eq $script:msgId) { return $msg }
    }
}
# Evaluates JavaScript in the page's own world and returns its (JSON-serialisable) value.
function Js([string]$expression, [bool]$gesture = $false) {
    $r = Cdp-Send 'Runtime.evaluate' @{ expression = $expression; returnByValue = $true; userGesture = $gesture; awaitPromise = $true }
    if ($r.result.exceptionDetails) { return "EXCEPTION: $($r.result.exceptionDetails.exception.description)" }
    $r.result.result.value
}
function Shot([string]$name) {
    if (-not $ShotDir) { return }
    $r = Cdp-Send 'Page.captureScreenshot' @{ format = 'jpeg'; quality = 50 }
    [IO.File]::WriteAllBytes((Join-Path $ShotDir "$name.jpg"), [Convert]::FromBase64String($r.result.data))
}
$state = @'
(() => {
  const fs = document.fullscreenElement, p = document.querySelector('#movie_player'), v = document.querySelector('video');
  const box = (e) => { if (!e) return null; const r = e.getBoundingClientRect(); return Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height); };
  return JSON.stringify({
    extensionInPage: !!window.__zoneFullscreen,
    requestIsOurs: !/native code/.test(Element.prototype.requestFullscreen.toString()),
    fullscreenElement: fs ? (fs.id || fs.tagName) + '.' + fs.className.split(' ').filter(c => c.startsWith('zf-')).join('.') : null,
    viewport: innerWidth + 'x' + innerHeight,
    fullscreenElementBox: box(fs), player: box(p), video: box(v),
    playerClasses: p ? p.className.split(' ').filter(c => /fullscreen|zf-/.test(c)).join(' ') : null,
    scrollY: Math.round(scrollY)
  });
})()
'@
function Edge-Procs { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*zf-cdp-profile*' } }

# ---- looking at, and typing into, the test browser's windows from outside ----
$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Wins3 {
    delegate bool Proc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(Proc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
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
function Windows-Now {
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    Edge-Procs | ForEach-Object { [void]$pids.Add([uint32]$_.ProcessId) }
    [Wins3]::Of($pids) | Where-Object { [Wins3]::Title($_) -notlike 'Disattiva*' }
}
function Windows-Text {
    (Windows-Now | ForEach-Object {
        $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($_, [ref]$r)
        $kind = if ([Wins3]::Title($_) -like '*Microsoft*Edge') { 'browser window' } else { 'bare window' }
        "$r $kind"
    }) -join ' | '
}
# Same effect as pressing F11 (browser-window fullscreen), without needing keyboard focus.
function Press-F11 {
    $win = Cdp-Send 'Browser.getWindowForTarget'
    if (-not $win.result.windowId) { Write-Host "          (no window id: $($win.error.message))"; return }
    $r = Cdp-Send 'Browser.setWindowBounds' @{ windowId = $win.result.windowId; bounds = @{ windowState = 'fullscreen' } }
    if ($r.error) { Write-Host "          (fullscreen refused: $($r.error.message))" }
    Start-Sleep -Seconds 3
}

$profileDir = Join-Path $env:TEMP 'zf-cdp-profile'
$ext = Join-Path $root 'extension'
try {
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --remote-debugging-port=$DebugPort --load-extension=`"$ext`" --window-position=$X,$Y --window-size=$W,$H `"$Url`""
    Start-Sleep -Seconds 8
    Cdp-Connect
    # EU cookie dialog: take the privacy-preserving option.
    Write-Host "consent : $(Js "(() => { const b = [...document.querySelectorAll('button')].find(b => /Rifiuta tutto|Reject all/i.test(b.textContent)); if (b) { b.click(); return 'rejected'; } return 'no dialog'; })()")"
    Start-Sleep -Seconds 5
    Write-Host "before  : $(Js $state)"
    Write-Host "click   : $(Js "(() => { const b = document.querySelector('.ytp-fullscreen-button'); if (!b) return 'no button'; b.click(); return 'clicked'; })()" $true)"
    Start-Sleep -Seconds 3
    Write-Host "entered : $(Js $state)"
    Shot 'entered'
    Write-Host "click   : $(Js "(() => { const b = document.querySelector('.ytp-fullscreen-button'); if (!b) return 'no button'; b.click(); return 'clicked'; })()" $true)"
    Start-Sleep -Seconds 3
    Write-Host "left    : $(Js $state)"
    Shot 'left'

    Write-Host '--- F11 on the normal window: must become a bare window in the same place, never the whole monitor'
    Write-Host "windows : $(Windows-Text)"
    Press-F11
    Write-Host "F11 in  : $(Windows-Text)   viewport $(Js 'innerWidth + "x" + innerHeight')"
    Press-F11
    Write-Host "F11 out : $(Windows-Text)   viewport $(Js 'innerWidth + "x" + innerHeight')"

    Write-Host '--- player fullscreen, then F11 to leave: the tab goes back and the player leaves fullscreen'
    [void](Js "document.querySelector('.ytp-fullscreen-button').click()" $true); Start-Sleep -Seconds 3
    Write-Host "entered : $(Windows-Text)   $(Js $state)"
    Press-F11
    Write-Host "F11 out : $(Windows-Text)   $(Js $state)"
} finally {
    if ($script:ws) { $script:ws.Dispose() }
    Edge-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 1
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
