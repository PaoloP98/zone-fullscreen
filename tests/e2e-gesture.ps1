# Checks the browser extension in a real Edge (throwaway profile), driven through the debugging
# protocol, which can run script with or without a simulated user gesture:
#   - "fullscreen" is only granted right after a user action, like the browser itself does
#   - the fullscreen button of <video controls> stays inside the window too
#   - a tab popped out by the page goes back on navigation, one popped out with F11 does not
# Run:  powershell -NoProfile -File tests\e2e-gesture.ps1      (an Edge window opens for ~50 s)
param([int]$Port = 8766, [int]$DebugPort = 9334, [int]$X = 1736, [int]$Y = 16, [int]$W = 1688, [int]$H = 1360)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host 'Edge not found'; exit 2 }

$script:failed = 0
function Check($name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Host "ok   $name" }
    else { $script:failed++; Write-Host "FAIL $name  expected $expected, got $actual" -ForegroundColor Red }
}

$script:ws = $null; $script:msgId = 0
function Cdp-Connect {
    $targets = Invoke-RestMethod "http://localhost:$DebugPort/json"
    $page = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like "http://localhost:$Port/*" } | Select-Object -First 1
    if (-not $page) { throw "test page not found among: $(($targets | ForEach-Object url) -join ', ')" }
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
# Runs JavaScript in the page's own world; $gesture makes the browser treat it as a user action.
function Js([string]$expression, [bool]$gesture = $false) {
    $r = Cdp-Send 'Runtime.evaluate' @{ expression = $expression; returnByValue = $true; userGesture = $gesture; awaitPromise = $true }
    if ($r.result.exceptionDetails) { return 'EXCEPTION' }
    $r.result.result.value
}
# "box" when the element fills the window, and whether the tab is still in the window it started in.
function Window-Id { (Cdp-Send 'Browser.getWindowForTarget').result.windowId }
$script:startWindow = $null
function State {
    $where = if ((Window-Id) -eq $script:startWindow) { 'normal-window' } else { 'bare-window' }
    "$(Js "document.fullscreenElement ? document.fullscreenElement.id : 'none'") $where"
}
$request = "document.getElementById('box').requestFullscreen().then(() => 'granted')"
function Window-State { (Cdp-Send 'Browser.getWindowBounds' @{ windowId = (Window-Id) }).result.bounds.windowState }
# What the fullscreen button of a <video controls> player does: it asks the browser directly.
# A fresh isolated world still has the browser's own requestFullscreen, not the replaced one.
function Press-VideoButton {
    $frame = (Cdp-Send 'Page.getFrameTree').result.frameTree.frame.id
    $world = (Cdp-Send 'Page.createIsolatedWorld' @{ frameId = $frame; worldName = 'zf-test' }).result.executionContextId
    [void](Cdp-Send 'Runtime.evaluate' @{ expression = "document.getElementById('vid').requestFullscreen()"; contextId = $world; userGesture = $true; awaitPromise = $true })
    Start-Sleep -Seconds 3
    State
}
# F11 cannot be typed through the protocol; making the window fullscreen is what it does.
function Press-F11 {
    [void](Cdp-Send 'Browser.setWindowBounds' @{ windowId = (Window-Id); bounds = @{ windowState = 'fullscreen' } })
    Start-Sleep -Seconds 3
}

$page = @'
<!doctype html><title>ZoneFullscreen gesture test</title>
<body style="margin:0;background:#223;color:#fff;font:20px sans-serif">
<p>ZoneFullscreen gesture test</p>
<div id="box" style="width:300px;height:200px;background:#c33">box</div>
<video id="vid" controls style="width:300px;height:200px;background:#000"></video>
<script>var errors = 0; document.addEventListener('fullscreenerror', function () { errors++; });</script>
'@
$file = Join-Path $env:TEMP "zf-page-$Port.html"
[IO.File]::WriteAllText($file, $page, (New-Object System.Text.UTF8Encoding $false))
$code = "`$l = New-Object System.Net.HttpListener; `$l.Prefixes.Add('http://localhost:$Port/'); `$l.Start(); while (`$true) { `$c = `$l.GetContext(); `$b = [IO.File]::ReadAllBytes('$file'); `$c.Response.ContentType = 'text/html; charset=utf-8'; `$c.Response.OutputStream.Write(`$b, 0, `$b.Length); `$c.Response.Close() }"
$server = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))

