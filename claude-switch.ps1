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
# Runs `cswap <args>` and returns its combined stdout+stderr split into lines.
# With -Pump, the WinForms message loop keeps running while we wait, so the
# window stays responsive (the close/minimize buttons work, and a slow or
# hanging cswap can still be dismissed). cswap --list output is small, so
# reading it after exit can't deadlock the pipe.
function Invoke-Cswap([string[]]$Arguments, [switch]$Pump) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new("cswap", ($Arguments -join " "))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Pump) {
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:closing) { try { $p.Kill() } catch {}; break }
            Start-Sleep -Milliseconds 25
        }
    }
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $out -split "`r?`n"
}

function ConvertTo-XmlText([string]$s) {
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# Modern Windows 10/11 toast: shows the app icon LARGE on the left via
# appLogoOverride. Returns $true on success, $false if the WinRT toast APIs are
# unavailable (older Windows) so the caller can fall back to the legacy balloon.
function Show-ModernToast([string]$title, [string]$message) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,    ContentType=WindowsRuntime] | Out-Null

        # Each line of $message becomes its own <text> element (they stack).
        $lines = $message -split "`r?`n"
        $textXml = ($lines | ForEach-Object { "<text>$(ConvertTo-XmlText $_)</text>" }) -join "`n"

        $imgXml = ""
        if ($script:toastPng -and (Test-Path $script:toastPng)) {
            $uri = ([System.Uri]$script:toastPng).AbsoluteUri
            $imgXml = "<image placement='appLogoOverride' hint-crop='circle' src='$uri'/>"
        }

        $xml = @"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      $imgXml
      <text>$(ConvertTo-XmlText $title)</text>
      $textXml
    </binding>
  </visual>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
        # PowerShell's registered AUMID — present on every Win10/11 box, so no
        # Start Menu shortcut is required for the toast to appear.
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
        return $true
    } catch {
        return $false
    }
}

# Legacy tray balloon — small icon. Fallback for pre-Win10 only.
function Show-LegacyToast([string]$title, [string]$message, [int]$duration) {
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

# Shows a notification, preferring the modern toast (big left icon) and falling
# back to the legacy balloon. Returns a NotifyIcon to dispose, or $null when the
# modern toast handled it (nothing to dispose).
function Show-Toast([string]$title, [string]$message, [int]$duration) {
    if (Show-ModernToast $title $message) { return $null }
    return Show-LegacyToast $title $message $duration
}

# Parse `cswap --list` into a list of account objects. With -Pump the UI stays
# responsive while cswap runs (see Invoke-Cswap).
function Get-Accounts([switch]$Pump) {
    $lines = Invoke-Cswap "--list" -Pump:$Pump
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
$cSubtle  = [System.Drawing.Color]::FromArgb(150, 152, 164)   # subtitle: slightly grayer than $cMuted

$reg  = [System.Drawing.FontStyle]::Regular
$bold = [System.Drawing.FontStyle]::Bold
$FONT_EMAIL = Fnt "Segoe UI Semibold" 14 $reg
$FONT_ORG   = Fnt "Segoe UI"          12 $reg
$FONT_USAGE = Fnt "Segoe UI"          12 $reg
$FONT_NUM   = Fnt "Segoe UI Semibold" 13 $reg
$FONT_TITLE = Fnt "Segoe UI Semibold" 17 $reg
$FONT_SUBTITLE = Fnt "Segoe UI"       15 $reg
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
# PNG sibling for the modern toast (WinRT toasts don't render .ico reliably).
$script:toastPng = Join-Path $baseDir "claude-switch-full.png"

$cBorder = [System.Drawing.Color]::FromArgb(70, 70, 78)

# Layout constants, in logical px at 96 DPI (scaled via Px/Pt/Sz).
$COLS        = 2
$CARD_W      = 240
$CARD_H      = 122
$CARD_MARGIN = 7
$FLOW_PAD    = 6
$HEADER_H    = 46
$SUBBAR_H    = 28     # "Select account" subtitle strip above the cards
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
# Start fully transparent so the window can fade in once shown.
$form.Opacity = 0
if (Test-Path $script:iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:iconPath) } catch {}
}

