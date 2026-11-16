# Unit tests for the pure logic (zone geometry, FancyZones parsing, zone picking, fight guard,
# and the confine / release / give-up decisions, run against fake windows).
# Run:  powershell -NoProfile -File tests\run-tests.ps1
$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot '..\core'; $win = Join-Path $PSScriptRoot '..\windows\src'
Add-Type -Path (Join-Path $core 'Core.cs'), (Join-Path $win 'FancyZones.cs'), (Join-Path $core 'ZoneKeeper.cs'), (Join-Path $PSScriptRoot 'Fakes.cs') `
    -ReferencedAssemblies System.Core, System.Web.Extensions

$script:failed = 0; $script:passed = 0
function Check([string]$name, $actual, $expected) {
    $a = ($actual | ForEach-Object { "$_" }) -join ' '
    $e = ($expected | ForEach-Object { "$_" }) -join ' '
    if ($a -ceq $e) { $script:passed++ }
    else { $script:failed++; Write-Host "FAIL $name`n   expected: $e`n   actual:   $a" -ForegroundColor Red }
}
function Rc($x, $y, $w, $h) { New-Object ZoneFullscreen.Rect $x, $y, $w, $h }
function Pick($zones, $window) {
    $out = New-Object ZoneFullscreen.Rect
    if ([ZoneFullscreen.ZonePicker]::TryPick([ZoneFullscreen.Rect[]]$zones, $window, [ref]$out)) { "$out" } else { 'none' }
}
$LC = [ZoneFullscreen.LayoutCalculator]
$FZ = [ZoneFullscreen.FancyZonesReader]
$mon = Rc 0 0 3440 1440
$work = Rc 0 0 3440 1392

# ---- layout geometry ----
Check 'columns 2 = halves' $LC::Columns($mon, 2) '(0,0 1720x1440)', '(1720,0 1720x1440)'
Check 'columns 3 tile the width' $LC::Columns($mon, 3) '(0,0 1146x1440)', '(1146,0 1147x1440)', '(2293,0 1147x1440)'
Check 'rows 3' $LC::Rows($mon, 3) '(0,0 3440x480)', '(0,480 3440x480)', '(0,960 3440x480)'
Check 'priority-grid 3 = 25/50/25' $LC::PriorityGrid($mon, 3) '(0,0 860x1440)', '(860,0 1720x1440)', '(2580,0 860x1440)'
Check 'priority-grid 2 = 2/3 + 1/3' $LC::PriorityGrid($mon, 2) '(0,0 2293x1440)', '(2293,0 1147x1440)'
Check 'priority-grid 4: two tall zones' $LC::PriorityGrid($mon, 4) '(0,0 860x1440)', '(860,0 1720x1440)', '(2580,0 860x720)', '(2580,720 860x720)'
Check 'priority-grid 12 falls back to grid' $LC::PriorityGrid($mon, 12) $LC::Grid($mon, 12)
Check 'grid 3 = 3 columns' $LC::Grid($mon, 3) $LC::Columns($mon, 3)
Check 'grid 4 = 2x2' $LC::Grid($mon, 4) '(0,0 1720x720)', '(1720,0 1720x720)', '(0,720 1720x720)', '(1720,720 1720x720)'
$g5 = $LC::Grid($mon, 5)
Check 'grid 5 count' $g5.Count 5
Check 'grid 5 last zone spans two cells' "$($g5[4])" '(1146,720 2294x720)'
Check 'monitor origin respected' $LC::Columns((Rc -1920 100 1920 1080), 2) '(-1920,100 960x1080)', '(-960,100 960x1080)'
Check 'malformed grid map -> empty' $LC::FromGrid($mon, @(5000, 5000), @(5000, 5000), [int[][]]@(, @(0, 1))).Count 0
Check 'canvas scales from reference' $LC::Canvas((Rc 0 0 3440 1400), 1720, 700, [ZoneFullscreen.Rect[]]@((Rc 100 50 500 300))) '(200,100 1000x600)'
foreach ($n in 0, -1) {
    Check "no zones for count $n" ($LC::Columns($mon, $n).Count + $LC::Rows($mon, $n).Count + $LC::Grid($mon, $n).Count + $LC::PriorityGrid($mon, $n).Count) 0
}
foreach ($n in 1..14) {
    $area = 0; foreach ($z in $LC::PriorityGrid($mon, $n)) { $area += $z.Area }
    Check "priority-grid $n covers the monitor exactly" $area (3440 * 1440)
    Check "priority-grid $n zone count" $LC::PriorityGrid($mon, $n).Count $n
    $area = 0; foreach ($z in $LC::Grid($mon, $n)) { $area += $z.Area }
    Check "grid $n covers the monitor exactly" $area (3440 * 1440)
}

# ---- zone picking ----
$halves = $LC::Columns($mon, 2)
Check 'snapped right window -> right zone' (Pick $halves (Rc 1728 16 1696 1360)) '(1720,0 1720x1440)'
Check 'mostly-left window -> left zone' (Pick $halves (Rc 400 100 1500 800)) '(0,0 1720x1440)'
Check 'tie -> zone holding the center' (Pick $halves (Rc 1220 0 1000 500)) '(1720,0 1720x1440)'
Check 'no overlap -> none' (Pick $halves (Rc 5000 0 100 100)) 'none'
Check 'covers all rows equally -> middle' (Pick $LC::Rows((Rc 0 0 900 900), 3) (Rc 0 0 900 900)) '(0,300 900x300)'

# ---- fight guard ----
$guard = New-Object ZoneFullscreen.FightGuard
$t = Get-Date '2026-01-01 12:00:00'; $h1 = [IntPtr]1; $h2 = [IntPtr]2
Check 'guard allows 3' ($guard.Allow($h1, $t), $guard.Allow($h1, $t.AddMilliseconds(100)), $guard.Allow($h1, $t.AddMilliseconds(200))) $true, $true, $true
Check 'guard blocks the 4th' $guard.Allow($h1, $t.AddMilliseconds(300)) $false
Check 'guard is per window' $guard.Allow($h2, $t.AddMilliseconds(300)) $true
Check 'guard expires after 2 s' $guard.Allow($h1, $t.AddSeconds(3)) $true
$guard.Reset($h2); Check 'guard reset' $guard.Allow($h2, $t.AddMilliseconds(301)) $true

# ---- FancyZones files ----
$zero = '{00000000-0000-0000-0000-000000000000}'
$applied = @'
{"applied-layouts":[
  {"device":{"monitor":"SAM711A","monitor-instance":"5&d9183b4&0&UID4353","serial-number":"X","monitor-number":1,"virtual-desktop":"{00000000-0000-0000-0000-000000000000}"},
   "applied-layout":{"uuid":"{00000000-0000-0000-0000-000000000000}","type":"priority-grid","show-spacing":true,"spacing":16,"zone-count":3,"sensitivity-radius":20}},
  {"device":{"monitor":"SAM7119","monitor-instance":"5&d9183b4&0&UID4352","serial-number":"X","monitor-number":1,"virtual-desktop":"{00000000-0000-0000-0000-000000000000}"},
   "applied-layout":{"uuid":"{F7C80E08-11C8-4A5F-9FB8-96AB499DF965}","type":"columns","show-spacing":true,"spacing":16,"zone-count":2,"sensitivity-radius":20}},
  {"device":{"monitor":"SAM7119","monitor-instance":"5&d9183b4&0&UID4352","serial-number":"X","monitor-number":1,"virtual-desktop":"{11111111-1111-1111-1111-111111111111}"},
   "applied-layout":{"uuid":"{AAAAAAAA-0000-0000-0000-000000000001}","type":"custom","zone-count":2}}
]}
'@
$custom = @'
{"custom-layouts":[
  {"uuid":"{AAAAAAAA-0000-0000-0000-000000000001}","name":"g","type":"grid",
   "info":{"rows":1,"columns":2,"rows-percentage":[10000],"columns-percentage":[7000,3000],"cell-child-map":[[0,1]],"show-spacing":true,"spacing":16}},
  {"uuid":"{AAAAAAAA-0000-0000-0000-000000000002}","name":"c","type":"canvas",
   "info":{"ref-width":3440,"ref-height":1392,"zones":[{"X":0,"Y":0,"width":1000,"height":1392},{"X":1000,"Y":0,"width":2440,"height":1392}]}}
]}
'@
$defaults = '{"default-layouts":[{"monitor-configuration":"vertical","layout":{"uuid":"","type":"rows","zone-count":3}},{"monitor-configuration":"horizontal","layout":{"uuid":"","type":"priority-grid","zone-count":3}}]}'
function Key($m, $i, $vd) { New-Object ZoneFullscreen.DeviceKey $m, $i, $vd }
function Spec($t, $n, $u) { New-Object ZoneFullscreen.LayoutSpec $t, $n, $u }

$s = $FZ::FindLayout($applied, (Key 'SAM7119' '5&d9183b4&0&UID4352' $zero))
Check 'find: monitor + instance' "$($s.Type) $($s.ZoneCount)" 'columns 2'
$s = $FZ::FindLayout($applied, (Key 'sam7119' '5&D9183B4&0&UID4352' '{11111111-1111-1111-1111-111111111111}'))
Check 'find: prefers current virtual desktop (case-insensitive)' $s.Type 'custom'
$s = $FZ::FindLayout($applied, (Key 'SAM7119' '5&d9183b4&0&UID4352' '{22222222-2222-2222-2222-222222222222}'))
Check 'find: unknown desktop falls back to the zero GUID' $s.Type 'columns'
Check 'find: unknown monitor -> null' ($null -eq $FZ::FindLayout($applied, (Key 'NOPE' 'x' $zero))) $true
foreach ($bad in '{"applied-layouts":[{"dev', '', '[]', '{"applied-layouts":"oops"}', '{"applied-layouts":[1,"a",null,{"device":5}]}') {
    Check "find: bad json [$bad] -> null" ($null -eq $FZ::FindLayout($bad, (Key 'SAM7119' 'x' $zero))) $true
}
Check 'IsValidJson rejects a half-written file' ($FZ::IsValidJson('{"applied-layouts":[{"dev'), $FZ::IsValidJson($applied)) $false, $true
Check 'default layout: horizontal' $FZ::FindDefault($defaults, $true).Type 'priority-grid'
Check 'default layout: vertical' $FZ::FindDefault($defaults, $false).Type 'rows'
Check 'default layout: bad json -> null' ($null -eq $FZ::FindDefault('nope', $true)) $true

Check 'resolve columns' $FZ::Resolve((Spec 'columns' 2 ''), $null, $mon, $work) '(0,0 1720x1440)', '(1720,0 1720x1440)'
Check 'resolve priority-grid' $FZ::Resolve((Spec 'priority-grid' 3 ''), $null, $mon, $work).Count 3
Check 'resolve focus -> none' $FZ::Resolve((Spec 'focus' 3 ''), $null, $mon, $work).Count 0
Check 'resolve blank -> none' $FZ::Resolve((Spec 'blank' 0 ''), $null, $mon, $work).Count 0
Check 'custom grid: full monitor, no spacing' $FZ::Resolve((Spec 'custom' 2 '{aaaaaaaa-0000-0000-0000-000000000001}'), $custom, $mon, $work) '(0,0 2408x1440)', '(2408,0 1032x1440)'
Check 'custom canvas: exact rects on work area' $FZ::Resolve((Spec 'custom' 2 '{AAAAAAAA-0000-0000-0000-000000000002}'), $custom, $mon, $work) '(0,0 1000x1392)', '(1000,0 2440x1392)'
$missing = Spec 'custom' 2 '{BBBBBBBB-0000-0000-0000-000000000009}'
Check 'custom: unknown uuid -> none' $FZ::Resolve($missing, $custom, $mon, $work).Count 0
Check 'custom: no file -> none' $FZ::Resolve($missing, $null, $mon, $work).Count 0
Check 'custom: broken json -> none' $FZ::Resolve($missing, '{ not json', $mon, $work).Count 0
Check 'custom: wrong value types -> none' $FZ::Resolve($missing, '{"custom-layouts":[{"uuid":"{BBBBBBBB-0000-0000-0000-000000000009}","type":"grid","info":{"rows-percentage":"oops","cell-child-map":5}}]}', $mon, $work).Count 0

# ---- the real files on this machine must parse ----
$dir = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones'
if (Test-Path (Join-Path $dir 'applied-layouts.json')) {
    Check 'real applied-layouts.json is readable' $FZ::IsValidJson((Get-Content (Join-Path $dir 'applied-layouts.json') -Raw)) $true
}

# ---- zone keeper: when a window is confined, released, given up on ----
$T0 = Get-Date '2026-01-01 12:00:00'
$snap = Rc 1736 16 1688 1360          # snapped in the right half, FancyZones-style
$rightZone = '(1720,0 1720x1440)'
$H = [IntPtr]1
function New-World($start = $snap) {
    $p = New-Object ZoneFullscreen.Tests.FakePlatform
    $p.Monitor = New-Object ZoneFullscreen.MonitorArea $mon, $work, 'DISPLAY1'
    $z = New-Object ZoneFullscreen.Tests.FakeZones
    foreach ($zone in $LC::Columns($mon, 2)) { $z.Zones.Add($zone) }
    $s = New-Object ZoneFullscreen.Tests.FakeSettings
    $m = New-Object ZoneFullscreen.Tests.Messages
    $k = New-Object ZoneFullscreen.ZoneKeeper $p, $z, $s, $m.Sink
    $win = $p.Add(1, $start)
    @{ P = $p; Z = $z; S = $s; M = $m; K = $k; Win = $win }
}
# The window is seen at its place, then takes the whole monitor a second later.
function Enter-Fullscreen($w, $at = $T0.AddSeconds(1)) {
    $w.K.Observe($H, $false, $T0)
    $w.Win.Rect = $mon
    $w.K.Observe($H, $true, $at)
}
# The window takes the monitor back $rounds times, $stepMs apart.
function Fight($w, $from, [int]$stepMs, [int]$rounds) {
    for ($i = 1; $i -le $rounds; $i++) { $w.Win.Rect = $mon; $w.K.Observe($H, $true, $from.AddMilliseconds($i * $stepMs)) }
}

$w = New-World; Enter-Fullscreen $w
Check 'keeper confines to the zone the window was in' $w.Win.Rect $rightZone
Check 'keeper makes it always-on-top' $w.Win.AlwaysOnTop $true
$w.K.Observe($H, $true, $T0.AddMilliseconds(1010))
Check 'keeper ignores the echo of its own move' ($w.K.IsZoned($H), $w.Win.Moves) $true, 1
$w.Win.Rect = $snap; $w.K.Observe($H, $true, $T0.AddSeconds(3))
Check 'keeper releases when the window leaves fullscreen' ($w.K.IsZoned($H), $w.Win.AlwaysOnTop, $w.Win.Rect) $false, $false, $snap

$w = New-World; $w.Win.AlwaysOnTop = $true; Enter-Fullscreen $w
$w.Win.Rect = $snap; $w.K.Observe($H, $true, $T0.AddSeconds(3))
Check 'keeper leaves a window that was always-on-top that way' $w.Win.AlwaysOnTop $true

$w = New-World; $w.S.CoverTaskbar = $false; Enter-Fullscreen $w
Check 'keeper stays above the taskbar area when asked' ($w.Win.Rect, $w.Win.AlwaysOnTop) '(1720,0 1720x1392)', $false

# The app's own enter-fullscreen animation passes through other sizes: they must not pick the zone.
$w = New-World
$w.K.Observe($H, $false, $T0)
$w.Win.Rect = Rc 100 100 1500 900; $w.K.Observe($H, $true, $T0.AddSeconds(1))
$w.Win.Rect = $mon; $w.K.Observe($H, $true, $T0.AddMilliseconds(1050))
Check 'keeper uses the settled position, not a transition frame' $w.Win.Rect $rightZone

$w = New-World $mon; $w.K.Observe($H, $true, $T0)
Check 'keeper skips a window first seen fullscreen' ($w.Win.Moves, ($w.M.Lines -like 'skipped*').Count) 0, 1
$w = New-World; $w.K.Observe($H, $false, $T0); $w.Win.Rect = $mon; $w.Win.Maximized = $true; $w.K.Observe($H, $true, $T0.AddSeconds(1))
Check 'keeper skips a maximized window' $w.Win.Moves 0
$w = New-World (Rc 8 8 3424 1360); Enter-Fullscreen $w
Check 'keeper skips a window that already spanned the monitor' $w.Win.Moves 0
$w = New-World; $w.S.Excluded.Add('app'); Enter-Fullscreen $w
Check 'keeper skips an excluded program' $w.Win.Moves 0
$w = New-World; $w.S.Enabled = $false; Enter-Fullscreen $w
Check 'keeper does nothing when disabled' $w.Win.Moves 0
$w = New-World; $w.Z.Zones.RemoveAt(1); Enter-Fullscreen $w
Check 'keeper needs at least two zones' $w.Win.Moves 0
$w = New-World; $w.Win.Reasserts = $true; Enter-Fullscreen $w
Check 'keeper leaves browser-like windows to the extension' $w.Win.Moves 0
$w = New-World; $w.Win.Reasserts = $true; $w.S.ConfineReassertingWindows = $true; Enter-Fullscreen $w
Check 'keeper confines browser-like windows when opted in' $w.Win.Rect $rightZone
$w = New-World; $w.K.Observe($H, $false, $T0); $w.Win.Rect = Rc 0 0 3440 1439; $w.K.Observe($H, $true, $T0.AddSeconds(1))
Check 'keeper ignores a parked window (monitor minus one row)' $w.Win.Moves 0

# Instant fight: the window snaps back at once, every time.
$w = New-World; Enter-Fullscreen $w; Fight $w $T0.AddSeconds(1) 20 4
Check 'keeper re-confines a few times' ($w.Win.Moves, $w.K.HasGivenUp($H)) 5, $false
Fight $w $T0.AddMilliseconds(1080) 20 1
Check 'keeper gives up on an instant fight' ($w.Win.Moves, $w.K.HasGivenUp($H), $w.Win.Rect, $w.Win.AlwaysOnTop) 5, $true, $mon, $false

# Slow fight: the window takes the monitor back every 300 ms, for ever.
$w = New-World; Enter-Fullscreen $w; Fight $w $T0.AddSeconds(1) 300 10
Check 'keeper tolerates some slow re-takes' ($w.Win.Moves, $w.K.HasGivenUp($H)) 11, $false
Fight $w $T0.AddSeconds(4) 300 5
Check 'keeper gives up on a slow fight too' ($w.Win.Moves, $w.K.HasGivenUp($H), $w.Win.AlwaysOnTop) 11, $true, $false
$w.Win.Rect = $snap; $w.K.Observe($H, $true, $T0.AddSeconds(10))
$w.Win.Rect = $mon; $w.K.Observe($H, $true, $T0.AddSeconds(11))
Check 'keeper starts afresh at the next fullscreen' ($w.K.IsZoned($H), $w.Win.Rect) $true, $rightZone

# Occasional re-takes (focus changes) spread over a long time never use up the budget.
$w = New-World; Enter-Fullscreen $w; Fight $w $T0.AddSeconds(1) 4000 30
Check 'keeper keeps undoing occasional re-takes' ($w.Win.Moves, $w.K.IsZoned($H)) 31, $true

# On request (hotkey): frame off and into the zone; again to undo.
$w = New-World; $w.K.ToggleForced($H)
Check 'keeper forces a window into its zone' ($w.Win.Framed, $w.Win.Rect, $w.K.IsForced($H)) $false, $rightZone, $true
$w.Win.Rect = $mon; $w.K.Observe($H, $true, $T0)
Check 'keeper leaves a forced window alone' $w.Win.Moves 0
$w.Win.Rect = Rc 1720 0 1720 1440; $w.K.ToggleForced($H)
Check 'keeper restores a forced window' ($w.Win.Framed, $w.Win.Rect, $w.Win.AlwaysOnTop, $w.K.IsForced($H)) $true, $snap, $false, $false
$w = New-World; $w.P.Maximize($H); $w.K.ToggleForced($H); $w.K.ToggleForced($H)
Check 'keeper restores a forced window that was maximized' ($w.Win.Maximized, $w.Win.Framed, $w.Win.RestoredRect) $true, $true, $snap

# Shutting down leaves nothing stuck.
$w = New-World; Enter-Fullscreen $w
$other = $w.P.Add(2, (Rc 16 16 1688 1360)); $w.K.ToggleForced([IntPtr]2)
$w.K.ReleaseAll()
Check 'keeper undoes always-on-top on shutdown' $w.Win.AlwaysOnTop $false
Check 'keeper gives frames back on shutdown' ($other.Framed, $other.Rect, $other.AlwaysOnTop) $true, '(16,16 1688x1360)', $false
$w = New-World; Enter-Fullscreen $w; $w.Win.Alive = $false; $w.K.Prune()
Check 'keeper forgets closed windows' $w.K.IsZoned($H) $false

Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed) { exit 1 }
