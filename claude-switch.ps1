$env:PYTHONUTF8 = "1"
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Declare per-monitor DPI awareness BEFORE any window is created so WinForms
# renders crisp text instead of being bitmap-stretched (blurry) by Windows.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Dpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Enable() {
        // Try newest API first (Win10 1703+), fall back gracefully.
        try { if (SetProcessDpiAwarenessContext((IntPtr)(-4))) return; } catch {}   // PER_MONITOR_AWARE_V2
        try { SetProcessDpiAwareness(2); return; } catch {}                          // PER_MONITOR
        try { SetProcessDPIAware(); } catch {}                                        // SYSTEM
    }
}
"@ -ErrorAction SilentlyContinue
try { [Dpi]::Enable() } catch {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Invoke-Cswap([string[]]$Arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new("cswap", ($Arguments -join " "))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $out -split "`r?`n"
}

function Show-Toast($title, $message, $duration) {
    $n = New-Object System.Windows.Forms.NotifyIcon
    $icon = $null
    if ($script:iconPath -and (Test-Path $script:iconPath)) {
        try { $icon = New-Object System.Drawing.Icon($script:iconPath) } catch {}
    }
    if ($null -eq $icon) { $icon = [System.Drawing.SystemIcons]::Information }
    $n.Icon = $icon
    $n.Visible = $true
    # ToolTipIcon.None so Windows shows the app icon instead of the blue info glyph.
    $n.ShowBalloonTip($duration, $title, $message, [System.Windows.Forms.ToolTipIcon]::None)
    return $n
}

# Parse `cswap --list` into a list of account objects.
function Get-Accounts {
    $lines = Invoke-Cswap "--list"
    $accounts = @()
    $current = $null

    foreach ($raw in $lines) {
        $line = "$raw"

        # Account header line:  "  1: email [Org] (active)"
        if ($line -match '^\s*(\d+):\s*(.*?)\s*\[(.*?)\]\s*(\(active\))?\s*$') {
            if ($null -ne $current) { $accounts += $current }
            $current = [pscustomobject]@{
                Num    = [int]$matches[1]
                Email  = $matches[2].Trim()
                Org    = $matches[3].Trim()
                Active = [bool]$matches[4]
                Pct5h  = $null
                Pct7d  = $null
                Reset5h = ""
                Reset7d = ""
                Unavailable = $false
            }
            continue
        }

        if ($null -eq $current) { continue }
        if ($line -match 'Running instances') { break }

        # Usage lines:  "  ├ 5h:  92%   resets 04:00   in 2h 49m"
        if ($line -match '5h:\s*(\d+)%') {
            $current.Pct5h = [int]$matches[1]
            if ($line -match 'resets\s+(.*?)\s{2,}') { $current.Reset5h = $matches[1].Trim() }
        }
        elseif ($line -match '7d:\s*(\d+)%') {
            $current.Pct7d = [int]$matches[1]
            if ($line -match 'resets\s+(.*?)\s{2,}') { $current.Reset7d = $matches[1].Trim() }
        }
        elseif ($line -match 'usage unavailable') {
            $current.Unavailable = $true
        }
    }
    if ($null -ne $current) { $accounts += $current }
    return $accounts
}

# Color for a usage percentage: green (low) -> amber -> red (near limit).
function Get-UsageColor([int]$pct) {
    if ($pct -ge 85) { return [System.Drawing.Color]::FromArgb(229, 72, 77) }   # red
    if ($pct -ge 60) { return [System.Drawing.Color]::FromArgb(245, 166, 35) }  # amber
    return [System.Drawing.Color]::FromArgb(48, 164, 108)                       # green
}

# ---------------------------------------------------------------------------
# DPI scaling
# ---------------------------------------------------------------------------
# Everything below is authored in logical pixels at 96 DPI and multiplied by
# $scale. Fonts use GraphicsUnit.Pixel (also scaled) and the form sets
# AutoScaleMode = None, so this manual scaling is the single source of truth.
$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $gfx.DpiX / 96.0
$gfx.Dispose()
if ($script:scale -lt 1) { $script:scale = 1 }

function Px([double]$n)  { return [int][math]::Round($n * $script:scale) }
function Pxf([double]$n) { return [single]($n * $script:scale) }
function Pt($x, $y)      { return New-Object System.Drawing.Point((Px $x), (Px $y)) }
function Sz($w, $h)      { return New-Object System.Drawing.Size((Px $w), (Px $h)) }
function Fnt($name, $px, $style) {
    if ($null -eq $style) { $style = [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($name, (Pxf $px), $style, [System.Drawing.GraphicsUnit]::Pixel)
}

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
# NOTE: PowerShell variable names are case-insensitive, so theme colors use a
# $c* prefix to avoid colliding with locals like $card / $track / $text.
$cBg      = [System.Drawing.Color]::FromArgb(24, 24, 27)
$cCard    = [System.Drawing.Color]::FromArgb(39, 39, 42)
$cCardHov = [System.Drawing.Color]::FromArgb(55, 55, 62)
$cActive  = [System.Drawing.Color]::FromArgb(54, 46, 40)      # active card tint
$cAccent  = [System.Drawing.Color]::FromArgb(224, 130, 95)   # claude-ish terracotta (brighter)
$cText    = [System.Drawing.Color]::FromArgb(245, 245, 247)
$cMuted   = [System.Drawing.Color]::FromArgb(184, 186, 198)   # brighter for legibility
$cTrack   = [System.Drawing.Color]::FromArgb(70, 70, 78)

$reg  = [System.Drawing.FontStyle]::Regular
$bold = [System.Drawing.FontStyle]::Bold
$FONT_EMAIL = Fnt "Segoe UI Semibold" 14 $reg
$FONT_ORG   = Fnt "Segoe UI"          12 $reg
$FONT_USAGE = Fnt "Segoe UI"          12 $reg
$FONT_NUM   = Fnt "Segoe UI Semibold" 13 $reg
$FONT_TITLE = Fnt "Segoe UI Semibold" 17 $reg
$FONT_BTN   = Fnt "Segoe UI Semibold" 13 $reg
$FONT_WINBTN = Fnt "Segoe UI"         15 $reg
# Segoe UI Symbol renders the recycling glyph monochrome (no color-emoji fallback).
$FONT_RESET  = Fnt "Segoe UI Symbol"  12 $reg
# Segoe MDL2 Assets: crisp vector UI icons (refresh/minimize/close).
$FONT_ICON   = Fnt "Segoe MDL2 Assets" 11 $reg

# Resolve our own directory whether running as .ps1 or as a ps2exe-compiled
# .exe (where $PSScriptRoot is empty).
$baseDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($baseDir)) {
    try { $baseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
}
if ([string]::IsNullOrEmpty($baseDir)) { $baseDir = (Get-Location).Path }
$script:iconPath = Join-Path $baseDir "claude-switch-full.ico"

$cBorder = [System.Drawing.Color]::FromArgb(70, 70, 78)

# Layout constants, in logical px at 96 DPI (scaled via Px/Pt/Sz).
$COLS        = 2
$CARD_W      = 240
$CARD_H      = 122
$CARD_MARGIN = 7
$FLOW_PAD    = 6
$HEADER_H    = 46
$BAR_H       = 6      # thinner bars

# Win32 helper so the borderless window can be dragged by its header.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Drag {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int wp, int lp);
}
"@ -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Claude Switch"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "None"
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $cBg
$form.ForeColor = $cText
$form.Font = $FONT_USAGE
$form.KeyPreview = $true
$form.ClientSize = Sz 470 200
if (Test-Path $script:iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:iconPath) } catch {}
}
# Subtle 1px border since there is no title bar / system frame.
$form.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($cBorder, 1)
    $e.Graphics.DrawRectangle($pen, 0, 0, $form.ClientSize.Width - 1, $form.ClientSize.Height - 1)
    $pen.Dispose()
})

