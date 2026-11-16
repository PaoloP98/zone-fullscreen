# ZoneFullscreen — design

## Why
An ultrawide monitor (3440×1440, the only screen). Windows placed side by side should behave like separate monitors: when a program goes fullscreen it must fill only its own portion, not the whole monitor.

## Goals
- Automatic "per-zone" fullscreen for any program that uses borderless fullscreen (browsers, video players, borderless games).
- The zones are those of the active FancyZones layout, with no need to configure them twice.
- It is closed from the tray and everything goes back to normal Windows behaviour.

## Non-goals
- Games in exclusive fullscreen (they cannot be resized from outside).
- Managing how ordinary windows are tiled (Windows / FancyZones already do).
- Drivers or virtual monitors.

## To avoid
- Windows left stuck at a wrong size after leaving fullscreen or after the app is closed.
- An endless resize war with a program that insists on going back to the whole screen.

## Approaches considered
- **A. Background app that catches fullscreen — chosen by the user.** Automatic, no driver, reversible. Limits: a brief full-screen flash, no exclusive fullscreen.
- **B. Hotkey only.** Simple but useless for videos in the browser (tabs and toolbar stay). Included as an extra of A.
- **C. Virtual monitors through a driver.** Works with everything but is invasive, slow and fragile; hardware PBP does the same thing better.

## How it works
1. **Zones = FancyZones' zones (user's request).** The app has no zones of its own: it reads the layout FancyZones applies to the current monitor from its files in `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones` (`applied-layouts.json`, `custom-layouts.json`).
   - Built-in layouts (columns, rows, grid, priority grid): FancyZones stores only the type and the zone count, so the app recomputes the rectangles with the same rules as FancyZones (open source).
   - Custom grid and "canvas" layouts (free rectangles): read directly.
   - "Focus" and "blank" layouts: no useful zones, the app does nothing.
   - The files are re-read automatically when they change, so switching layout in FancyZones takes effect at once.
   - The monitor is matched to the right entry through its hardware identifier. If FancyZones is not installed or the monitor has no layout, the fallback is two halves.
2. **Detection.** The app listens for top-level windows moving and resizing. A window is "fullscreen" when its rectangle equals the whole monitor (taskbar included) and it is not the desktop or the shell.
3. **Choosing the zone.** For every window the app remembers its last normal position. The zone chosen is the one that held most of the window before fullscreen.
4. **Resizing.** The window is moved at once to the zone's rectangle.
5. **Leaving.** When the program leaves fullscreen it restores its previous position by itself; the app just forgets the state. When the app is closed, windows still in a zone are left where they are (their own Esc/F11 brings them back to normal anyway).
6. **Anti-fight.** If a program goes back to the whole screen right after each of our moves more than 5 times in 2 seconds, or more than 10 times in 30 seconds at any pace, the app leaves it alone until it next leaves fullscreen.
7. **Hotkey** `Ctrl+Win+F11`: forces the active window, without borders, into its zone, and again to restore it. The windows left without borders are also written to `frameless-windows.txt` next to the launcher: if the app dies before restoring them, the next start does it.
8. **Tray menu:** enable/disable, start with Windows, exclude the active program, exit. It also shows which FancyZones layout is in use.
9. **Exclusions:** a list of process names in `config.json`.

## My own choices (not discussed, can be changed)
- **Taskbar:** in zone fullscreen the window also covers the taskbar in its portion (as on a real monitor), by being made always-on-top. An option in the menu keeps it above the taskbar area instead.
- **Gaps between zones:** FancyZones leaves a 16 px margin around each zone. In fullscreen the app ignores the margins: zones touch each other and reach the monitor edges, like real monitors side by side. For "canvas" layouts the exact rectangles are used.
- **Multiple monitors:** applies to every monitor that has a FancyZones layout with at least two zones; the others stay normal.
- **Technology (changed along the way):** this PC has Smart App Control on, which blocks unsigned executables compiled locally. The app is therefore shipped as C# sources (`core/*.cs` and `windows/src/*.cs`) compiled in memory at start-up by Windows PowerShell (`windows/ZoneFullscreen.ps1`), without touching that protection. Consequences: C# 5 / .NET Framework 4.8, no .exe, started from `Start ZoneFullscreen.cmd`, tests in PowerShell (`tests/`).
- **Monitors with no saved layout:** FancyZones' default layout is used (`default-layouts.json`), as FancyZones itself does. The two halves remain only when FancyZones is not installed and the monitor is ultrawide.
- **Windows that already took the whole screen** (maximized, or ≥ 90% of the monitor): their fullscreen stays the real one, on the whole monitor.
- **Chromium browsers:** in fullscreen they refuse external resizes; the app moves the window with `SWP_NOSENDCHANGING` to get around that.
- **Name:** ZoneFullscreen.

## Verification
- Automated tests on the zone logic (rectangle computation, zone picking, anti-fight) and on the confine / release / give-up decisions, run against fake windows.
- Real run with a test window that simulates borderless fullscreen, then manual checks with YouTube in Chrome/Edge/Firefox and with VLC.

## Left to the builder
Internal code structure, exact format of `config.json`, icon.

## Later additions

### Browsers (extension in `extension/`)
Edge and Chrome in fullscreen grow back by themselves on every focus change or popup, so the app does not handle them (a menu option turns that back on). An extension handles them: the player's fullscreen, `F11`, the toolbar button and `Alt+Shift+F` move the tab into a window with only a title bar, in the same rectangle as the window it came from. A maximized window keeps the real fullscreen. Like the browser itself, the extension only grants fullscreen right after a click or key press.
- The fullscreen button of a plain `<video controls>` player bypasses the page's fullscreen API, so the window really goes fullscreen for a moment (like `F11`); the extension undoes that and keeps the video filling the bare window instead.
- A tab moved out for the page goes back when the page leaves fullscreen or navigates away. A tab moved out by the user stays out across navigation until the user puts it back.

### Share a zone (for video calls)
Request: share a single FancyZones zone instead of the whole wide screen.
- "Share a zone" in the tray menu opens a borderless window, as large as the zone, showing a live copy of it. In the call app you choose "share a window" and pick that window.
- **Default method:** the Windows magnifier (Magnification API), about 1-3 ms per frame. The window sits in the zone itself, beneath all the others, and leaves itself out of its own picture. Off screen the magnifier gives black, so it has to stay on screen.
- **Compatible method:** a copy of the screen 30 times a second, about 45 ms per frame (almost a full core, ~20 fps); the window is off screen. Needed when the call app does not capture the magnifier's content.
- Verified only with `PrintWindow` (`tests/mirror-check.ps1`), not with Teams: the Teams check is left to the user.

### Structure for other platforms
The decisions (when to confine, release or give up on a window) live in `core/ZoneKeeper.cs`, which makes no operating-system calls. It reaches windows through `IWindowPlatform` and zones through `IZoneSource`; `windows/` holds the Win32 and FancyZones implementations.