# State flags. $closing lets a slow cswap call bail when the user closes the
# window mid-load; $loading suppresses refresh while the initial load runs.
$script:closing = $false
$script:loading = $false
$form.Add_FormClosing({ $script:closing = $true })
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
$lblTitle.Text = $form.Text   # project name (e.g. "Claude Switch")
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

# The card grid is always $COLS columns wide, so the final window width is known
# before the (slow) account load. Sizing the window to it up front means the
# header + buttons never reposition when the cards arrive. (Matches Render's
# no-scroll width; the rare scrollbar case widens it by one scrollbar afterward.)
function Get-GridWidth {
    $cardOuterW = (Px $CARD_W) + 2 * (Px $CARD_MARGIN)
    return ($COLS * $cardOuterW + 2 * (Px $FLOW_PAD))
}

# Height for a $rows-row layout. Used to size the loading window to the SAME
# height the cards will need, so the common 1-row case has zero window resize
# when loading finishes — only the content (loading -> cards) crossfades.
# Mirrors Render's height math exactly.
function Get-GridHeight([int]$rows) {
    $cardOuterH = (Px $CARD_H) + 2 * (Px $CARD_MARGIN)
    $contentH = $rows * $cardOuterH + 2 * (Px $FLOW_PAD)
    return ((Px $HEADER_H) + (Px $SUBBAR_H) + $contentH)
}

# Center the form on the screen it's currently on. Used only at startup so a
# window the user has dragged elsewhere is never yanked back.
function Center-Form {
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = $wa.X + [int](($wa.Width  - $form.Width)  / 2)
    $y = $wa.Y + [int](($wa.Height - $form.Height) / 2)
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

# Content area below the header. Everything that fades during a transition
# (subtitle, cards, loading splash) lives here, so the header stays static and
# the open fade-in is the only time the whole window fades.
$content = New-Object System.Windows.Forms.Panel
$content.Dock = "Fill"
$content.BackColor = $cBg
$form.Controls.Add($content)
# Dock fill must be brought to front so it fills the area BELOW the (Top-docked)
# header instead of the whole form. Without this, $content covers the header and
# the crossfade overlay (sized to $content) hides it, making the header seem to
# "reappear" after the cards.
$content.BringToFront()

# Scrollable flow container: cards sit side by side and wrap to new rows.
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = "Fill"
$flow.FlowDirection = "LeftToRight"
$flow.WrapContents = $true
$flow.AutoScroll = $true
$flow.BackColor = $cBg
$flow.Padding = New-Object System.Windows.Forms.Padding((Px $FLOW_PAD))
# "Select account" subtitle: smaller, slightly grayer, centered just above the
# cards. Hidden during loading; revealed (faded in) together with the cards.
$subBar = New-Object System.Windows.Forms.Panel
$subBar.Dock = "Top"
$subBar.Height = Px $SUBBAR_H
$subBar.BackColor = $cBg
$subBar.Visible = $false
$subLbl = New-Object System.Windows.Forms.Label
$subLbl.Dock = "Fill"
$subLbl.TextAlign = "MiddleCenter"
$subLbl.Text = "Select account"
$subLbl.Font = $FONT_SUBTITLE
$subLbl.ForeColor = $cSubtle
$subBar.Controls.Add($subLbl)
$content.Controls.Add($subBar)

$content.Controls.Add($flow)
$flow.BringToFront()

# ---------------------------------------------------------------------------
# Loading splash
# ---------------------------------------------------------------------------
# `cswap --list` is a blocking subprocess call. Running it on the UI thread
# (inside Add_Shown) freezes painting, so the window would otherwise appear as a
# half-drawn gray box until cswap answers. We show this splash — the app icon
# centered over a "loading" label — and force a paint BEFORE the blocking call.

# Load the PNG into memory (don't lock the file on disk).
$script:splashImg = $null
if (Test-Path $script:toastPng) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($script:toastPng)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $script:splashImg = [System.Drawing.Image]::FromStream($ms)
    } catch {}
}

