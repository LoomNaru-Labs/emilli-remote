# The store PC's screen for the blur measurement (brief REMOTE-BLUR): a window that fills the
# screen except a plain margin (so the helper can find the picture by the wallpaper colour) and
# shows one of two text-heavy pages, A or B, like a back-office list. It switches page on a
# signal file and writes the moment each change is on screen to an answer file. A small square
# in the window's top-left corner can blink twice a second (a "ticker": something on the
# screen that keeps changing, as a clock or a blinking caret does on a real PC).
# Only for a throwaway CI runner. Plain ASCII on purpose (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $Signal,
    [Parameter(Mandatory)] [string] $Answer,
    [int] $Margin = 30
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name Dpi -Namespace BlurMeasure -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[BlurMeasure.Dpi]::SetProcessDPIAware() | Out-Null

$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$W = $scr.Width - 2 * $Margin
$H = $scr.Height - 2 * $Margin

function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
# The measuring script may be reading the answer file at the same moment: try a few times.
function Write-Answer([string] $Text) {
    for ($i = 0; $i -lt 50; $i++) {
        try { [System.IO.File]::AppendAllText($Answer, $Text + "`r`n"); return } catch { Start-Sleep -Milliseconds 10 }
    }
}

$words = @('Bulgogi', 'Galbi', 'Samgyeopsal', 'Kimchi', 'Japchae', 'Bibimbap', 'Tteokbokki', 'Mandu',
           'Soju', 'Iced tea', 'Cola', 'Lunch set', 'Side salad', 'Rice', 'Egg roll', 'Pork belly',
           'Short rib', 'Brisket', 'Ramen', 'Cold noodles', 'Pancake', 'Soup', 'Stew', 'Dessert')
$names = @('Kim', 'Lee', 'Park', 'Choi', 'Jung', 'Kang', 'Cho', 'Yoon', 'Jang', 'Lim', 'Han', 'Oh')

function New-Page([int] $Seed, [string] $Title, [int] $PageH = $H) {
    $rnd = New-Object System.Random $Seed
    $bmp = New-Object System.Drawing.Bitmap $W, $PageH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    # Grey-scale smoothing (no ClearType colour fringes), as a plain line-of-business screen.
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $black = [System.Drawing.Brushes]::Black
    $grey = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(102, 102, 102))
    $line = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 200, 200)), 1
    $head = New-Object System.Drawing.Font 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold)
    $body = New-Object System.Drawing.Font 'Segoe UI', 9
    $small = New-Object System.Drawing.Font 'Segoe UI', 8
    $mono = New-Object System.Drawing.Font 'Consolas', 10
    $g.DrawString($Title, $head, $black, 24, 14)
    $g.DrawString(("Branch 4   Report {0:D4}   Printed by {1}" -f $rnd.Next(1000, 9999), $names[$rnd.Next($names.Count)]), $small, $grey, 26, 46)
    $cols = @(24, 90, 330, 470, 610, 760, 930, 1130, 1330, 1530)
    $hdr = @('No.', 'Item', 'Qty', 'Price', 'Amount', 'Table', 'Server', 'Time', 'Check', 'Note')
    $y = 76
    for ($c = 0; $c -lt $hdr.Count; $c++) { if ($cols[$c] -lt $W - 60) { $g.DrawString($hdr[$c], $body, $black, $cols[$c], $y) } }
    $y += 22
    $g.DrawLine($line, 20, $y - 3, $W - 20, $y - 3)
    $row = 1
    while ($y -lt $PageH - 40) {
        $qty = $rnd.Next(1, 9); $price = $rnd.Next(300, 4800) / 100.0
        $vals = @(('{0:D3}' -f $row), $words[$rnd.Next($words.Count)], "$qty", ('{0:N2}' -f $price), ('{0:N2}' -f ($qty * $price)),
                  ('{0}{1}' -f [char](65 + $rnd.Next(4)), $rnd.Next(1, 41)), $names[$rnd.Next($names.Count)],
                  ('{0:D2}:{1:D2}:{2:D2}' -f $rnd.Next(11, 23), $rnd.Next(60), $rnd.Next(60)), ('#{0}' -f $rnd.Next(10000, 99999)),
                  $(if ($rnd.Next(3) -eq 0) { 'no onion, extra sauce' } else { '' }))
        for ($c = 0; $c -lt $vals.Count; $c++) {
            if ($cols[$c] -ge $W - 60) { continue }
            $f = if ($c -eq 3 -or $c -eq 4 -or $c -eq 8) { $mono } elseif ($c -eq 9) { $small } else { $body }
            $br = if ($c -eq 9 -or $c -eq 0) { $grey } else { $black }
            $g.DrawString($vals[$c], $f, $br, $cols[$c], $y)
        }
        $y += 20
        if ($row % 5 -eq 0) { $g.DrawLine($line, 20, $y - 2, $W - 20, $y - 2) }
        $row++
    }
    $g.Dispose()
    return $bmp
}