function Edge-Procs { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*zf-gesture-profile*' } }
$profileDir = Join-Path $env:TEMP 'zf-gesture-profile'
$ext = Join-Path $root 'extension'
try {
    Start-Sleep -Milliseconds 800
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --remote-debugging-port=$DebugPort --load-extension=`"$ext`" --window-position=$X,$Y --window-size=$W,$H about:blank http://localhost:$Port/"
    Start-Sleep -Seconds 6
    Cdp-Connect
    # A second tab keeps the starting window alive while ours is popped out; ours must be the active one.
    [void](Cdp-Send 'Page.bringToFront'); Start-Sleep -Milliseconds 500
    $script:startWindow = Window-Id

    Check 'extension is active in the page' (Js '!!window.__zoneFullscreen && !/native code/.test(Element.prototype.requestFullscreen.toString())') 'True'
    Check 'starts in a normal window' (State) 'none normal-window'

    # ---- no user action: everything must be refused ----
    Check 'request without a user action is rejected' (Js $request) 'EXCEPTION'
    Check 'the page is told (fullscreenerror)' (Js 'errors') '1'
    Start-Sleep -Seconds 2
    Check 'nothing happened' (State) 'none normal-window'
    [void](Js "document.dispatchEvent(new CustomEvent('zf-popout', { detail: 'enter' }))")
    Start-Sleep -Seconds 2
    Check 'a forged pop-out event is ignored' (State) 'none normal-window'

    # ---- with a user action: it works as before ----
    Check 'request after a user action is granted' (Js $request $true) 'granted'
    Start-Sleep -Seconds 3
    Check 'element fills a bare window' (State) 'box bare-window'
    Check 'leaving is allowed without a user action' (Js "document.exitFullscreen().then(() => 'left')") 'left'
    Start-Sleep -Seconds 3
    Check 'back in the normal window' (State) 'none normal-window'

    # ---- the fullscreen button of <video controls>: it bypasses the page's API ----
    Check 'video button: the element fills a bare window' (Press-VideoButton) 'vid bare-window'
    Check 'video button: the window is not really fullscreen' (Window-State) 'normal'
    Check 'video button again: back in the normal window' (Press-VideoButton) 'none normal-window'

    # ---- a tab popped out for the page goes back when the page navigates away ----
    [void](Js $request $true); Start-Sleep -Seconds 3
    Check 'page fullscreen before navigating' (State) 'box bare-window'
    [void](Cdp-Send 'Page.navigate' @{ url = "http://localhost:$Port/?second" }); Start-Sleep -Seconds 3
    Check 'navigating ends the page fullscreen' (State) 'none normal-window'

    # ---- a tab popped out by the user (F11) stays out across navigation ----
    Press-F11
    Check 'F11 moves the tab to a bare window' (State) 'none bare-window'
    [void](Cdp-Send 'Page.navigate' @{ url = "http://localhost:$Port/?third" }); Start-Sleep -Seconds 3
    Check 'F11 survives navigation' (State) 'none bare-window'
    Press-F11
    Check 'F11 again puts the tab back' (State) 'none normal-window'
} finally {
    if ($script:ws) { $script:ws.Dispose() }
    Edge-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { $server.Kill() }
    Start-Sleep 1
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $file -ErrorAction SilentlyContinue
}
Write-Host ("{0} failure(s)" -f $script:failed)
if ($script:failed) { exit 1 }
