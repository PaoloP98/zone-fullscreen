# Sets ZoneFullscreen up where it was downloaded: nothing is copied elsewhere.
#   (no arguments)   unblock the downloaded files, add a Start menu shortcut, start the app
#   -Remove          remove the Start menu shortcut and the "start with Windows" entry
# ASCII only in this file: Windows PowerShell reads a script without BOM in the ANSI code page.
param([switch]$Remove)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $PSScriptRoot 'ZoneFullscreen.ps1'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'ZoneFullscreen.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

if ($Remove) {
    Remove-Item $shortcut -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name 'ZoneFullscreen' -ErrorAction SilentlyContinue
    Write-Host 'Shortcut and start-with-Windows entry removed.'
    Write-Host 'Close ZoneFullscreen from its notification-area icon (Exit), then you can delete the folder:'
    Write-Host "  $root"
    return
}

# Files from a downloaded ZIP carry a "came from the internet" mark that can keep scripts from running.
Get-ChildItem $root -Recurse -File | Unblock-File

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# "conhost --headless" gives PowerShell a console with no window at all. Started on its own,
# PowerShell shows a console first and hides it afterwards; where Windows Terminal is the default
# terminal that window stays open, and closing it closes the app.
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $conhost
$link.Arguments = "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
$link.WorkingDirectory = $PSScriptRoot
$link.Description = 'Fullscreen that stays inside the FancyZones zone'
$link.Save()

Start-Process $conhost -ArgumentList $link.Arguments
Write-Host 'ZoneFullscreen is running: look for its icon (two panes) in the notification area.'
Write-Host 'It is in the Start menu too. To start it with Windows: right-click the icon > Start with Windows.'