$pages = @{ A = (New-Page 11 'Sales by item, lunch'); B = (New-Page 29 'Open checks, dinner'); T = (New-Page 47 'All checks, today' (2 * $H)) }

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Bounds = New-Object System.Drawing.Rectangle $Margin, $Margin, $W, $H
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::White
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Fill'
$pic.SizeMode = 'Normal'
$pic.Image = $pages.A
$form.Controls.Add($pic)
# The tall page T (twice the screen's height) for the scroll test: shown from its top, then moved
# up by ScrollPx at ScrollSpeed pixels a second, as a list scrolled with the mouse wheel.
$picT = New-Object System.Windows.Forms.PictureBox
$picT.SizeMode = 'Normal'
$picT.Image = $pages.T
$picT.Bounds = New-Object System.Drawing.Rectangle 0, 0, $W, (2 * $H)
$picT.Visible = $false
$form.Controls.Add($picT)
$tick = New-Object System.Windows.Forms.Panel
$tick.Bounds = New-Object System.Drawing.Rectangle 4, 4, 16, 16
$tick.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($tick)
$tick.BringToFront()
$ScrollPx = 510
$ScrollSpeed = 340.0

$script:lastWrite = [DateTime]::MinValue
$script:ticking = $false
$script:lastTick = 0
$script:scrollFrom = 0

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15
$timer.Add_Tick({
    if ($script:ticking -and ((Now-Ms) - $script:lastTick) -ge 500) {
        $tick.BackColor = if ($tick.BackColor.R -gt 128) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        $script:lastTick = Now-Ms
    }
    if ($script:scrollFrom -gt 0) {
        $off = [Math]::Min($ScrollPx, [int](((Now-Ms) - $script:scrollFrom) * $ScrollSpeed / 1000.0))
        if ($picT.Top -ne -$off) { $picT.Top = -$off; $form.Update() }
        if ($off -ge $ScrollPx) {
            Write-Answer ("scroll {0} {1}" -f $script:scrollFrom, (Now-Ms))
            $script:scrollFrom = 0
        }
    }
    if (-not (Test-Path $Signal)) { return }
    $lw = (Get-Item $Signal).LastWriteTimeUtc
    if ($lw -eq $script:lastWrite) { return }
    $cmd = ''
    # Attempt 1 lost a command here: the file was still being written, the read failed and the
    # change was already marked as seen. Now it is marked only after a good read.
    try { $cmd = ([System.IO.File]::ReadAllText($Signal)).Trim() } catch { return }
    if (-not $cmd) { return }
    $script:lastWrite = $lw
    switch ($cmd) {
        'A' { $picT.Visible = $false; $pic.Visible = $true; $pic.Image = $pages.A; $pic.Refresh() }
        'B' { $picT.Visible = $false; $pic.Visible = $true; $pic.Image = $pages.B; $pic.Refresh() }
        'T' { $picT.Top = 0; $picT.Visible = $true; $picT.BringToFront(); $tick.BringToFront(); $pic.Visible = $false; $form.Refresh() }
        # The answer comes when the scroll ends ("scroll <start> <end>").
        'scroll' { $script:scrollFrom = Now-Ms; return }
        'tick-on' { $script:ticking = $true }
        'tick-off' { $script:ticking = $false; $tick.BackColor = [System.Drawing.Color]::White; $tick.Refresh() }
        'quit' { $form.Close() }
        default { return }
    }
    Write-Answer ("{0} {1}" -f $cmd, (Now-Ms))
})
$form.Add_Shown({ Write-Answer ("shown {0} {1}x{2} at {3}" -f (Now-Ms), $W, $H, $Margin); $timer.Start() })
[System.Windows.Forms.Application]::Run($form)
