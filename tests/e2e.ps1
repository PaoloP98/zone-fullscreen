# End-to-end check: runs the real app and scripted test windows, then compares where they end up.
# Run:  powershell -NoProfile -File tests\e2e.ps1      (windows will flash on screen for ~30 s)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Get-ChildItem (Join-Path $root 'core'), (Join-Path $root 'windows\src') -Filter *.cs | ForEach-Object FullName
Add-Type -Path $src -IgnoreWarnings -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions
$N = [ZoneFullscreen.Native]
[void]$N::SetThreadDpiAwarenessContext([IntPtr]-4)

$mon = [IntPtr]::Zero; $info = New-Object ZoneFullscreen.Native+MONITORINFOEX
[void]$N::TryGetPrimaryMonitor([ref]$mon, [ref]$info)
$monitor = $info.rcMonitor.ToRect()
$desc = ''
$zones = (New-Object ZoneFullscreen.ZoneProvider ([ZoneFullscreen.ZoneProvider]::DefaultDirectory)).GetZones($info, [ref]$desc)
Write-Host "monitor $monitor, layout: $desc, zones: $($zones -join ' ')"
if ($zones.Count -lt 2) { Write-Host 'This monitor has fewer than 2 zones: nothing to test.'; exit 2 }

$script:failed = 0
function Check($name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Host "ok   $name" }
    else { $script:failed++; Write-Host "FAIL $name  expected $expected, got $actual" -ForegroundColor Red }
}
function Find-Window([string]$title) {
    $found = [IntPtr]::Zero
    foreach ($p in Get-Process powershell -ErrorAction SilentlyContinue) {
        if ($p.MainWindowTitle -eq $title) { $found = $p.MainWindowHandle }
    }
    $found
}
function Rect-Of([IntPtr]$h) { $r = New-Object ZoneFullscreen.Rect; [void]$N::TryGetRect($h, [ref]$r); $r }
function Is-Topmost([IntPtr]$h) { ($N::GetWindowLong($h, $N::GWL_EXSTYLE) -band $N::WS_EX_TOPMOST) -ne 0 }
function Start-Fake([string]$title, $rect, [string]$extra = '', [string]$timing = '-EnterMs 1500 -LeaveMs 4000 -CloseMs 6000') {
    $fake = Join-Path $PSScriptRoot 'FakeFullscreen.ps1'
    $args = "-NoProfile -WindowStyle Hidden -File `"$fake`" -Title $title -X $($rect.X) -Y $($rect.Y) -W $($rect.W) -H $($rect.H) $timing $extra"
    Start-Process powershell -ArgumentList $args -PassThru
}
# A window snapped into a zone the way FancyZones does it (16 px margins).
function Snapped($zone) { New-Object ZoneFullscreen.Rect ($zone.X + 16), ($zone.Y + 16), ($zone.W - 32), ($zone.H - 80) }

function Run-Case([string]$title, $start, $expectFull, [bool]$expectTopmost, [string]$extra = '') {
    $proc = Start-Fake $title $start $extra
    try {
        $h = [IntPtr]::Zero
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 100; $h = Find-Window $title }
        if ($h -eq [IntPtr]::Zero) { Check "$title window appeared" 'no' 'yes'; return }
        $sw.Restart()
        Start-Sleep -Milliseconds 700
        Check "$title starts where placed" (Rect-Of $h) $start
        Start-Sleep -Milliseconds 2100      # ~2.8 s: fullscreen entered at 1.5 s
        Check "$title while fullscreen" (Rect-Of $h) $expectFull
        Check "$title always-on-top while fullscreen" (Is-Topmost $h) $expectTopmost
        Start-Sleep -Milliseconds 2200      # ~5 s: fullscreen left at 4 s
        Check "$title after leaving fullscreen" (Rect-Of $h) $start
        Check "$title no longer always-on-top" (Is-Topmost $h) $false
    } finally {
        if (-not $proc.WaitForExit(5000)) { $proc.Kill() }
    }
}

$log = Join-Path $env:TEMP 'zonefullscreen-e2e.log'
Remove-Item $log -ErrorAction SilentlyContinue
$launcher = Join-Path $root 'windows\ZoneFullscreen.ps1'
$app = Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$launcher`" -Log `"$log`"" -PassThru
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $log) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 200 }
    Check 'app started' (Test-Path $log) $true

    $last = $zones[$zones.Count - 1]
    Run-Case 'ZfLast' (Snapped $last) $last $true
    Run-Case 'ZfFirst' (Snapped $zones[0]) $zones[0] $true
    # A window that already spans the screen must get the real, whole-monitor fullscreen.
    $wide = New-Object ZoneFullscreen.Rect 8, 8, ($monitor.W - 16), ($monitor.H - 80)
    Run-Case 'ZfWide' $wide $monitor $false
    # A stubborn window that keeps re-taking the monitor: the app must give up, not fight forever.
    Run-Case 'ZfStubborn' (Snapped $last) $monitor $false '-Insist'

    # A window that takes the monitor back every 200 ms, too slowly to look like a fight each time:
    # the app must still give up within a few seconds instead of flickering for ever.
    $start = Snapped $last
    $proc = Start-Fake 'ZfSlow' $start '-InsistEveryMs 200' '-EnterMs 1500 -LeaveMs 8000 -CloseMs 11000'
    try {
        $h = [IntPtr]::Zero
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 100; $h = Find-Window 'ZfSlow' }
        if ($h -eq [IntPtr]::Zero) { Check 'ZfSlow window appeared' 'no' 'yes' }
        else {
            Start-Sleep -Milliseconds 2300      # ~2.3 s: fullscreen entered at 1.5 s, the fight is on
            $slowHandle = 'powershell#' + $h.ToInt64().ToString('X')
            Check 'ZfSlow was confined at first' ([bool](Select-String -Path $log -SimpleMatch "zoned $slowHandle" -Quiet)) $true
            Start-Sleep -Milliseconds 4700      # ~7 s: ten re-zones are long spent
            Check 'ZfSlow app gave up' ([bool](Select-String -Path $log -SimpleMatch "gave up on $slowHandle" -Quiet)) $true
            Check 'ZfSlow left with the whole monitor' (Rect-Of $h) $monitor
            Check 'ZfSlow no longer always-on-top' (Is-Topmost $h) $false
            $lines = (Get-Content $log).Count
            Start-Sleep -Milliseconds 1000
            Check 'ZfSlow is left alone afterwards' (Get-Content $log).Count $lines
            Start-Sleep -Milliseconds 3500      # ~11.5 s: the test window's clock runs slow, its 8 s is ~10 s
            Check 'ZfSlow after leaving fullscreen' (Rect-Of $h) $start
        }
    } finally {
        if (-not $proc.WaitForExit(6000)) { $proc.Kill() }
    }
} finally {
    if (-not $app.HasExited) { $app.Kill() }
    Write-Host '--- app log ---'
    if (Test-Path $log) { Get-Content $log -Encoding UTF8 }
}

# ---- the hotkey path, driven directly (no hooks, no tray): frame off into the zone, then back ----
$watcher = New-Object ZoneFullscreen.WindowWatcher (New-Object ZoneFullscreen.ZoneProvider ([ZoneFullscreen.ZoneProvider]::DefaultDirectory)),
    ([ZoneFullscreen.AppConfig]::Load((Join-Path $env:TEMP 'zf-no-such-config.json'))), '', ''
$statePath = Join-Path $env:TEMP 'zonefullscreen-e2e-frameless.txt'
Remove-Item $statePath -ErrorAction SilentlyContinue
function New-CrashWatcher {
    New-Object ZoneFullscreen.WindowWatcher (New-Object ZoneFullscreen.ZoneProvider ([ZoneFullscreen.ZoneProvider]::DefaultDirectory)),
        ([ZoneFullscreen.AppConfig]::Load((Join-Path $env:TEMP 'zf-no-such-config.json'))), '', $statePath
}
$start = Snapped $zones[0]
$proc = Start-Fake 'ZfForced' $start '' '-CloseMs 11000'
try {
    $h = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 100; $h = Find-Window 'ZfForced' }
    if ($h -eq [IntPtr]::Zero) { Check 'ZfForced window appeared' 'no' 'yes' }
    else {
        function Has-Frame([IntPtr]$w) { ($N::GetWindowLong($w, $N::GWL_STYLE) -band $N::WS_CAPTION) -eq $N::WS_CAPTION }
        Start-Sleep -Milliseconds 500
        $watcher.ToggleForced($h); Start-Sleep -Milliseconds 500
        Check 'ZfForced fills its zone' (Rect-Of $h) $zones[0]
        Check 'ZfForced has no frame' (Has-Frame $h) $false
        Check 'ZfForced is always-on-top' (Is-Topmost $h) $true
        $watcher.ToggleForced($h); Start-Sleep -Milliseconds 500
        Check 'ZfForced is back where it was' (Rect-Of $h) $start
        Check 'ZfForced has its frame again' (Has-Frame $h) $true
        Check 'ZfForced no longer always-on-top' (Is-Topmost $h) $false
        # Shutting down must restore a window that is still forced.
        $watcher.ToggleForced($h); Start-Sleep -Milliseconds 300
        $watcher.Dispose(); Start-Sleep -Milliseconds 500
        Check 'ZfForced restored on shutdown' "$(Rect-Of $h) $(Has-Frame $h) $(Is-Topmost $h)" "$start True False"

        # A run that dies with a window still forced: the next run must give the frame back.
        $crashed = New-CrashWatcher
        $crashed.ToggleForced($h); Start-Sleep -Milliseconds 300
        Check 'ZfForced frameless when the app dies' "$(Has-Frame $h) $(Test-Path $statePath)" 'False True'
        $crashed = $null   # never disposed, like a killed process
        $next = New-CrashWatcher
        Check 'ZfForced recovered by the next run' $next.RestoreAbandoned() 1
        Start-Sleep -Milliseconds 300
        Check 'ZfForced as it was before the crash' "$(Rect-Of $h) $(Has-Frame $h) $(Is-Topmost $h)" "$start True False"
        Check 'ZfForced record cleared' (Test-Path $statePath) $false
    }
} finally {
    if (-not $proc.WaitForExit(11000)) { $proc.Kill() }
}

Write-Host ("{0} failure(s)" -f $script:failed)
if ($script:failed) { exit 1 }