# Header (doubles as the drag handle)
$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = Px $HEADER_H
$header.BackColor = $cBg
$form.Controls.Add($header)

$dragDown = {
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [Drag]::ReleaseCapture() | Out-Null
        [Drag]::SendMessage($form.Handle, 0xA1, 0x2, 0) | Out-Null
    }
}
$header.Add_MouseDown($dragDown)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Select account"
$lblTitle.Font = $FONT_TITLE
$lblTitle.ForeColor = $cText
$lblTitle.AutoSize = $true
$lblTitle.Location = Pt 16 12
$lblTitle.Add_MouseDown($dragDown)
$header.Controls.Add($lblTitle)

function New-WinButton($glyph, $hoverColor) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $glyph
    $b.Font = $FONT_ICON
    $b.Size = Sz 30 28
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $hoverColor
    $b.BackColor = $cBg
    $b.ForeColor = $cMuted
    $b.Cursor = "Hand"
    $b.TabStop = $false
    return $b
}

# Top-right cluster: refresh, then minimize and close to its right.
# Glyphs are Segoe MDL2 Assets codepoints (Refresh / ChromeMinimize / ChromeClose).
$btnRefresh = New-WinButton ([char]0xE72C) $cCardHov   # Refresh
$btnMin     = New-WinButton ([char]0xE921) $cCardHov   # ChromeMinimize
$btnClose   = New-WinButton ([char]0xE8BB) ([System.Drawing.Color]::FromArgb(229, 72, 77))  # ChromeClose
$header.Controls.Add($btnRefresh)
$header.Controls.Add($btnMin)
$header.Controls.Add($btnClose)

