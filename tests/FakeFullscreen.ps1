# Test window that goes borderless-fullscreen the way browsers and video players do:
# it removes its frame and resizes itself to the whole monitor. F11 or Esc toggles by hand.
#   -EnterMs / -LeaveMs / -CloseMs  script the toggles for the automated test
#   -Insist                         keep forcing the monitor size back (to exercise the fight guard)
param(
    [int]$X = 100, [int]$Y = 100, [int]$W = 800, [int]$H = 600,
    [string]$Title = 'FakeFullscreen',
    [int]$EnterMs = 0, [int]$LeaveMs = 0, [int]$CloseMs = 0,
    [switch]$Insist,
    [int]$InsistEveryMs = 0   # while fullscreen, take the monitor back on a timer (a slow fight)
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.StartPosition = 'Manual'
$form.Bounds = New-Object System.Drawing.Rectangle $X, $Y, $W, $H
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 46)
$form.KeyPreview = $true
$label = New-Object System.Windows.Forms.Label
$label.Dock = 'Fill'; $label.TextAlign = 'MiddleCenter'; $label.ForeColor = 'White'
$label.Font = New-Object System.Drawing.Font 'Segoe UI', 16
$label.Text = "$Title`nF11 = fullscreen"
$form.Controls.Add($label)

$script:full = $false
$script:saved = $form.Bounds
function Set-Full([bool]$on) {
    if ($on -eq $script:full) { return }
    if ($on) {
        $script:saved = $form.Bounds
        $form.FormBorderStyle = 'None'
        $form.Bounds = [System.Windows.Forms.Screen]::FromControl($form).Bounds
        $script:full = $true
    } else {
        $script:full = $false
        $form.FormBorderStyle = 'Sizable'
        $form.Bounds = $script:saved
    }
}
$form.Add_KeyDown({ if ($_.KeyCode -eq 'F11') { Set-Full (-not $script:full) } elseif ($_.KeyCode -eq 'Escape') { Set-Full $false } })

if ($Insist) {
    # A stubborn app: whenever it is "fullscreen" but not monitor-sized, it grabs the monitor again.
    $form.Add_Resize({
        if ($script:full) {
            $screen = [System.Windows.Forms.Screen]::FromControl($form).Bounds
            if ($form.Bounds -ne $screen) { $form.Bounds = $screen }
        }
    })
}

$script:elapsed = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
    $script:elapsed += 50
    if ($EnterMs -and $script:elapsed -eq $EnterMs) { Set-Full $true }
    if ($LeaveMs -and $script:elapsed -eq $LeaveMs) { Set-Full $false }
    if ($InsistEveryMs -and $script:full -and ($script:elapsed % $InsistEveryMs) -eq 0) {
        $screen = [System.Windows.Forms.Screen]::FromControl($form).Bounds
        if ($form.Bounds -ne $screen) { $form.Bounds = $screen }
    }
    if ($CloseMs -and $script:elapsed -ge $CloseMs) { $form.Close() }
})
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
