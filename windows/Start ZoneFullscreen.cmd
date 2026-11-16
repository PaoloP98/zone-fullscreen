@echo off
rem Starts ZoneFullscreen in the notification area, with no window. To close it: right-click its icon > Exit.
rem -ExecutionPolicy Bypass applies to this one process: without it the default Windows policy refuses the script.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ZoneFullscreen.ps1"