$btnMin.Add_Click({ $form.WindowState = "Minimized" })
$btnClose.Add_Click({ $form.Close() })

# Place the window buttons relative to the (variable) form width.
function Position-HeaderButtons($clientW) {
    $bw = Px 30; $bh = Px 28; $yb = Px 9; $gap = Px 2; $margin = Px 8
    $xClose = $clientW - $margin - $bw
    $xMin   = $xClose - $gap - $bw
    $xRef   = $xMin   - $gap - $bw
    $btnClose.Location   = New-Object System.Drawing.Point($xClose, $yb)
    $btnMin.Location     = New-Object System.Drawing.Point($xMin,   $yb)
    $btnRefresh.Location = New-Object System.Drawing.Point($xRef,   $yb)
}

# Scrollable flow container: cards sit side by side and wrap to new rows.
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = "Fill"
$flow.FlowDirection = "LeftToRight"
$flow.WrapContents = $true
$flow.AutoScroll = $true
$flow.BackColor = $cBg
$flow.Padding = New-Object System.Windows.Forms.Padding((Px $FLOW_PAD))
$form.Controls.Add($flow)
$flow.BringToFront()

# Tooltip so the full email/org is available even when the card clips it.
$tip = New-Object System.Windows.Forms.ToolTip
$tip.InitialDelay = 400
$tip.AutoPopDelay = 8000
$tip.ReshowDelay = 200

# ---------------------------------------------------------------------------
# Card rendering
# ---------------------------------------------------------------------------
$script:switching = $false

function Switch-To($account) {
    if ($script:switching) { return }
    $script:switching = $true

    Invoke-Cswap @("--switch-to", $account.Num) | Out-Null
    Start-Sleep -Milliseconds 800

    # Confirm with fresh usage info, then hold briefly so the toast can show.
    $fresh = Get-Accounts
    $now = $fresh | Where-Object { $_.Active } | Select-Object -First 1
    $form.Hide()
    if ($null -ne $now) {
        $u = if ($now.Unavailable) { "usage unavailable" }
             else { "5h: $($now.Pct5h)%   7d: $($now.Pct7d)%" }
        $toast = Show-Toast "Account switched" "$($now.Email)`n$u" 5000
        Start-Sleep -Seconds 4
        $toast.Dispose()
    }
    $form.Close()
}