$splash = New-Object System.Windows.Forms.Panel
$splash.Dock = "Fill"
$splash.BackColor = $cBg

$splashPic = New-Object System.Windows.Forms.PictureBox
$splashPic.SizeMode = "Zoom"
$splashPic.Size = Sz 88 88
$splashPic.BackColor = [System.Drawing.Color]::Transparent
if ($null -ne $script:splashImg) { $splashPic.Image = $script:splashImg }
$splash.Controls.Add($splashPic)

$splashLbl = New-Object System.Windows.Forms.Label
$splashLbl.Text = "Carregando contas…"
$splashLbl.Font = $FONT_ORG
$splashLbl.ForeColor = $cMuted
$splashLbl.AutoSize = $true
$splash.Controls.Add($splashLbl)

# Center the icon + label whenever the splash is sized.
$layoutSplash = {
    $w = $splash.ClientSize.Width
    $h = $splash.ClientSize.Height
    $gap = Px 12
    $blockH = $splashPic.Height + $gap + $splashLbl.Height
    $top = [int](($h - $blockH) / 2)
    $splashPic.Location = New-Object System.Drawing.Point([int](($w - $splashPic.Width) / 2), $top)
    $splashLbl.Location = New-Object System.Drawing.Point([int](($w - $splashLbl.Width) / 2), ($splashPic.Bottom + $gap))
}.GetNewClosure()
$splash.Add_Resize($layoutSplash)

$content.Controls.Add($splash)
$splash.BringToFront()

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
        if ($null -ne $toast) { $toast.Dispose() }
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

