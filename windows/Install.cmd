@echo off
rem Sets ZoneFullscreen up: unblocks the downloaded files, adds a Start menu shortcut and starts the app.
rem To remove the shortcut and the start-with-Windows entry:  Install.cmd -Remove
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
pause
