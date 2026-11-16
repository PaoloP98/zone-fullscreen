@echo off
rem Starts ZoneFullscreen in the notification area, with no window. To close it: right-click its icon > Exit.
rem "conhost --headless" gives PowerShell a console with no window at all. Started on its own, PowerShell
rem shows a console first and hides it afterwards; where Windows Terminal is the default terminal that
rem window stays open, and closing it closes the app.
rem -ExecutionPolicy Bypass applies to this one process: without it the default Windows policy refuses the script.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ZoneFullscreen.ps1"