function Render([switch]$Pump) {
    $accounts = Get-Accounts -Pump:$Pump
    # The user may have closed the window while cswap was running.
    if ($form.IsDisposed -or $script:closing) { return @() }
    $flow.Controls.Clear()
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

    # Size the window: $COLS columns wide. The flow padding + card margins give a
    # uniform 13px gutter on every side (left/right/top/bottom); no extra slack,
    # so the bottom margin matches the sides and grows by one row at a time.
    $rows = [math]::Ceiling($accounts.Count / [double]$COLS)
    $cardOuterW = (Px $CARD_W) + 2 * (Px $CARD_MARGIN)
    $cardOuterH = (Px $CARD_H) + 2 * (Px $CARD_MARGIN)
    $padPx  = Px $FLOW_PAD
    $contentW = $COLS * $cardOuterW + 2 * $padPx
    $contentH = $rows * $cardOuterH + 2 * $padPx
    $maxFlowH = Px 640
    $needScroll = $contentH -gt $maxFlowH
    # Only enable AutoScroll when needed — otherwise the FlowLayoutPanel reserves
    # scrollbar width and squeezes a column out.
    $flow.AutoScroll = $needScroll
    $sbW = if ($needScroll) { [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { 0 }
    $clientW = $contentW + $sbW
    $flowH = if ($needScroll) { $maxFlowH } else { $contentH }
    # Always reserve the subtitle strip's height so the layout doesn't jump when
    # it's revealed after loading.
    $newH = (Px $HEADER_H) + (Px $SUBBAR_H) + $flowH

    # Repaint the whole form (header + border) ONLY when the size actually changes
    # — otherwise just the cards, so the header never flickers on a same-size
    # (re)load, matching the reload behavior.
    if ($form.ClientSize.Width -ne $clientW -or $form.ClientSize.Height -ne $newH) {
        $form.ClientSize = New-Object System.Drawing.Size($clientW, $newH)
        Position-HeaderButtons $clientW
        $form.Invalidate()
    } else {
        $flow.Invalidate()
    }

    return $accounts
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
$script:accounts = $null

# Animate $form.Opacity from $from to $to over ~$ms ms. Used ONLY for the open
# fade-in of the whole window. Content transitions use Swap-Content (below) so
# the header doesn't fade with them.
function Fade-Form([double]$from, [double]$to, [int]$ms) {
    $steps = 10
    $dt = [int][math]::Max(1, $ms / $steps)
    $delta = ($to - $from) / $steps
    $o = $from
    try { $form.Opacity = [math]::Max(0.0, [math]::Min(1.0, $o)) } catch {}
    for ($i = 0; $i -lt $steps; $i++) {
        $o += $delta
        try { $form.Opacity = [math]::Max(0.0, [math]::Min(1.0, $o)) } catch {}
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $dt
    }
    try { $form.Opacity = $to } catch {}
}

# Snapshot a control's current pixels into a bitmap.
function Snapshot-Of($ctl) {
    $w = $ctl.ClientSize.Width; $h = $ctl.ClientSize.Height
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $ctl.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    return $bmp
}

# The overlay panel draws $script:ovImg at $script:ovAlpha (see Swap-Content's
# Paint handler). We keep the source bitmap fixed and vary only the alpha, so
# each frame is a single alpha-blended DrawImage with NO per-frame bitmap
# allocation — that's what keeps the fade smooth instead of laggy. (A Panel, not
# a PictureBox: PictureBox runs the ImageAnimator on show, which throws on
# bitmaps produced by DrawToBitmap.)
$script:ovImg = $null
$script:ovAlpha = 1.0

# Animate $img from $from to $to opacity over $ms ms. Time-based (alpha derived
# from elapsed time) so the fade lasts exactly $ms and renders as many frames as
# the machine can — instead of a fixed step count whose per-frame Sleep overhead
# stretches the total well past the target (what made it feel laggy).
function Fade-Overlay($overlay, $img, [double]$from, [double]$to, [int]$ms) {
    $script:ovImg = $img
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $t = $sw.ElapsedMilliseconds / [double]$ms
        $script:ovAlpha = [math]::Max(0.0, [math]::Min(1.0, $from + ($to - $from) * $t))
        $overlay.Invalidate(); $overlay.Update()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
    $script:ovAlpha = $to
    $overlay.Invalidate(); $overlay.Update()
}

# Crossfade just $target (e.g. the whole content area, or only the cards): an
# overlay is laid over $target, the current pixels fade out to the background,
# $buildNew runs while hidden, then the new pixels fade in. Whatever is outside
# $target (the header, and on reload the subtitle) never moves or fades.
function Swap-Content($target, [scriptblock]$buildNew, [int]$msOut = 100, [int]$msIn = 100, $oldSource = $null) {
    # Snapshot for the fade-OUT. Defaults to $target, but the caller can pass a
    # different control when $target has overlapping children that DrawToBitmap
    # would composite in the wrong order (e.g. the loading splash sits over the
    # cards inside $content, but DrawToBitmap($content) renders the cards on top).
    $src = if ($null -ne $oldSource) { $oldSource } else { $target }
    $bmpOld = Snapshot-Of $src
    if ($null -eq $bmpOld) { & $buildNew; return }
    $parent = $target.Parent

    $ov = New-Object System.Windows.Forms.Panel
    $ov.Bounds = $target.Bounds
    $ov.BackColor = $cBg
    # Double-buffer the overlay so the fade doesn't flicker.
    try { $ov.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($ov, $true, $null) } catch {}
    # The panel auto-clears to its BackColor ($cBg) each paint; we draw the source
    # image over it at the current alpha. No bitmap is allocated per frame.
    $ov.Add_Paint({
        param($s, $e)
        $img = $script:ovImg
        if ($null -ne $img -and $script:ovAlpha -gt 0) {
            $cm = New-Object System.Drawing.Imaging.ColorMatrix
            $cm.Matrix33 = [single]$script:ovAlpha
            $ia = New-Object System.Drawing.Imaging.ImageAttributes
            $ia.SetColorMatrix($cm)
            $r = New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height)
            $e.Graphics.DrawImage($img, $r, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
            $ia.Dispose()
        }
    })
    $script:ovImg = $bmpOld
    $script:ovAlpha = 1.0
    $parent.Controls.Add($ov)
    $ov.BringToFront()
    $ov.Invalidate(); $ov.Update()
    [System.Windows.Forms.Application]::DoEvents()

    Fade-Overlay $ov $bmpOld 1.0 0.0 $msOut

    & $buildNew
    # Lay out only the swapped area (not the whole form) so the header isn't
    # repainted. The overlay still covers $target, and Snapshot-Of below renders
    # via DrawToBitmap, so no on-screen refresh of $target is needed here.
    try { $target.PerformLayout() } catch {}
    [System.Windows.Forms.Application]::DoEvents()

    # $buildNew may have resized things; re-fit the overlay over the target.
    $ov.Bounds = $target.Bounds
    $bmpNew = Snapshot-Of $target
    Fade-Overlay $ov $bmpNew 0.0 1.0 $msIn

    $parent.Controls.Remove($ov)
    $ov.Dispose()
    # $script:ovImg just aliases $bmpOld/$bmpNew now — clear it, don't dispose it
    # here (the sources are disposed below), to avoid a double-dispose.
    $script:ovImg = $null
    if ($null -ne $bmpOld) { $bmpOld.Dispose() }
    if ($null -ne $bmpNew) { $bmpNew.Dispose() }
}

# Refresh: fade only the cards ($flow) out and the freshly-fetched ones in. The
# header and the "Select account" subtitle stay put. Ignored during the initial
# load to avoid re-entrancy.
$btnRefresh.Add_Click({
    if ($script:loading) { return }
    Swap-Content $flow { $script:accounts = Render } 100 100
})

$form.Add_Shown({
    $script:loading = $true

    # Size the window to its FINAL width (the grid is always $COLS columns) before
    # loading, so the header and its buttons never reposition when the cards
    # arrive — only the height changes. Center it now and again after loading so
    # the window appears to expand from the center.
    # One-row height: with 1-2 accounts (the common case) this equals the final
    # height, so Render's resize is a no-op and only the content crossfades.
    $loadH = Get-GridHeight 1
    $form.ClientSize = New-Object System.Drawing.Size((Get-GridWidth), $loadH)
    Position-HeaderButtons $form.ClientSize.Width
    Center-Form

    # Lay out and paint the loading splash before the cswap call, so the window
    # never shows as a half-drawn gray box. The close/minimize buttons are live
    # the whole time (Render -Pump keeps the message loop running).
    $splash.Visible = $true
    $splash.BringToFront()
    & $layoutSplash
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    # 1) Open: fade the WHOLE window in (this is the only whole-window fade), with
    #    the loading splash showing.
    Fade-Form 0.0 1.0 160

    # 2) Load accounts while the splash is up. -Pump keeps the UI responsive so a
    #    slow/failed cswap can still be dismissed. This sets the final height.
    $script:accounts = Render -Pump
    if ($form.IsDisposed -or $script:closing) { return }
    Center-Form

    # 3) Content-only crossfade: fade the loading out, reveal subtitle + cards,
    #    fade them in. The header does not fade.
    # $splash overlaps the cards inside $content, so snapshot it explicitly for
    # the fade-OUT (DrawToBitmap of $content would grab the cards instead).
    Swap-Content $content { $splash.Visible = $false; $subBar.Visible = $true; $flow.BringToFront() } 100 100 $splash
    $script:loading = $false
})

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
