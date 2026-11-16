# ZoneFullscreen launcher.
# Compiles the C# sources in ..\core and .\src in memory and runs the tray app. Nothing is installed.
#   -Log <file>   write one line per action (for troubleshooting)
param([string]$Log = '')

$ErrorActionPreference = 'Stop'

# The launcher normally runs with no window, so anything the user must know goes in a message box.
function Show-Message([string]$Text, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'ZoneFullscreen', 'OK', $Icon)
}

try {
    # ..\core is the platform-independent logic, .\src the Windows side of it.
    $folders = (Join-Path (Split-Path $PSScriptRoot -Parent) 'core'), (Join-Path $PSScriptRoot 'src')
    $sources = Get-ChildItem -Path $folders -Filter *.cs | ForEach-Object { $_.FullName }
    Add-Type -Path $sources -IgnoreWarnings `
        -ReferencedAssemblies System.Core, System.Drawing, System.Windows.Forms, System.Web.Extensions

    if ($Log) { $Log = [System.IO.Path]::GetFullPath($Log) }
    if (-not [ZoneFullscreen.Program]::Run($PSCommandPath, $Log)) {
        # ASCII only in this file: Windows PowerShell reads a script without BOM in the ANSI code page.
        Show-Message 'ZoneFullscreen is already running: look for its icon in the notification area.' 'Information'
    }
}
catch {
    Show-Message ("ZoneFullscreen could not start.`n`n" + $_.Exception.Message) 'Error'
    exit 1
}