# Adds one usage row to a card: "5h" label + thin bar + pct on one line, the
# reset time on the line below. $y is logical; returns the next logical y.
function Add-UsageRow($card, $label, $pct, $reset, $y, $cardW) {
    $barX = 34
    $pctW = 40
    $rightPad = 12
    $barW = $cardW - $barX - $pctW - $rightPad - 4

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $label
    $lbl.Font = $FONT_USAGE
    $lbl.ForeColor = $cMuted
    $lbl.AutoSize = $false
    $lbl.Size = Sz 24 14
    $lbl.Location = Pt 12 $y
    $card.Controls.Add($lbl)

    $track = New-Object System.Windows.Forms.Panel
    $track.BackColor = $cTrack
    $track.Location = Pt $barX ($y + 3)
    $track.Size = Sz $barW $BAR_H
    $card.Controls.Add($track)

    if ($null -ne $pct) {
        $fillW = [math]::Max(2, [int]((Px $barW) * ([math]::Min(100, $pct) / 100.0)))
        $fill = New-Object System.Windows.Forms.Panel
        $fill.BackColor = (Get-UsageColor $pct)
        $fill.Location = New-Object System.Drawing.Point(0, 0)
        $fill.Size = New-Object System.Drawing.Size($fillW, (Px $BAR_H))
        $track.Controls.Add($fill)
    }

    $info = New-Object System.Windows.Forms.Label
    $info.Text = if ($null -ne $pct) { "$pct%" } else { "--" }
    $info.Font = $FONT_USAGE
    $info.ForeColor = $cText
    $info.AutoSize = $false
    $info.TextAlign = "MiddleRight"
    $info.Size = Sz $pctW 14
    $info.Location = Pt ($barX + $barW + 4) ($y - 1)
    $card.Controls.Add($info)

    if ($reset) {
        $rt = New-Object System.Windows.Forms.Label
        # U+267B recycling symbol, rendered monochrome via Segoe UI Symbol.
        $rt.Text = ([char]0x267B) + " $reset"
        $rt.Font = $FONT_RESET
        $rt.ForeColor = $cMuted
        $rt.AutoSize = $false
        $rt.Size = Sz ($cardW - $barX - $rightPad) 13
        $rt.Location = Pt $barX ($y + 14)
        $card.Controls.Add($rt)
    }

    return ($y + 30)
}

