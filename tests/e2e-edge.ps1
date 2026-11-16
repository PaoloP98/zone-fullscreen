# Real-browser check: opens Edge with a throwaway profile, presses F11 twice, reports where the window went.
# Run:  powershell -NoProfile -File tests\e2e-edge.ps1     (do not touch the keyboard for ~15 s)
param([int]$X = 1000, [int]$Y = 100, [int]$W = 1400, [int]$H = 900)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host 'Edge not found'; exit 2 }

$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Fg { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }'
Add-Type -AssemblyName System.Windows.Forms
$N = [ZoneFullscreen.Native]; [void]$N::SetThreadDpiAwarenessContext([IntPtr]-4)
function Rect-Of([IntPtr]$h) { $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r); "$r" }
function Edge-Procs { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*zf-edge-profile*' } }

$log = Join-Path $env:TEMP 'zonefullscreen-edge.log'; Remove-Item $log -ErrorAction SilentlyContinue
$profileDir = Join-Path $env:TEMP 'zf-edge-profile'
$launcher = Join-Path $root 'windows\ZoneFullscreen.ps1'
# The page puts its own viewport size in the window title, so we can see what the browser lays out for.
$page = Join-Path $env:TEMP 'zf-edge-page.html'
Set-Content $page '<body style="margin:0;background:#223"><script>setInterval(function(){document.title="viewport "+innerWidth+"x"+innerHeight},200)</script></body>'
function Title-Of([IntPtr]$h) { foreach ($p in Edge-Procs) { $pp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; if ($pp -and $pp.MainWindowHandle -eq $h) { return $pp.MainWindowTitle } } }
$app = Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$launcher`" -Log `"$log`"" -PassThru
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $log) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 200 }
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --new-window --window-position=$X,$Y --window-size=$W,$H `"$page`""
    Start-Sleep -Seconds 5
    $h = [IntPtr]::Zero
    foreach ($p in Edge-Procs) {
        $pp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($pp -and $pp.MainWindowHandle -ne 0) { $h = $pp.MainWindowHandle }
    }
    if ($h -eq [IntPtr]::Zero) { Write-Host 'Edge test window not found'; return }
    Write-Host "before:     $(Rect-Of $h)"
    foreach ($step in 'fullscreen', 'restored  ') {
        [void][Fg]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400
        if ($N::GetForegroundWindow() -ne $h) { Write-Host 'could not focus Edge; skipping key press'; break }
        [System.Windows.Forms.SendKeys]::SendWait('{F11}'); Start-Sleep -Milliseconds 2500
        $top = ($N::GetWindowLong($h, $N::GWL_EXSTYLE) -band $N::WS_EX_TOPMOST) -ne 0
        Write-Host "$step`: $(Rect-Of $h)  topmost=$top  [$(Title-Of $h)]"
        if ($step -eq 'fullscreen') {
            # Does it stay in its zone when focus goes to another window and comes back, repeatedly?
            $fake = Join-Path $PSScriptRoot 'FakeFullscreen.ps1'
            $other = Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$fake`" -Title ZfOther -X 40 -Y 200 -W 700 -H 600 -CloseMs 20000" -PassThru
            $o = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($o -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 100; Get-Process powershell | Where-Object MainWindowTitle -eq 'ZfOther' | ForEach-Object { $o = $_.MainWindowHandle } }
            foreach ($i in 1..4) {
                [void][Fg]::SetForegroundWindow($o); Start-Sleep -Milliseconds 700
                $bg = "$(Rect-Of $h) focusMoved=$($N::GetForegroundWindow() -eq $o)"
                [void][Fg]::SetForegroundWindow($h); Start-Sleep -Milliseconds 700
                Write-Host "switch $i  : background $bg | foreground $(Rect-Of $h)  [$(Title-Of $h)]"
            }
            if (-not $other.HasExited) { $other.Kill() }
            [void][Fg]::SetForegroundWindow($h); Start-Sleep -Milliseconds 500
        }
    }
} finally {
    Edge-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $app.HasExited) { $app.Kill() }
    Write-Host '--- app log ---'
    if (Test-Path $log) { Get-Content $log -Encoding UTF8 }
    Start-Sleep 1
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
