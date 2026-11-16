# ZoneFullscreen

On an ultrawide monitor, windows placed side by side behave like separate monitors: when a program
goes fullscreen it fills only its own [FancyZones](https://learn.microsoft.com/windows/powertoys/fancyzones)
zone, not the whole monitor.

Windows only for now. It is made of two independent parts; you can use either one on its own:

| Part | What it does | Where |
|---|---|---|
| Windows app | Confines to its zone any program that uses borderless fullscreen (video players, borderless games) | [`windows/`](windows) |
| Browser extension | Does the same for Edge and Chrome: video fullscreen, `F11`, toolbar button | [`extension/`](extension) |

Chromium-based browsers are left to the extension: resized from outside, they take the whole monitor back on every focus change.

## Requirements

- Windows 10 or 11. Nothing else to install: the app uses Windows PowerShell 5.1 and .NET Framework 4.8, both already there.
- [PowerToys](https://learn.microsoft.com/windows/powertoys/) with FancyZones and a layout of at least two zones. Without FancyZones, an ultrawide monitor is split into two halves.
- For the extension: Edge or Chrome 111 or later.

## Installing the app

1. Get the project: `git clone https://github.com/PaoloP98/zone-fullscreen.git`, or **Code > Download ZIP** and extract the folder wherever you want to keep it.
2. Open the `windows` folder and double-click **`Install.cmd`**.

The script copies nothing elsewhere: it unblocks the downloaded files, adds a Start menu shortcut and starts the app. An icon with two panes appears in the notification area.

The app is not an executable: it is C# source compiled in memory at every start. That is why it also runs with Smart App Control on, and you can read everything it executes.

### Using it

- Put a window in a zone and send it fullscreen: it stays in the zone.
- `Ctrl+Win+F11` fits the active window, without borders, to its zone; press it again to undo.
- Right-click the icon to: enable or disable, cover the taskbar or not, exclude a program, share a single zone in video calls, start with Windows, exit.

If a program keeps taking the whole screen back, the app stops insisting and leaves it alone until it next leaves fullscreen.

### Updating

`git pull` (or download the ZIP again into the same folder), then **Exit** from the icon and start it again from the Start menu.

### Removing

1. Right-click the icon > **Exit**.
2. In the `windows` folder run `Install.cmd -Remove`: it removes the shortcut and the start-with-Windows entry.
3. Delete the folder.

## Installing the extension

It is not in the stores yet, so it is loaded from its folder:

1. Open `edge://extensions` (or `chrome://extensions`).
2. Turn on **Developer mode**.
3. **Load unpacked** and pick the `extension` folder.

From then on a video's fullscreen, `F11`, the toolbar button and `Alt+Shift+F` move the tab into a window with only a title bar, the same size as the window it came from. A maximized window keeps the real fullscreen.

The extension asks for the `storage` permission only and talks neither to the app nor to the network.

## Known limits

- Games in exclusive fullscreen cannot be resized from outside.
- The window flashes at full-monitor size for a moment before it is confined.
- Electron apps (VS Code, Discord, Spotify, Teams) are treated like browsers and ignored, unless you turn on "Also Edge/Chrome without the extension" in the menu.
- Tested on a single 3440×1440 ultrawide monitor.

## Project layout

```
core/        operating-system independent logic: zone geometry, zone picking, and the state
             machine that decides when to confine, release or give up on a window
windows/     the Windows side: launcher, tray icon, Win32 hooks, FancyZones file reader
extension/   browser extension (Manifest V3), independent of the app
tests/       unit and end-to-end tests, in PowerShell
```

Porting the app to another system takes two implementations of the interfaces in
[`core/ZoneKeeper.cs`](core/ZoneKeeper.cs): `IWindowPlatform` (reading and moving windows) and
`IZoneSource` (where the zones come from). There is no FancyZones on Linux or macOS, so the zone
source has to be chosen per platform. The reasons behind the design are in [`design.md`](design.md).

## Tests

```
powershell -NoProfile -File tests\run-tests.ps1     # unit tests, no windows
powershell -NoProfile -File tests\e2e.ps1           # the real app with test windows (~1 minute)
powershell -NoProfile -File tests\e2e-gesture.ps1   # the extension in Edge with a throwaway profile
```

The end-to-end tests open and move windows on screen; exit ZoneFullscreen first if it is running.
The other scripts in `tests/` are diagnostics: they print what they see, with no pass/fail result.

## License

[MIT](LICENSE): you may use, modify and redistribute the code as long as the copyright notice is kept; no warranty.

The built-in layouts are computed with the same rules as FancyZones, part of
[Microsoft PowerToys](https://github.com/microsoft/PowerToys) (also MIT licensed).
ZoneFullscreen is an independent project, not affiliated with Microsoft.