function Render {
    $flow.Controls.Clear()
    $accounts = Get-Accounts
    $cardW = $CARD_W

    foreach ($acc in $accounts) {
        $card = New-Object System.Windows.Forms.Panel
        $card.Size = Sz $CARD_W $CARD_H
        $card.Margin = New-Object System.Windows.Forms.Padding((Px $CARD_MARGIN))
        $card.BackColor = if ($acc.Active) { $cActive } else { $cCard }
        $card.Tag = $acc

        # number badge
        $num = New-Object System.Windows.Forms.Label
        $num.Text = "$($acc.Num)"
        $num.Font = $FONT_NUM
        $num.ForeColor = if ($acc.Active) { $cAccent } else { $cMuted }
        $num.AutoSize = $false
        $num.TextAlign = "MiddleCenter"
        $num.Size = Sz 22 20
        $num.Location = Pt 10 12
        $card.Controls.Add($num)

        # email (clipped to the card width; no AutoEllipsis — it blanks long
        # space-less strings like emails in WinForms)
        $email = New-Object System.Windows.Forms.Label
        $email.Text = $acc.Email
        $email.Font = $FONT_EMAIL
        $email.ForeColor = $cText
        $email.AutoSize = $false
        $email.AutoEllipsis = $false
        $email.UseMnemonic = $false
        $emailW = if ($acc.Active) { $cardW - 44 - 58 } else { $cardW - 44 }
        $email.Size = Sz $emailW 18
        $email.Location = Pt 36 11
        $card.Controls.Add($email)

        # org
        $org = New-Object System.Windows.Forms.Label
        $org.Text = $acc.Org
        $org.Font = $FONT_ORG
        $org.ForeColor = $cMuted
        $org.AutoSize = $false
        $org.AutoEllipsis = $false
        $org.UseMnemonic = $false
        $org.Size = Sz ($cardW - 44) 15
        $org.Location = Pt 36 31
        $card.Controls.Add($org)

        $tipText = "$($acc.Email)`n$($acc.Org)"
        $tip.SetToolTip($email, $tipText)
        $tip.SetToolTip($org, $tipText)
        $tip.SetToolTip($num, $tipText)

        $cy = 54
        if (-not $acc.Unavailable) {
            $cy = Add-UsageRow $card "5h" $acc.Pct5h $acc.Reset5h $cy $cardW
            $cy = Add-UsageRow $card "7d" $acc.Pct7d $acc.Reset7d $cy $cardW
        } else {
            $un = New-Object System.Windows.Forms.Label
            $un.Text = "usage unavailable"
            $un.Font = $FONT_USAGE
            $un.ForeColor = $cMuted
            $un.AutoSize = $true
            $un.Location = Pt 12 $cy
            $card.Controls.Add($un)
        }

        if ($acc.Active) {
            # No button: mark the active card with an accent left stripe and a
            # small "active" badge. It is not clickable.
            $card.Add_Paint({
                param($s, $e)
                $b = New-Object System.Drawing.SolidBrush($cAccent)
                $e.Graphics.FillRectangle($b, 0, 0, (Px 4), $s.ClientSize.Height)
                $b.Dispose()
            }.GetNewClosure())

            $badge = New-Object System.Windows.Forms.Label
            $badge.Text = ([char]0x25CF) + " active"
            $badge.Font = $FONT_USAGE
            $badge.ForeColor = $cAccent
            $badge.AutoSize = $false
            $badge.TextAlign = "MiddleRight"
            $badge.Size = Sz 58 16
            $badge.Location = Pt ($cardW - 58 - 12) 13
            $card.Controls.Add($badge)
        } else {
            # The whole card is the click target. Wire click + hover + hand
            # cursor onto the card and every descendant (bars, labels, etc.).
            $acctRef = $acc
            $theCard = $card
            $onClick = { Switch-To $acctRef }.GetNewClosure()
            $onEnter = { $theCard.BackColor = $cCardHov }.GetNewClosure()
            $onLeave = { $theCard.BackColor = $cCard }.GetNewClosure()
            $wire = {
                param($ctrl)
                $ctrl.Cursor = "Hand"
                $ctrl.Add_Click($onClick)
                $ctrl.Add_MouseEnter($onEnter)
                $ctrl.Add_MouseLeave($onLeave)
            }
            & $wire $card
            foreach ($c in $card.Controls) {
                & $wire $c
                foreach ($c2 in $c.Controls) { & $wire $c2 }
            }
        }

        $flow.Controls.Add($card)
    }

    # Size the window: $COLS columns wide, scroll vertically past the cap.
    # Sum the already-scaled component widths (each Px() rounds independently),
    # then add a few px of slack so a column never wraps from off-by-one.
    $rows = [math]::Ceiling($accounts.Count / [double]$COLS)
    $cardOuterW = (Px $CARD_W) + 2 * (Px $CARD_MARGIN)
    $cardOuterH = (Px $CARD_H) + 2 * (Px $CARD_MARGIN)
    $padPx  = Px $FLOW_PAD
    $slack  = Px 6
    $contentW = $COLS * $cardOuterW + 2 * $padPx
    $contentH = $rows * $cardOuterH + 2 * $padPx
    $maxFlowH = Px 640
    $needScroll = $contentH -gt $maxFlowH
    # Only enable AutoScroll when needed — otherwise the FlowLayoutPanel reserves
    # scrollbar width and squeezes a column out.
    $flow.AutoScroll = $needScroll
    $sbW = if ($needScroll) { [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { 0 }
    $clientW = $contentW + $sbW + $slack
    $flowH = if ($needScroll) { $maxFlowH } else { $contentH + $slack }
    $form.ClientSize = New-Object System.Drawing.Size($clientW, ((Px $HEADER_H) + $flowH))
    Position-HeaderButtons $clientW
    $form.Invalidate()

    return $accounts
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
$script:accounts = $null

$btnRefresh.Add_Click({ $script:accounts = Render })

$form.Add_Shown({ $script:accounts = Render })

# number keys 1..9 switch; Esc closes
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close(); return }
    $d = $null
    if ($_.KeyValue -ge 49 -and $_.KeyValue -le 57) { $d = $_.KeyValue - 48 }      # top row 1-9
    elseif ($_.KeyValue -ge 97 -and $_.KeyValue -le 105) { $d = $_.KeyValue - 96 } # numpad 1-9
    if ($null -ne $d -and $null -ne $script:accounts) {
        $target = $script:accounts | Where-Object { $_.Num -eq $d -and -not $_.Active } | Select-Object -First 1
        if ($null -ne $target) { Switch-To $target }
    }
})

[void]$form.ShowDialog()
