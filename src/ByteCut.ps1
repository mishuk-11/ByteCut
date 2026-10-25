<#
    ByteCut - desktop app (Windows Forms, Fluent-style UI)
    Developer : Inzamam Islam
    License   : MIT

    Run from source :  powershell -ExecutionPolicy Bypass -File src\ByteCut.ps1
    Scheduled mode  :  ... -Scheduled            (the .exe uses:  ByteCut.exe --scheduled)
    Temp cleaner    :  ... -TempClean [-System] [-Boost]   (ByteCut.exe --tempclean [--system] [--boost])

    UI rules (keep the app snappy):
      - No owner-drawn controls in hot paths: buttons/nav use native flat buttons (hover and
        press colors are drawn by Windows), cards use a pre-rendered background image.
      - No animations. Nothing slow (disk, Task Scheduler) runs on the UI thread.
      - Every themed control is registered with Reg so Light/Dark can switch live.
    Keep this file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI.
#>
param([switch]$Scheduled, [switch]$TempClean, [switch]$System, [switch]$Boost, [string]$ResultFile)

$AppName    = 'ByteCut'
$AppVersion = '4.2.0'
$Developer  = 'Inzamam Islam'
$RepoUrl    = 'https://github.com/mishuk-11/ByteCut'

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------
#  Load the engine. The .exe passes it in $CoreCode; from source we read Core.ps1.
# ---------------------------------------------------------------------
if (-not $CoreCode) { $CoreCode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Core.ps1')) }
if (-not ('Adc.Scanner' -as [type]) -and -not $NativeCode) { $NativeCode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Native.cs')) }
. ([ScriptBlock]::Create($CoreCode))

# Sharp text on scaled displays (125%, 150%...): tell Windows we scale ourselves instead of
# letting it stretch a blurry bitmap of the window. $UiScale = display scale (1.0 at 100%).
try { [void][Adc.Native]::SetProcessDPIAware() } catch {}
$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $UiScale = $gfx.DpiX / 96.0; $gfx.Dispose()
$FontMul = 1.0
if ($env:ADC_FORCE_SCALE) { $UiScale = [double]$env:ADC_FORCE_SCALE; $FontMul = $UiScale }   # layout test at 100%

$IsExe       = [bool]$AppExePath
$ScriptFile  = $PSCommandPath
$IsScheduled = $Scheduled -or (@($AppArgs) -contains '--scheduled')
$Settings    = Get-AdcSettings

$AppIcon = $null
if ($IsExe) { $AppIcon = [Drawing.Icon]::ExtractAssociatedIcon($AppExePath) }
elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot '..\assets\app.ico'))) { $AppIcon = New-Object Drawing.Icon (Join-Path $PSScriptRoot '..\assets\app.ico') }
if (-not $AppIcon) { $AppIcon = [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\cleanmgr.exe") }

# ---------------------------------------------------------------------
#  Scheduled run (no window unless the notification is clicked)
# ---------------------------------------------------------------------
function Show-AdcNotification([string]$Title, [string]$Text, [int]$WaitSeconds = 25) {
    $ni = New-Object Windows.Forms.NotifyIcon
    $ni.Icon = $AppIcon; $ni.Text = $AppName; $ni.Visible = $true
    $state = @{ Clicked = $false }
    $ni.Add_BalloonTipClicked({ $state.Clicked = $true }.GetNewClosure())
    $ni.ShowBalloonTip(10000, $Title, $Text, 'Info')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds -and -not $state.Clicked) {
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150
    }
    $ni.Visible = $false; $ni.Dispose()
    return $state.Clicked
}

$AutoScan = $false
if ($IsScheduled) {
    Set-AdcPowerMode $Settings.PowerMode -WholeProcess
    $res = Invoke-AdcScheduledRun -Settings $Settings
    if ($res.Action -eq 'Clean') {
        if (-not $res.Cleaned) { return }
        $clicked = Show-AdcNotification 'ByteCut cleaned your PC' ("Freed {0} of cache from {1} apps. Click to open." -f (Format-AdcSize $res.Freed), $res.Cleaned)
    } else {
        if (-not $res.Targets.Count) { return }
        $clicked = Show-AdcNotification 'Cache can be cleaned' ("{0} of cache/temp data in {1} apps. Click to review and clean." -f (Format-AdcSize $res.Size), $res.Targets.Count)
    }
    if (-not $clicked) { return }
    Set-AdcPowerMode 'Normal' -WholeProcess          # also turns process-wide Efficiency mode off before showing the window
    $AutoScan = $true
}

# ---------------------------------------------------------------------
#  Command line: Windows temp cleaner (no window)
#    ByteCut.exe --tempclean [--system] [--boost]
#    (from source: ByteCut.ps1 -TempClean [-System] [-Boost])
#  --system needs administrator: ByteCut asks once (UAC) and runs itself again elevated.
#  --result <file> is used by the Settings page: the results go to that JSON file instead.
# ---------------------------------------------------------------------
$argv = @($AppArgs)
if ($TempClean -or ($argv -contains '--tempclean')) {
    $tcSystem = $System -or ($argv -contains '--system')
    $tcBoost  = $Boost -or ($argv -contains '--boost')
    $tcResult = $ResultFile
    $ri = [array]::IndexOf($argv, '--result')
    if (-not $tcResult -and $ri -ge 0 -and ($ri + 1) -lt $argv.Count) { $tcResult = $argv[$ri + 1] }

    if ($tcSystem -and -not (Test-AdcAdmin) -and -not $tcResult) {
        if ($IsExe) { $exe = $AppExePath; $argLine = ($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ' }
        else { $exe = 'powershell.exe'; $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptFile`" -TempClean -System" + $(if ($tcBoost) { ' -Boost' } else { '' }) }
        try { Start-Process $exe -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden } catch {}
        return
    }
    Set-AdcPowerMode $Settings.PowerMode -WholeProcess
    $tc = Invoke-AdcTempClean -System:$tcSystem -Boost:$tcBoost
    if ($tcResult) {
        ConvertTo-Json -InputObject $tc -Depth 4 | Set-Content -LiteralPath $tcResult -Encoding UTF8
    } else {
        Add-AdcHistory 'Temp cleaner (command line)' $(if ($tcSystem) { 'User + system temp' } else { 'User temp' }) @($tc.Items | Where-Object { $_.Freed -gt 0 }).Count $tc.Freed
        [void](Show-AdcNotification 'ByteCut temp cleaner' ("Freed {0} of temp files." -f (Format-AdcSize $tc.Freed)) 6)
    }
    return
}


# =====================================================================
#  Design system (Fluent): palettes, fonts, icons
# =====================================================================
function C([string]$Hex) { [Drawing.ColorTranslator]::FromHtml($Hex) }
$Palettes = @{
    Dark = @{
        Bg = C '#1F1F1F'; Card = C '#2B2B2B'; Stroke = C '#3B3B3B'; Text = C '#FFFFFF'; Muted = C '#B3B3B3'
        Input = C '#333333'; Row = C '#303030'; NavHover = C '#2D2D2D'; NavActive = C '#383838'
        Neutral = C '#3A3A3A'; NeutralHover = C '#444444'; NeutralPress = C '#323232'
        Accent = C '#0078D4'; AccentHover = C '#106EBE'; AccentPress = C '#005A9E'; AccentText = C '#4CC2FF'
        Danger = C '#E81123'; DangerHover = C '#C50F1F'; DangerPress = C '#A80000'
        Success = C '#6CCB5F'; Warning = C '#FF8C55'; Error = C '#FF6B78'; Shadow = 0
    }
    Light = @{
        Bg = C '#F3F3F3'; Card = C '#FFFFFF'; Stroke = C '#E5E5E5'; Text = C '#1E1E1E'; Muted = C '#5D5D5D'
        Input = C '#FFFFFF'; Row = C '#F9F9F9'; NavHover = C '#EAEAEA'; NavActive = C '#E3E3E3'
        Neutral = C '#F0F0F0'; NeutralHover = C '#E6E6E6'; NeutralPress = C '#DADADA'
        Accent = C '#0078D4'; AccentHover = C '#106EBE'; AccentPress = C '#005A9E'; AccentText = C '#0067C0'
        Danger = C '#E81123'; DangerHover = C '#C50F1F'; DangerPress = C '#A80000'
        Success = C '#107C41'; Warning = C '#D83B01'; Error = C '#E81123'; Shadow = 18
    }
}
$T = @{}
function Test-SystemLight {
    $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction SilentlyContinue
    return ($null -eq $v -or $v -ne 0)
}
function Set-Palette([string]$Name) {
    $mode = if ($Name -eq 'Light' -or $Name -eq 'Dark') { $Name } elseif (Test-SystemLight) { 'Light' } else { 'Dark' }
    foreach ($k in @($Palettes[$mode].Keys)) { $T[$k] = $Palettes[$mode][$k] }
    $T.Mode = $mode
}
Set-Palette $Settings.Theme

# Fonts: classic Segoe UI, built into every Windows and hinted for crisp GDI text.
# (Segoe UI Variable looked thin and jagged through GDI.) Sizes in points so they follow the
# display scale; at 100%: 10.5pt = 14px body, 9pt = 12px small, 18pt = 24px titles.
function New-AppFont([string]$Family, [float]$Pt) {
    New-Object Drawing.Font($Family, [float]($Pt * $FontMul), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Point)
}
$F = @{
    Body  = New-AppFont 'Segoe UI' 10.5
    Bold  = New-AppFont 'Segoe UI Semibold' 10.5
    Small = New-AppFont 'Segoe UI' 9
    Title = New-AppFont 'Segoe UI Semibold' 18
    Card  = New-AppFont 'Segoe UI Semibold' 12
    Stat  = New-AppFont 'Segoe UI Semibold' 16.5
    Huge  = New-AppFont 'Segoe UI Semibold' 24
}
$IconFamily = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$Ico = @{ Clean = 0xE8C6; Calendar = 0xE787; History = 0xE81C; Settings = 0xE713; Info = 0xE946
          Apps = 0xE7B8; Drive = 0xEDA2; Broom = 0xEA99; Check = 0xE73E; Total = 0xE9F9 }
$Dot = [string][char]0x2022

# =====================================================================
#  Helpers
# =====================================================================
function Set-DoubleBuffered($Control) {
    $Control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($Control, $true, $null)
}

function New-RoundPath([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90); $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90); $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}

# Icons are drawn as anti-aliased vector shapes (GraphicsPath.AddString + FillPath).
# NEVER set Graphics.TextRenderingHint anywhere in this app: setting it to AntiAlias/AntiAliasGridFit on
# any Graphics switches ClearType off for every text control in the whole process (jagged "C-grade" text).
function Add-GlyphPath($G, [int]$Code, [float]$Px, [float]$Box, [float]$OffsetY, $Brush) {
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $path.AddString([string][char]$Code, (New-Object Drawing.FontFamily($IconFamily)), 0, $Px, (New-Object Drawing.RectangleF(0, $OffsetY, $Box, $Box)), $fmt)
    $G.FillPath($Brush, $path); $path.Dispose()
}

function New-GlyphImage([int]$Code, $Color, [int]$Px = 16, [int]$Box = 20) {
    $Px = [int]($Px * $UiScale); $Box = [int]($Box * $UiScale)
    $bmp = New-Object Drawing.Bitmap($Box, $Box)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    Add-GlyphPath $g $Code $Px $Box 0 (New-Object Drawing.SolidBrush($Color))
    $g.Dispose()
    return $bmp
}

# Round tinted bubble with an icon (stat cards)
function New-BubbleImage([int]$Code, $Tint, $Back, [int]$Box = 40) {
    $bmp = New-Object Drawing.Bitmap($Box, $Box)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear($Back)
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(38, $Tint))), 0, 0, ($Box - 1), ($Box - 1))
    $g.Dispose()
    $glyph = New-GlyphImage $Code $Tint 18 ([int]($Box / $UiScale))
    $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($glyph, 0, 0); $g.Dispose(); $glyph.Dispose()
    return $bmp
}

# App logo tile (accent gradient + scissors)
function New-LogoImage([int]$Size) {
    $bmp = New-Object Drawing.Bitmap($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $rect = New-Object Drawing.Rectangle(0, 0, $Size, $Size)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, (C '#2B95F0'), (C '#005A9E'), 45)
    $g.FillPath($br, (New-RoundPath 0 0 ($Size - 1) ($Size - 1) ($Size * 0.22)))
    Add-GlyphPath $g $Ico.Clean ($Size * 0.5) $Size ($Size * 0.02) ([Drawing.Brushes]::White)
    $g.Dispose()
    return $bmp
}

# ---- Theme registry: every control + its role, so Set-Theme can recolor the whole UI ----
$Themed = New-Object System.Collections.ArrayList
function Reg($Control, [string]$Role) { [void]$Themed.Add(@($Control, $Role)); Apply-Role $Control $Role; return $Control }

function Set-ButtonColors($B, $Back, $Fore, $Hover, $Press) {
    if (-not $B.Enabled) { $Back = $T.Neutral; $Hover = $T.Neutral; $Press = $T.Neutral; $Fore = $T.Muted }   # disabled look
    $B.BackColor = $Back; $B.ForeColor = $Fore
    $B.FlatAppearance.MouseOverBackColor = $Hover; $B.FlatAppearance.MouseDownBackColor = $Press
}

# Role "name" or "name:ColorKey" (ColorKey overrides the text color)
function Apply-Role($Ctl, [string]$Role) {
    $base, $key = $Role.Split(':')
    $white = [Drawing.Color]::White
    switch ($base) {
        'page'       { $Ctl.BackColor = $T.Bg }
        'card'       { $Ctl.BackColor = $T.Bg; Update-CardImage $Ctl }
        'text'       { $Ctl.BackColor = $T.Card; $Ctl.ForeColor = $T.Text }
        'muted'      { $Ctl.BackColor = $T.Card; $Ctl.ForeColor = $T.Muted }
        'pageText'   { $Ctl.BackColor = $T.Bg;   $Ctl.ForeColor = $T.Text }
        'pageMuted'  { $Ctl.BackColor = $T.Bg;   $Ctl.ForeColor = $T.Muted }
        'input'      { $Ctl.BackColor = $T.Input; $Ctl.ForeColor = $T.Text }
        'accentBtn'  { Set-ButtonColors $Ctl $T.Accent $white $T.AccentHover $T.AccentPress }
        'neutralBtn' { Set-ButtonColors $Ctl $T.Neutral $T.Text $T.NeutralHover $T.NeutralPress }
        'dangerBtn'  { Set-ButtonColors $Ctl $T.Danger $white $T.DangerHover $T.DangerPress }
        'chip'       { $Ctl.BackColor = $T.Neutral; $Ctl.FlatAppearance.CheckedBackColor = $T.Accent
                       $Ctl.FlatAppearance.MouseOverBackColor = $(if ($Ctl.Checked) { $T.AccentHover } else { $T.NeutralHover })
                       $Ctl.FlatAppearance.BorderColor = $T.Stroke
                       $Ctl.ForeColor = $(if ($Ctl.Checked) { $white } else { $T.Text }) }
        'nav'        { Update-NavItem $Ctl }
        'bubble'     { $old = $Ctl.Image; $Ctl.BackColor = $T.Card; $Ctl.Image = New-BubbleImage $Ctl.Tag.Code $T[$Ctl.Tag.Tint] $T.Card ([int](40 * $UiScale)); if ($old) { $old.Dispose() } }
        'pill'       { $Ctl.BackColor = $T.Accent }
        'track'      { $Ctl.BackColor = $T.Stroke }
        'fill'       { $Ctl.BackColor = $T.Accent }
        'toggle'     { $Ctl.BackColor = $T.Card; $Ctl.Invalidate() }
        'list'       { $Ctl.BackColor = $T.Card; $Ctl.ForeColor = $T.Text; [Adc.Ui]::ThemeListView($Ctl.Handle, ($T.Mode -eq 'Dark')) }
        'listbox'    { $Ctl.BackColor = $T.Card; $Ctl.ForeColor = $T.Text; [Adc.Ui]::ThemeControl($Ctl.Handle, ($T.Mode -eq 'Dark')) }
    }
    if ($key) { $Ctl.ForeColor = $T[$key] }
}

# Card = panel with a pre-rendered rounded background (8px radius, 1px stroke, soft shadow in Light)
function Update-CardImage($P) {
    if ($P.Width -lt 8 -or $P.Height -lt 8) { return }
    $bmp = New-Object Drawing.Bitmap($P.Width, $P.Height)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear($T.Bg)
    $r = 8 * $UiScale
    if ($T.Shadow) { $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb($T.Shadow, 0, 0, 0))), (New-RoundPath 0.5 1.5 ($P.Width - 1.5) ($P.Height - 2) $r)) }
    $path = New-RoundPath 0.5 0.5 ($P.Width - 1.5) ($P.Height - 2.5) $r
    $g.FillPath((New-Object Drawing.SolidBrush($T.Card)), $path)
    $g.DrawPath((New-Object Drawing.Pen($T.Stroke)), $path)
    $g.Dispose()
    $old = $P.BackgroundImage; $P.BackgroundImage = $bmp; if ($old) { $old.Dispose() }
}

# Rounded corners via a window region, recomputed whenever the control is resized (e.g. by scaling).
# The radius (in 96-DPI pixels) is read from $Control.Tag.Radius.
function Set-RoundRegion($Ctl) {
    if ($Ctl.Width -lt 2 -or $Ctl.Height -lt 2) { return }
    $old = $Ctl.Region
    $Ctl.Region = New-Object Drawing.Region((New-RoundPath 0 0 $Ctl.Width $Ctl.Height ($Ctl.Tag.Radius * $UiScale)))
    if ($old) { $old.Dispose() }
}
function Add-RoundCorners($Ctl) { Set-RoundRegion $Ctl; $Ctl.Add_Resize({ Set-RoundRegion $this }) }

function New-Card([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title = '') {
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point($X, $Y); $p.Size = New-Object Drawing.Size($W, $H)
    $p.BackgroundImageLayout = 'None'; Set-DoubleBuffered $p
    [void](Reg $p 'card')
    $p.Add_Resize({ Update-CardImage $this })
    if ($Title) { $p.Controls.Add((New-Label $Title 20 16 $F.Card 'text')) }
    return $p
}

function New-Label([string]$Text, [int]$X, [int]$Y, $Font = $F.Body, [string]$Role = 'text') {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.AutoSize = $true; $l.Location = New-Object Drawing.Point($X, $Y)
    return (Reg $l $Role)
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$W, [string]$Role = 'neutralBtn', [int]$H = 32) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Font = $F.Bold; $b.Location = New-Object Drawing.Point($X, $Y); $b.Size = New-Object Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = [Windows.Forms.Cursors]::Hand; $b.UseVisualStyleBackColor = $false
    $b.Tag = @{ Role = $Role; Radius = 4 }                                    # 4px Fluent corner radius
    Add-RoundCorners $b
    $b.Add_EnabledChanged({ Apply-Role $this $this.Tag.Role })
    return (Reg $b $Role)
}

function New-Check([string]$Text, [int]$X, [int]$Y, [bool]$Checked, [string]$Role = 'text') {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $Text; $c.Location = New-Object Drawing.Point($X, $Y); $c.AutoSize = $true; $c.Checked = $Checked
    $c.Cursor = [Windows.Forms.Cursors]::Hand
    return (Reg $c $Role)
}

function New-Radio([string]$Text, [int]$X, [int]$Y, [bool]$Checked, [string]$Role = 'text') {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = $Text; $r.Location = New-Object Drawing.Point($X, $Y); $r.AutoSize = $true; $r.Checked = $Checked
    $r.Cursor = [Windows.Forms.Cursors]::Hand
    return (Reg $r $Role)
}

function New-Combo([int]$X, [int]$Y, [int]$W, [object[]]$Items) {
    $c = New-Object Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'; $c.Width = $W; $c.Location = New-Object Drawing.Point($X, $Y)
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    return (Reg $c 'input')
}

function New-Chip([string]$Text, [int]$X, [int]$Y, [bool]$Checked) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Appearance = 'Button'; $c.Text = $Text; $c.TextAlign = 'MiddleCenter'; $c.Font = $F.Bold
    $c.Location = New-Object Drawing.Point($X, $Y); $c.Size = New-Object Drawing.Size(56, 32)
    $c.FlatStyle = 'Flat'; $c.Cursor = [Windows.Forms.Cursors]::Hand; $c.Checked = $Checked
    $c.Tag = @{ Radius = 4 }; Add-RoundCorners $c
    $c.Add_CheckedChanged({ Apply-Role $this 'chip' })
    return (Reg $c 'chip')
}

# Toggle switch (painted only when clicked or recolored, never in a loop)
function New-Toggle([int]$X, [int]$Y, [bool]$On) {
    $tgl = New-Object Windows.Forms.Label
    $tgl.Location = New-Object Drawing.Point($X, $Y); $tgl.Size = New-Object Drawing.Size(42, 22)
    $tgl.Cursor = [Windows.Forms.Cursors]::Hand; $tgl.Tag = @{ On = $On }
    $tgl.Add_Click({ $this.Tag.On = -not $this.Tag.On; $this.Invalidate() })
    $tgl.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $w = $s.Width - 2; $h = $s.Height - 2; $d = $h * 0.55; $y = 1 + ($h - $d) / 2
        $path = New-RoundPath 0.5 0.5 $w $h ($h / 2)
        if ($s.Tag.On) {
            $g.FillPath((New-Object Drawing.SolidBrush($T.Accent)), $path)
            $g.FillEllipse([Drawing.Brushes]::White, ($w - $d - ($h - $d) / 2 + 1), $y, $d, $d)
        } else {
            $g.DrawPath((New-Object Drawing.Pen($T.Muted, [float](1.2 * $UiScale))), $path)
            $g.FillEllipse((New-Object Drawing.SolidBrush($T.Muted)), (1 + ($h - $d) / 2), $y, $d, $d)
        }
    })
    return (Reg $tgl 'toggle')
}

# Stat card: icon bubble + caption + value. Returns @(card, valueLabel)
function New-StatCard([int]$X, [int]$Y, [int]$W, [string]$Caption, [int]$Icon, [string]$TintKey) {
    $card = New-Card $X $Y $W 84
    $bubble = New-Object Windows.Forms.Label
    $bubble.Location = New-Object Drawing.Point(16, 22); $bubble.Size = New-Object Drawing.Size(40, 40)
    $bubble.Tag = @{ Code = $Icon; Tint = $TintKey }
    [void](Reg $bubble 'bubble')
    $cap = New-Label $Caption 68 18 $F.Small 'muted'
    $val = New-Label '-' 66 36 $F.Stat 'text'
    $card.Controls.AddRange(@($bubble, $cap, $val))
    return @($card, $val)
}

# Column header row made of plain labels (the native dark-mode ListView header draws unreadable text).
# $Columns: @{ Text; W; Align }. Click handler gets the column index. Call Update-ListHeader after width changes.
function New-ListHeader($ListView, $Columns, [int]$FirstPad, [scriptblock]$OnClick) {
    $hdr = New-Object Windows.Forms.Panel
    $hdr.Dock = 'Top'; $hdr.Height = 34
    [void](Reg $hdr 'text')
    $line = New-Object Windows.Forms.Panel
    $line.Dock = 'Bottom'; $line.Height = 1
    [void](Reg $line 'track')
    $hdr.Controls.Add($line)
    $labels = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $l = New-Object Windows.Forms.Label
        $l.AutoSize = $false; $l.Height = 33; $l.Font = $F.Bold; $l.AutoEllipsis = $true
        $l.TextAlign = $(if ($Columns[$i].Align -eq 'Right') { 'MiddleRight' } else { 'MiddleLeft' })
        $l.Padding = New-Object Windows.Forms.Padding($(if ($i -eq 0) { $FirstPad } else { 6 }), 0, 8, 0)
        $l.Tag = @{ Index = $i; Base = $Columns[$i].Text }
        if ($OnClick) { $l.Cursor = [Windows.Forms.Cursors]::Hand; $l.Add_Click($OnClick) }
        [void](Reg $l 'muted')
        $hdr.Controls.Add($l); $labels += $l
    }
    $hdr.Tag = @{ Labels = $labels; List = $ListView }
    return $hdr
}

function Update-ListHeader($Hdr, [int]$SortIndex = -1, [bool]$Desc = $false) {
    $x = 0
    foreach ($l in $Hdr.Tag.Labels) {
        $i = $l.Tag.Index
        $w = $Hdr.Tag.List.Columns[$i].Width
        $l.SetBounds($x, 0, $w, ($Hdr.Height - 1)); $x += $w
        $text = $l.Tag.Base
        if ($i -eq $SortIndex) { $text += '  ' + [string][char]$(if ($Desc) { 0x25BC } else { 0x25B2 }); $l.ForeColor = $T.Text } else { $l.ForeColor = $T.Muted }
        $l.Text = $text
    }
}

function Set-Cue($TextBox, [string]$Cue) { [void][Adc.Native]::SendMessage($TextBox.Handle, 0x1501, [IntPtr]1, $Cue) }

function New-PageHeader($Page, [string]$Title, [string]$Subtitle) {
    $Page.Controls.Add((New-Label $Title 32 24 $F.Title 'pageText'))
    $Page.Controls.Add((New-Label $Subtitle 33 60 $F.Body 'pageMuted'))
}

# =====================================================================
#  Window + top navigation bar
# =====================================================================
$form = New-Object Windows.Forms.Form
$form.Text = "$AppName  v$AppVersion"
$form.AutoScaleMode = 'None'                 # we scale ourselves (see Scale at the end)
$form.ClientSize = New-Object Drawing.Size(1040, 760)
$form.StartPosition = 'CenterScreen'
$form.Font = $F.Body; $form.Icon = $AppIcon
[void](Reg $form 'page')

$TopH = 56
$PW = $form.ClientSize.Width; $PH = $form.ClientSize.Height - $TopH       # page design size (96 DPI)
# 12-column grid with 16px gutters and 32px page margins
$M = 32; $Gap = 16; $ColW = ($PW - 2 * $M - 11 * $Gap) / 12
function GX([int]$Col) { [int]($M + $Col * ($ColW + $Gap)) }
function GW([int]$Span) { [int]($Span * $ColW + ($Span - 1) * $Gap) }

$topBar = New-Object Windows.Forms.Panel
$topBar.Dock = 'Top'; $topBar.Height = $TopH
[void](Reg $topBar 'page')
$topLine = New-Object Windows.Forms.Panel
$topLine.Dock = 'Bottom'; $topLine.Height = 1
[void](Reg $topLine 'track')
$topBar.Controls.Add($topLine)

$logo = New-Object Windows.Forms.Label
$logo.Location = New-Object Drawing.Point(24, 14); $logo.Size = New-Object Drawing.Size(28, 28); $logo.Image = New-LogoImage ([int](28 * $UiScale))
[void](Reg $logo 'pageText')
$credit = New-Label "v$AppVersion  $Dot  by $Developer" ($PW - 196) 20 $F.Small 'pageMuted'
$credit.Anchor = 'Top,Right'
$topBar.Controls.AddRange(@($logo, (New-Label $AppName 60 15 $F.Card 'pageText'), $credit))

$Pages = [ordered]@{}
$NavItems = New-Object System.Collections.ArrayList
$script:ActivePage = ''

# Active tab indicator: small accent pill under the tab
$navPill = New-Object Windows.Forms.Panel
$navPill.Size = New-Object Drawing.Size(18, 3); $navPill.Tag = @{ Radius = 1.5 }
Add-RoundCorners $navPill
[void](Reg $navPill 'pill')

function Update-NavItem($N) {
    $active = ($N.Tag.Key -eq $script:ActivePage)
    Set-ButtonColors $N $T.Bg $(if ($active) { $T.Text } else { $T.Muted }) $T.NavHover $T.NavActive
    $N.Font = $(if ($active) { $F.Bold } else { $F.Body })
    $old = $N.Image; $N.Image = New-GlyphImage $N.Tag.Code $(if ($active) { $T.AccentText } else { $T.Muted }) 16 20; if ($old) { $old.Dispose() }
}

function New-NavItem([string]$Key, [string]$Text, [int]$Code, [int]$X) {
    $n = New-Object Windows.Forms.Button
    $n.Text = " $Text"; $n.Location = New-Object Drawing.Point($X, 9); $n.Size = New-Object Drawing.Size(112, 36)
    $n.FlatStyle = 'Flat'; $n.FlatAppearance.BorderSize = 0; $n.UseVisualStyleBackColor = $false
    $n.TextAlign = 'MiddleCenter'; $n.ImageAlign = 'MiddleCenter'; $n.TextImageRelation = 'ImageBeforeText'
    $n.Cursor = [Windows.Forms.Cursors]::Hand
    $n.Tag = @{ Key = $Key; Code = $Code; Radius = 4 }
    Add-RoundCorners $n
    $n.Add_Click({ Show-Page $this.Tag.Key })
    [void]$NavItems.Add($n); $topBar.Controls.Add($n)
    [void](Reg $n 'nav')
}
New-NavItem 'Cleaner'  'Cleaner'  $Ico.Clean    196
New-NavItem 'Schedule' 'Schedule' $Ico.Calendar 312
New-NavItem 'History'  'History'  $Ico.History  428
New-NavItem 'Settings' 'Settings' $Ico.Settings 544
New-NavItem 'About'    'About'    $Ico.Info     660
$topBar.Controls.Add($navPill); $navPill.BringToFront()

function New-Page([string]$Key) {
    $p = New-Object Windows.Forms.Panel
    $p.Size = New-Object Drawing.Size($PW, $PH)      # design size first, so anchors work after docking
    $p.Visible = $false
    [void](Reg $p 'page')
    $Pages[$Key] = $p
    return $p
}

function Show-Page([string]$Key) {
    if ($script:ActivePage -eq $Key) { return }
    $prev = $script:ActivePage; $script:ActivePage = $Key
    $form.SuspendLayout()
    $Pages[$Key].Visible = $true                     # show the new page first: no blank frame
    if ($prev) { $Pages[$prev].Visible = $false }
    foreach ($n in $NavItems) {
        Update-NavItem $n
        if ($n.Tag.Key -eq $Key) { $navPill.Location = New-Object Drawing.Point(($n.Left + [int](($n.Width - $navPill.Width) / 2)), ($n.Bottom + [int]$UiScale)) }
    }
    $form.ResumeLayout()
    switch ($Key) { 'History' { Update-HistoryPage } 'Schedule' { Update-ScheduleStatus } 'Settings' { Update-ExclusionList } }
}

# =====================================================================
#  Background work (never block the UI thread)
# =====================================================================
$script:Job = $null
$JobBootstrap = {
    param($Core, $Mode, $Sync, $Work, $WorkArgs)
    try {
        . ([ScriptBlock]::Create($Core))
        Set-AdcPowerMode $Mode
        $Sync.Result = & ([ScriptBlock]::Create($Work)) @WorkArgs
    } catch { $Sync.Error = $_.Exception.Message }
    $Sync.Finished = $true
}

$jobTimer = New-Object Windows.Forms.Timer
$jobTimer.Interval = 120

# Long work with progress (scan / clean). Only one at a time.
function Start-BackgroundTask([string]$Label, [scriptblock]$Work, [object[]]$WorkArgs, [scriptblock]$OnDone, [hashtable]$Context = @{}) {
    $sync = [hashtable]::Synchronized(@{ Context = $Context; Label = $Label; Done = 0; Total = 0; Current = ''; Cancel = $false; Result = $null; Error = $null; Finished = $false; Started = (Get-Date) })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($JobBootstrap).AddArgument($CoreCode).AddArgument($Settings.PowerMode).AddArgument($sync).AddArgument($Work.ToString()).AddArgument($WorkArgs)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; OnDone = $OnDone }
    Set-Busy $true
    $jobTimer.Start()
}

$jobTimer.Add_Tick({
    $j = $script:Job
    if (-not $j) { $jobTimer.Stop(); return }
    $s = $j.Sync
    if ($s.Total -gt 0) {
        Set-Progress ($s.Done / $s.Total)
        $status.Text = "{0} {1} of {2}   {3}" -f $s.Label, [math]::Min($s.Done + 1, $s.Total), $s.Total, [IO.Path]::GetFileName("$($s.Current)")
    } else { $status.Text = "$($s.Label)..." }
    if ($s.Finished) {
        $jobTimer.Stop()
        try { [void]$j.PS.EndInvoke($j.Handle) } catch {}
        $j.PS.Dispose(); $script:Job = $null
        Set-Busy $false
        & $j.OnDone $s
    }
})

# Small quiet lookups (e.g. Task Scheduler) that must not freeze the window. Several may run at once.
$script:Quiet = New-Object System.Collections.ArrayList
$quietTimer = New-Object Windows.Forms.Timer
$quietTimer.Interval = 100
$quietTimer.Add_Tick({
    foreach ($q in @($script:Quiet)) {
        if (-not $q.Handle.IsCompleted) { continue }
        $out = $null
        try { $out = $q.PS.EndInvoke($q.Handle) } catch {}
        $q.PS.Dispose(); $script:Quiet.Remove($q)
        & $q.OnDone $(if ($out -and $out.Count) { $out[0] } else { $null })
    }
    if (-not $script:Quiet.Count) { $quietTimer.Stop() }
})
# A small runspace pool, opened once, so starting a lookup costs almost nothing on the UI thread
$script:QuietPool = $null
function Start-Quiet([scriptblock]$Work, [scriptblock]$OnDone) {
    if (-not $script:QuietPool) { $script:QuietPool = [RunspaceFactory]::CreateRunspacePool(1, 2); $script:QuietPool.Open() }
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $script:QuietPool
    [void]$ps.AddScript('param($Core, $Work) . ([ScriptBlock]::Create($Core)); & ([ScriptBlock]::Create($Work))').AddArgument($CoreCode).AddArgument($Work.ToString())
    [void]$script:Quiet.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone })
    $quietTimer.Start()
}

# =====================================================================
#  PAGE: Cleaner
# =====================================================================
$pg = New-Page 'Cleaner'
New-PageHeader $pg 'Cleaner' 'Scan your AppData folders and clear app cache, temp and log files.'

$cbRoot = New-Combo (GX 0) 102 150 @('Local', 'Roaming', 'LocalLow', 'All folders')
$cbRoot.SelectedItem = $(if ($cbRoot.Items -contains $Settings.LastRoot) { $Settings.LastRoot } else { 'Local' })
$btnScan = New-Button 'Scan' ((GX 0) + 162) 99 96 'accentBtn'
$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Location = New-Object Drawing.Point(((GX 0) + 272), 102); $txtSearch.Width = 220; $txtSearch.BorderStyle = 'FixedSingle'
[void](Reg $txtSearch 'input')

$SortOptions = [ordered]@{
    'Size (largest first)'       = @('Size', $true)
    'Cache size (largest first)' = @('CacheSize', $true)
    'Priority (highest first)'   = @('Priority', $true)
    'Last used (oldest first)'   = @('LastUsed', $false)
    'Name (A to Z)'              = @('Name', $false)
    'Name (Z to A)'              = @('Name', $true)
}
$cbSort = New-Combo ($PW - $M - 210) 102 210 @($SortOptions.Keys)
$cbSort.Anchor = 'Top,Right'
$lblSort = New-Label 'Sort by' ($PW - $M - 268) 105 $F.Body 'pageMuted'
$lblSort.Anchor = 'Top,Right'
$pg.Controls.AddRange(@($cbRoot, $btnScan, $txtSearch, $lblSort, $cbSort))

$c1, $valApps  = New-StatCard (GX 0) 150 (GW 3) 'App folders'       $Ico.Apps  'Accent'
$c2, $valTotal = New-StatCard (GX 3) 150 (GW 3) 'Total size'        $Ico.Drive 'AccentText'
$c3, $valCache = New-StatCard (GX 6) 150 (GW 3) 'Cleanable cache'   $Ico.Broom 'Warning'
$c4, $valTick  = New-StatCard (GX 9) 150 (GW 3) 'Ticked to clean'   $Ico.Check 'Success'
$pg.Controls.AddRange(@($c1, $c2, $c3, $c4))

$listCard = New-Card (GX 0) 250 (GW 12) ($PH - 250 - 164)
$listCard.Anchor = 'Top,Bottom,Left,Right'; $listCard.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 8)
$list = New-Object Windows.Forms.ListView
$list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.Dock = 'Fill'
$list.BorderStyle = 'None'; $list.HeaderStyle = 'None'; $list.ShowItemToolTips = $true
Set-DoubleBuffered $list
$rowH = New-Object Windows.Forms.ImageList; $rowH.ImageSize = New-Object Drawing.Size(1, [int](30 * $UiScale)); $list.SmallImageList = $rowH
$Columns = @(
    @{ Key = 'Name';      Text = 'App folder'; W = 200; Align = 'Left' }
    @{ Key = 'Priority';  Text = 'Priority';   W = 96;  Align = 'Left' }
    @{ Key = 'Size';      Text = 'Total size'; W = 104; Align = 'Right' }
    @{ Key = 'CacheSize'; Text = 'Cache/temp'; W = 108; Align = 'Right' }
    @{ Key = 'LastUsed';  Text = 'Last used';  W = 112; Align = 'Left' }
    @{ Key = 'Root';      Text = 'Location';   W = 84;  Align = 'Left' }
    @{ Key = 'Path';      Text = 'Path';       W = 200; Align = 'Left' }
)
foreach ($col in $Columns) { [void]$list.Columns.Add($col.Text, [int]($col.W * $UiScale), $col.Align) }
$listHeader = New-ListHeader $list $Columns 26 { Set-SortColumn $this.Tag.Index }
$listCard.Controls.Add($list)
$listCard.Controls.Add($listHeader)            # added last = docks first (on top of the list)
$pg.Controls.Add($listCard)
[void](Reg $list 'list')

function Set-PathColumnWidth {
    $used = 0; for ($i = 0; $i -lt $list.Columns.Count - 1; $i++) { $used += $list.Columns[$i].Width }
    $free = $list.Width - $used - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - [int](8 * $UiScale)
    $list.Columns[$list.Columns.Count - 1].Width = [math]::Max(80, $free)
    Update-SortUi
}
$list.Add_Resize({ Set-PathColumnWidth })

$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen    = $menu.Items.Add('Open folder')
$miCopy    = $menu.Items.Add('Copy path')
[void]$menu.Items.Add('-')
$miExclude = $menu.Items.Add('Never clean this app')
$list.ContextMenuStrip = $menu

$by = $PH - 152
$btnAll    = New-Button 'Tick all'      (GX 0) $by 92
$btnNone   = New-Button 'Untick all'    ((GX 0) + 100) $by 92
$btnHigh   = New-Button 'High'          ((GX 0) + 200) $by 70
$btnMed    = New-Button 'High + Medium' ((GX 0) + 278) $by 124
$btnUnused = New-Button 'Unused 90d+'   ((GX 0) + 410) $by 112
$btnExport = New-Button 'Export CSV'    ($PW - $M - 112) $by 112
foreach ($b in $btnAll, $btnNone, $btnHigh, $btnMed, $btnUnused) { $b.Anchor = 'Bottom,Left' }
$btnExport.Anchor = 'Bottom,Right'

$modeCard = New-Card (GX 0) ($by + 46) (GW 9) 66
$modeCard.Anchor = 'Bottom,Left,Right'
$rbCache = New-Radio 'Delete only cache / temp / log data  (keeps settings and logins)  -  Recommended' 16 10 $true
$rbAll   = New-Radio 'Delete the ENTIRE app folder  (resets the app: settings, logins and saves are lost)' 16 36 $false 'text:Error'
$modeCard.Controls.AddRange(@($rbCache, $rbAll))

$btnDelete = New-Button 'Delete ticked' (GX 9) ($by + 46) (GW 3) 'dangerBtn' 66
$btnDelete.Anchor = 'Bottom,Right'; $btnDelete.Font = $F.Card

# Progress: two plain panels (no painting code)
$track = New-Object Windows.Forms.Panel
$track.Location = New-Object Drawing.Point((GX 0), ($PH - 32)); $track.Size = New-Object Drawing.Size((GW 12), 3)
$track.Anchor = 'Bottom,Left,Right'; $track.Visible = $false
[void](Reg $track 'track')
$fill = New-Object Windows.Forms.Panel
$fill.Location = New-Object Drawing.Point(0, 0); $fill.Size = New-Object Drawing.Size(0, 3)
[void](Reg $fill 'fill')
$track.Controls.Add($fill)
function Set-Progress([double]$Value) { $fill.Width = [int]($track.Width * [math]::Max(0.0, [math]::Min(1.0, $Value))) }

$status = New-Label 'Choose a folder and press Scan. Close the apps you want to clean first.' (GX 0) ($PH - 25) $F.Small 'pageMuted'
$status.AutoSize = $false; $status.Size = New-Object Drawing.Size((GW 12), 18); $status.Anchor = 'Bottom,Left,Right'; $status.AutoEllipsis = $true

$pg.Controls.AddRange(@($btnAll, $btnNone, $btnHigh, $btnMed, $btnUnused, $btnExport, $modeCard, $btnDelete, $track, $status))

$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($btnUnused, 'Ticks apps with no file changes for 90+ days (often leftovers of uninstalled apps). Best used with "Delete the ENTIRE app folder".')
$tips.SetToolTip($btnHigh, 'Ticks apps with 100 MB or more of cache')
$tips.SetToolTip($btnMed, 'Ticks apps with 10 MB or more of cache')

# ---------------- Cleaner logic ----------------
$script:Rows     = @()
$script:SortKey  = "$($Settings.SortKey)"
$script:SortDesc = [bool]$Settings.SortDesc
$script:Syncing  = $false

function Update-Stats {
    $total = 0L; $cache = 0L; $ticked = 0; $tickedCache = 0L
    foreach ($r in $script:Rows) {
        $total += $r.Size
        if ($r.PriorityRank -ge 0) { $cache += $r.CacheSize }
        if ($r.Checked) { $ticked++; $tickedCache += $r.CacheSize }
    }
    $valApps.Text  = '{0:N0}' -f $script:Rows.Count
    $valTotal.Text = Format-AdcSize $total
    $valCache.Text = Format-AdcSize $cache
    $valTick.Text  = if ($ticked) { "$ticked  ($(Format-AdcSize $tickedCache))" } else { '0' }
}

function Update-SortUi {
    $idx = -1; for ($i = 0; $i -lt $Columns.Count; $i++) { if ($Columns[$i].Key -eq $script:SortKey) { $idx = $i } }
    Update-ListHeader $listHeader $idx $script:SortDesc
    $script:Syncing = $true
    $cbSort.SelectedIndex = -1
    $i = 0
    foreach ($k in $SortOptions.Keys) {
        if ($SortOptions[$k][0] -eq $script:SortKey -and $SortOptions[$k][1] -eq $script:SortDesc) { $cbSort.SelectedIndex = $i }
        $i++
    }
    $script:Syncing = $false
}

function Get-SortedRows {
    $d = $script:SortDesc
    $props = switch ($script:SortKey) {
        'Priority' { @(@{ Expression = 'PriorityRank'; Descending = $d }, @{ Expression = 'CacheSize'; Descending = $d }) }
        'LastUsed' { @(@{ Expression = 'LastUsedTicks'; Descending = $d }) }
        default    { @(@{ Expression = $script:SortKey; Descending = $d }) }
    }
    return @($script:Rows | Sort-Object -Property $props)
}

function Get-PriorityColor([string]$P) {
    switch ($P) { 'High' { $T.Error } 'Medium' { $T.Warning } 'Low' { $T.Success } default { $T.Muted } }
}

function Show-Rows {
    Update-SortUi
    $list.BeginUpdate(); $list.Items.Clear()
    $q = $txtSearch.Text.Trim(); $n = 0
    foreach ($r in (Get-SortedRows)) {
        if ($q -and $r.Name -notlike "*$q*" -and $r.Path -notlike "*$q*") { continue }
        $it = New-Object Windows.Forms.ListViewItem($r.Name)
        $it.UseItemStyleForSubItems = $false
        $pri = $it.SubItems.Add($r.Priority)
        [void]$it.SubItems.Add((Format-AdcSize $r.Size))
        [void]$it.SubItems.Add((Format-AdcSize $r.CacheSize))
        $age = $it.SubItems.Add((Format-AdcAge $r.LastUsed))
        $loc = $it.SubItems.Add($r.Root)
        $pth = $it.SubItems.Add($r.Path)
        $back = if ($n % 2) { $T.Row } else { $T.Card }
        foreach ($si in $it.SubItems) { $si.BackColor = $back; $si.ForeColor = $T.Text }
        $pri.ForeColor = Get-PriorityColor $r.Priority; $pri.Font = $F.Bold
        $pth.ForeColor = $T.Muted; $loc.ForeColor = $T.Muted
        if ($r.DaysUnused -ge 90) { $age.ForeColor = $T.Warning }
        if ($r.PriorityRank -lt 0) { $it.SubItems[0].ForeColor = $T.Muted }
        $it.Tag = $r
        $it.ToolTipText = "$($r.Path)`n$($r.Files) files  $Dot  last change $(Format-AdcAge $r.LastUsed)"
        $it.Checked = [bool]$r.Checked
        [void]$list.Items.Add($it)
        $n++
    }
    $list.EndUpdate()
    Set-PathColumnWidth              # also refreshes the header row
}

function Set-Busy([bool]$Busy) {
    foreach ($c in $btnDelete, $cbRoot, $btnAll, $btnNone, $btnHigh, $btnMed, $btnUnused, $btnExport, $btnRunNow, $btnSaveSchedule, $btnTemp) { $c.Enabled = -not $Busy }
    $btnScan.Text = if ($Busy) { 'Stop' } else { 'Scan' }
    $btnScan.Tag.Role = $(if ($Busy) { 'neutralBtn' } else { 'accentBtn' }); Apply-Role $btnScan $btnScan.Tag.Role
    $track.Visible = $Busy; Set-Progress 0
}

function Start-Scan {
    $sel = "$($cbRoot.SelectedItem)"
    $roots = if ($sel -eq 'All folders') { @('Local', 'Roaming', 'LocalLow') } else { @($sel) }
    $Settings.LastRoot = $sel; Save-AdcSettings $Settings
    Start-BackgroundTask 'Scanning' {
        param($Roots, $Excl)
        Invoke-AdcScan -RootNames $Roots -Exclusions $Excl -Sync $Sync
    } @($roots, @($Settings.Exclusions)) {
        param($s)
        if ($s.Error) { $status.Text = "Scan failed: $($s.Error)"; return }
        $script:Rows = @($s.Result | Where-Object { $_ })
        foreach ($r in $script:Rows) { $r | Add-Member -NotePropertyName Checked -NotePropertyValue $false -Force }
        Show-Rows; Update-Stats
        $secs = ((Get-Date) - $s.Started).TotalSeconds
        $note = if ($s.Cancel) { 'Scan stopped' } else { 'Scan complete' }
        $status.Text = "{0}: {1} app folders in {2:N1}s  ({3} mode)" -f $note, $script:Rows.Count, $secs, $Settings.PowerMode
    }
}

$btnScan.Add_Click({
    if ($script:Job) { $script:Job.Sync.Cancel = $true; $status.Text = 'Stopping...'; return }
    Start-Scan
})
$txtSearch.Add_TextChanged({ Show-Rows })

$cbSort.Add_SelectedIndexChanged({
    if ($script:Syncing -or $cbSort.SelectedIndex -lt 0) { return }
    $o = $SortOptions[$cbSort.SelectedItem]
    $script:SortKey = $o[0]; $script:SortDesc = $o[1]
    $Settings.SortKey = $script:SortKey; $Settings.SortDesc = $script:SortDesc; Save-AdcSettings $Settings
    Show-Rows
})

function Set-SortColumn([int]$Index) {
    $key = $Columns[$Index].Key
    if ($key -eq $script:SortKey) { $script:SortDesc = -not $script:SortDesc }
    else { $script:SortKey = $key; $script:SortDesc = ($key -in @('Size', 'CacheSize', 'Priority')) }
    $Settings.SortKey = $script:SortKey; $Settings.SortDesc = $script:SortDesc; Save-AdcSettings $Settings
    Show-Rows
}

$list.Add_ItemChecked({ param($s, $e)
    if ($e.Item.Tag) { $e.Item.Tag.Checked = $e.Item.Checked; Update-Stats }
})

function Set-Ticks([scriptblock]$Rule) {
    $list.BeginUpdate()
    foreach ($it in $list.Items) { $it.Checked = [bool](& $Rule $it.Tag) }
    $list.EndUpdate()
}
$btnAll.Add_Click({    Set-Ticks { param($r) $r.PriorityRank -ge 0 } })
$btnNone.Add_Click({   Set-Ticks { param($r) $false } })
$btnHigh.Add_Click({   Set-Ticks { param($r) $r.PriorityRank -eq 3 } })
$btnMed.Add_Click({    Set-Ticks { param($r) $r.PriorityRank -ge 2 } })
$btnUnused.Add_Click({ Set-Ticks { param($r) $r.PriorityRank -ge 0 -and $r.DaysUnused -ge 90 } })

$btnExport.Add_Click({
    if (-not $script:Rows.Count) { $status.Text = 'Scan first, then export.'; return }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = "AppData-scan-$(Get-Date -Format 'yyyy-MM-dd').csv"
    if ($dlg.ShowDialog() -eq 'OK') {
        Get-SortedRows | Select-Object Name, Priority, Root,
            @{ n = 'TotalMB'; e = { [math]::Round($_.Size / 1MB, 2) } },
            @{ n = 'CacheMB'; e = { [math]::Round($_.CacheSize / 1MB, 2) } },
            @{ n = 'LastUsed'; e = { if ($_.LastUsed) { $_.LastUsed.ToString('yyyy-MM-dd') } else { '' } } },
            DaysUnused, Path | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        $status.Text = "Exported to $($dlg.FileName)"
    }
})

$menu.Add_Opening({ param($s, $e)
    if (-not $list.SelectedItems.Count) { $e.Cancel = $true; return }
    $r = $list.SelectedItems[0].Tag
    $miExclude.Text = if ($r.PriorityRank -eq -2) { 'Allow cleaning this app again' } else { 'Never clean this app' }
})
$miOpen.Add_Click({ Start-Process explorer.exe $list.SelectedItems[0].Tag.Path })
$miCopy.Add_Click({ [Windows.Forms.Clipboard]::SetText($list.SelectedItems[0].Tag.Path) })
$miExclude.Add_Click({
    $r = $list.SelectedItems[0].Tag
    if ($Settings.Exclusions -contains $r.Path) { $Settings.Exclusions = @($Settings.Exclusions | Where-Object { $_ -ne $r.Path }) }
    else { $Settings.Exclusions = @($Settings.Exclusions) + $r.Path; $r.Checked = $false }
    Save-AdcSettings $Settings
    Set-AdcPriority $r @($Settings.Exclusions)
    Show-Rows; Update-Stats
})
$list.Add_DoubleClick({ if ($list.SelectedItems.Count) { Start-Process explorer.exe $list.SelectedItems[0].Tag.Path } })

$btnDelete.Add_Click({
    $ticked = @($script:Rows | Where-Object { $_.Checked })
    if (-not $ticked.Count) { [void][Windows.Forms.MessageBox]::Show('Tick at least one app first.', $AppName, 'OK', 'Information'); return }
    $entire = $rbAll.Checked
    $mode = if ($entire) { 'DELETE THE ENTIRE FOLDER of' } else { 'delete the cache / temp / log data of' }
    $names = ($ticked | Select-Object -First 15 | ForEach-Object { "   $Dot $($_.Name)" }) -join "`n"
    if ($ticked.Count -gt 15) { $names += "`n   ...and $($ticked.Count - 15) more" }
    $ans = [Windows.Forms.MessageBox]::Show("This will permanently $mode`n`n$names`n`nClose these apps first. Continue?", 'Confirm delete', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $modeName = if ($entire) { 'Entire' } else { 'Cache' }
    Start-BackgroundTask 'Cleaning' {
        param($Rows, $Mode)
        Invoke-AdcClean $Rows $Mode $Sync
    } @($ticked, $modeName) {
        param($s)
        if ($s.Error) { [void][Windows.Forms.MessageBox]::Show("Cleaning failed: $($s.Error)", $AppName); return }
        $r = $s.Result
        Add-AdcHistory 'Manual' $(if ($s.Context.Mode -eq 'Entire') { 'Entire folder' } else { 'Cache only' }) $r.Cleaned $r.Freed
        $msg = "Freed $(Format-AdcSize $r.Freed) from $($r.Cleaned) apps.`n`nFiles that were in use were skipped."
        if (@($r.Skipped).Count) { $msg += "`n`nSkipped (protected or excluded): $(@($r.Skipped) -join ', ')" }
        [void][Windows.Forms.MessageBox]::Show($msg, 'Done', 'OK', 'Information')
        Start-Scan
    } @{ Mode = $modeName }
})

# =====================================================================
#  PAGE: Schedule
# =====================================================================
$psched = New-Page 'Schedule'
New-PageHeader $psched 'Schedule' 'Let ByteCut check or clean your PC automatically every week.'
$sc = $Settings.Schedule
$cardW = GW 12

$when = New-Card (GX 0) 100 $cardW 130 'When'
$tglEnabled = New-Toggle ($cardW - 62) 18 ([bool]$sc.Enabled)
$lblEnabled = New-Label 'Enabled' ($cardW - 124) 18 $F.Body 'text'
$when.Controls.AddRange(@($tglEnabled, $lblEnabled, (New-Label 'Days' 20 50 $F.Small 'muted')))
$DayNames = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$DayChips = @{}
for ($i = 0; $i -lt 7; $i++) {
    $chip = New-Chip $DayNames[$i].Substring(0, 3) (20 + $i * 62) 72 (@($sc.Days) -contains $DayNames[$i])
    $DayChips[$DayNames[$i]] = $chip; $when.Controls.Add($chip)
}
$when.Controls.Add((New-Label 'Time' 480 50 $F.Small 'muted'))
$Times = foreach ($hh in 0..23) { foreach ($mm in 0, 15, 30, 45) { '{0:D2}:{1:D2}' -f $hh, $mm } }
$cbTime = New-Combo 480 76 90 @($Times)
$cbTime.SelectedItem = $(if ($Times -contains $sc.Time) { $sc.Time } else { '20:00' })
$when.Controls.Add($cbTime)

$what = New-Card (GX 0) 246 $cardW 210 'What to do'
$rbNotify = New-Radio 'Just notify me  (nothing is deleted, click the notification to review)' 20 48 ($sc.Action -ne 'Clean')
$rbAuto   = New-Radio 'Clean automatically  (cache / temp / logs only, never whole folders)' 20 74 ($sc.Action -eq 'Clean')
$what.Controls.AddRange(@($rbNotify, $rbAuto, (New-Label 'Priorities to clean' 20 108 $F.Small 'muted')))
$chkHigh = New-Check 'High  (100 MB+)' 20 128 (@($sc.Priorities) -contains 'High') 'text:Error'
$chkMed  = New-Check 'Medium  (10 MB+)' 160 128 (@($sc.Priorities) -contains 'Medium') 'text:Warning'
$chkLow  = New-Check 'Low' 310 128 (@($sc.Priorities) -contains 'Low') 'text:Success'
$what.Controls.AddRange(@($chkHigh, $chkMed, $chkLow, (New-Label 'Folders' 20 160 $F.Small 'muted')))
$chkLocal    = New-Check 'Local'    20  180 (@($sc.Roots) -contains 'Local')
$chkRoaming  = New-Check 'Roaming'  110 180 (@($sc.Roots) -contains 'Roaming')
$chkLocalLow = New-Check 'LocalLow' 214 180 (@($sc.Roots) -contains 'LocalLow')
$what.Controls.AddRange(@($chkLocal, $chkRoaming, $chkLocalLow, (New-Label 'Unused apps' 480 108 $F.Small 'muted')))
$chkUnused = New-Check 'Only apps unused for at least' 480 128 ([bool]$sc.UnusedOnly)
$numDays = New-Object Windows.Forms.NumericUpDown
$numDays.Minimum = 1; $numDays.Maximum = 3650; $numDays.Value = [int]$sc.UnusedDays; $numDays.Width = 64; $numDays.BorderStyle = 'FixedSingle'
$numDays.Location = New-Object Drawing.Point(692, 126)
[void](Reg $numDays 'input')
$what.Controls.AddRange(@($chkUnused, $numDays, (New-Label 'days' 762 129 $F.Body 'text')))

$power = New-Card (GX 0) 472 $cardW 100 'Power saving'
$chkAC   = New-Check 'Only run when plugged in  (skip on battery)' 20 46 ([bool]$sc.OnlyOnAC)
$chkIdle = New-Check 'Only run when the PC is idle  (waits until you are away)' 20 70 ([bool]$sc.OnlyIdle)
$power.Controls.AddRange(@($chkAC, $chkIdle))
foreach ($x in $when, $what, $power) { $x.Anchor = 'Top,Left,Right' }
$tglEnabled.Anchor = 'Top,Right'; $lblEnabled.Anchor = 'Top,Right'

$btnSaveSchedule = New-Button 'Save schedule' (GX 0) 590 140 'accentBtn' 36
$btnRunNow       = New-Button 'Run now' ((GX 0) + 152) 590 104 'neutralBtn' 36
$lblNext = New-Label '' ((GX 0) + 272) 598 $F.Body 'pageMuted'
$psched.Controls.AddRange(@($when, $what, $power, $btnSaveSchedule, $btnRunNow, $lblNext))

function Read-ScheduleForm {
    $s = $Settings.Schedule
    $s.Enabled    = [bool]$tglEnabled.Tag.On
    $s.Days       = @($DayNames | Where-Object { $DayChips[$_].Checked })
    $s.Time       = "$($cbTime.SelectedItem)"
    $s.Action     = if ($rbAuto.Checked) { 'Clean' } else { 'Notify' }
    $s.Priorities = @(@('High', 'Medium', 'Low') | Where-Object {
        ($_ -eq 'High' -and $chkHigh.Checked) -or ($_ -eq 'Medium' -and $chkMed.Checked) -or ($_ -eq 'Low' -and $chkLow.Checked) })
    $s.Roots      = @(@('Local', 'Roaming', 'LocalLow') | Where-Object {
        ($_ -eq 'Local' -and $chkLocal.Checked) -or ($_ -eq 'Roaming' -and $chkRoaming.Checked) -or ($_ -eq 'LocalLow' -and $chkLocalLow.Checked) })
    $s.UnusedOnly = $chkUnused.Checked
    $s.UnusedDays = [int]$numDays.Value
    $s.OnlyOnAC   = $chkAC.Checked
    $s.OnlyIdle   = $chkIdle.Checked
}

# Task Scheduler is slow (~0.7 s), so ask it in the background and show the last known answer meanwhile
$script:SchedInfo = $null
function Show-ScheduleInfo {
    $i = $script:SchedInfo
    if ($i -and $i.NextRun) {
        $last = if ($i.LastRun -and $i.LastRun.Year -gt 2000) { "   $Dot   Last run: $($i.LastRun.ToString('ddd dd MMM HH:mm'))" } else { '' }
        $lblNext.Text = "Next run: $($i.NextRun.ToString('dddd dd MMM, HH:mm'))$last"
        $lblNext.ForeColor = $T.Success
    } else { $lblNext.Text = 'No schedule is active.'; $lblNext.ForeColor = $T.Muted }
}
function Update-ScheduleStatus {
    Show-ScheduleInfo
    Start-Quiet { Get-AdcScheduleInfo } { param($info) $script:SchedInfo = $info; Show-ScheduleInfo }
}

$btnSaveSchedule.Add_Click({
    Read-ScheduleForm
    $s = $Settings.Schedule
    if ($s.Enabled -and (-not @($s.Days).Count -or -not @($s.Priorities).Count -or -not @($s.Roots).Count)) {
        [void][Windows.Forms.MessageBox]::Show('Pick at least one day, one priority and one folder.', $AppName, 'OK', 'Information'); return
    }
    Save-AdcSettings $Settings
    try {
        $form.Cursor = 'WaitCursor'
        Register-AdcSchedule $Settings -ExePath $AppExePath -ScriptPath $ScriptFile
        $script:SchedInfo = Get-AdcScheduleInfo
        Show-ScheduleInfo
        $form.Cursor = 'Default'
        $msg = if ($s.Enabled) { "Schedule saved. $($lblNext.Text)" } else { 'Schedule turned off.' }
        if ($s.Enabled -and $IsExe -and $AppExePath -notlike "$env:LOCALAPPDATA\Programs\*") {
            $msg += "`n`nTip: the schedule runs this .exe from its current folder. Use Settings > Install to this PC so it keeps working if you move or delete the download."
        }
        [void][Windows.Forms.MessageBox]::Show($msg, $AppName, 'OK', 'Information')
    } catch {
        $form.Cursor = 'Default'
        [void][Windows.Forms.MessageBox]::Show("Could not create the scheduled task:`n$($_.Exception.Message)", $AppName, 'OK', 'Error')
    }
})

$btnRunNow.Add_Click({
    Read-ScheduleForm; Save-AdcSettings $Settings
    Show-Page 'Cleaner'
    Start-BackgroundTask 'Checking' {
        param($UiScale)
        Invoke-AdcScheduledRun -WhatIf -Settings $UiScale -Sync $Sync
    } @(, $Settings) {
        param($s)
        if ($s.Error) { $status.Text = "Failed: $($s.Error)"; return }
        $res = $s.Result; $targets = @($res.Targets)
        $status.Text = "Schedule check: $($targets.Count) apps, $(Format-AdcSize $res.Size) can be cleaned"
        if (-not $targets.Count) { [void][Windows.Forms.MessageBox]::Show('Nothing matches your schedule rules right now. Your PC is clean!', $AppName); return }
        $names = ($targets | Sort-Object CacheSize -Descending | Select-Object -First 12 | ForEach-Object { "   $Dot $($_.Name)  ($(Format-AdcSize $_.CacheSize))" }) -join "`n"
        if ($targets.Count -gt 12) { $names += "`n   ...and $($targets.Count - 12) more" }
        $ans = [Windows.Forms.MessageBox]::Show("Your schedule would clean $(Format-AdcSize $res.Size) of cache from $($targets.Count) apps:`n`n$names`n`nClean them now (cache only)?", 'Run schedule now', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        Start-BackgroundTask 'Cleaning' { param($Rows) Invoke-AdcClean $Rows 'Cache' $Sync } @(, $targets) {
            param($s2)
            $r = $s2.Result
            Add-AdcHistory 'Schedule (manual)' 'Cache only' $r.Cleaned $r.Freed
            [void][Windows.Forms.MessageBox]::Show("Freed $(Format-AdcSize $r.Freed) from $($r.Cleaned) apps.", 'Done', 'OK', 'Information')
            $status.Text = "Freed $(Format-AdcSize $r.Freed)"
        }
    }
})

# =====================================================================
#  PAGE: History
# =====================================================================
$phist = New-Page 'History'
New-PageHeader $phist 'History' 'Every cleanup, manual or scheduled.'
$h1, $valFreed = New-StatCard (GX 0) 100 (GW 3) 'Total cleaned'      $Ico.Total    'Success'
$h2, $valRuns  = New-StatCard (GX 3) 100 (GW 3) 'Cleanups'           $Ico.History  'Accent'
$h3, $valMonth = New-StatCard (GX 6) 100 (GW 3) 'Cleaned this month' $Ico.Broom    'Warning'
$h4, $valLast  = New-StatCard (GX 9) 100 (GW 3) 'Last cleanup'       $Ico.Calendar 'AccentText'
$histCard = New-Card (GX 0) 200 (GW 12) ($PH - 200 - 76)
$histCard.Anchor = 'Top,Bottom,Left,Right'; $histCard.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 8)
$histList = New-Object Windows.Forms.ListView
$histList.View = 'Details'; $histList.FullRowSelect = $true; $histList.Dock = 'Fill'; $histList.BorderStyle = 'None'; $histList.HeaderStyle = 'None'
$histList.SmallImageList = $rowH; Set-DoubleBuffered $histList
$HistColumns = @(
    @{ Text = 'Date'; W = 170; Align = 'Left' }, @{ Text = 'Type'; W = 180; Align = 'Left' }, @{ Text = 'Mode'; W = 150; Align = 'Left' },
    @{ Text = 'Apps'; W = 80; Align = 'Right' }, @{ Text = 'Space freed'; W = 140; Align = 'Right' })
foreach ($col in $HistColumns) { [void]$histList.Columns.Add($col.Text, [int]($col.W * $UiScale), $col.Align) }
$histHeader = New-ListHeader $histList $HistColumns 8 $null
$histCard.Controls.Add($histList)
$histCard.Controls.Add($histHeader)
Update-ListHeader $histHeader
[void](Reg $histList 'list')
$btnClearHist = New-Button 'Clear history' (GX 0) ($PH - 56) 130
$btnClearHist.Anchor = 'Bottom,Left'
$phist.Controls.AddRange(@($h1, $h2, $h3, $h4, $histCard, $btnClearHist))

$script:HistStamp = $null
function Update-HistoryPage([switch]$Force) {
    # Rebuild only when history.json changed (or the theme changed)
    $file = Get-Item -LiteralPath (Join-Path $AdcDataDir 'history.json') -ErrorAction SilentlyContinue
    $stamp = if ($file) { $file.LastWriteTimeUtc.Ticks } else { 0 }
    if (-not $Force -and $stamp -eq $script:HistStamp) { return }
    $script:HistStamp = $stamp
    $h = @(Get-AdcHistory)
    $sum = 0L; $month = 0L; $thisMonth = (Get-Date).ToString('yyyy-MM')
    foreach ($x in $h) { $sum += [int64]$x.Freed; if ("$($x.Date)".StartsWith($thisMonth)) { $month += [int64]$x.Freed } }
    $valFreed.Text = Format-AdcSize $sum
    $valRuns.Text  = '{0:N0}' -f $h.Count
    $valMonth.Text = Format-AdcSize $month
    $valLast.Text  = '-'
    if ($h.Count) { $d = [datetime]::MinValue; $valLast.Text = if ([datetime]::TryParse("$($h[-1].Date)", [ref]$d)) { $d.ToString('dd MMM yyyy') } else { "$($h[-1].Date)" } }
    $histList.BeginUpdate(); $histList.Items.Clear()
    for ($i = $h.Count - 1; $i -ge 0; $i--) {
        $x = $h[$i]
        $it = New-Object Windows.Forms.ListViewItem($x.Date)
        [void]$it.SubItems.Add($x.Type); [void]$it.SubItems.Add($x.Mode)
        [void]$it.SubItems.Add("$($x.Apps)"); [void]$it.SubItems.Add((Format-AdcSize ([int64]$x.Freed)))
        $it.BackColor = $(if (($h.Count - $i) % 2 -eq 0) { $T.Row } else { $T.Card }); $it.ForeColor = $T.Text
        [void]$histList.Items.Add($it)
    }
    $histList.EndUpdate()
}
$btnClearHist.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('Clear the cleanup history?', $AppName, 'YesNo', 'Question') -eq 'Yes') { Clear-AdcHistory; Update-HistoryPage }
})

# =====================================================================
#  PAGE: Settings
# =====================================================================
$pset = New-Page 'Settings'
New-PageHeader $pset 'Settings' 'Appearance, performance, other tools, exclusions and installation.'
$pset.AutoScroll = $true                 # more cards than fit: the page scrolls

$look = New-Card (GX 0) 100 $cardW 88 'Appearance'
$rbSystem = New-Radio 'Use Windows setting' 20 50 ($Settings.Theme -notin @('Light', 'Dark'))
$rbLight  = New-Radio 'Light' 210 50 ($Settings.Theme -eq 'Light')
$rbDark   = New-Radio 'Dark' 300 50 ($Settings.Theme -eq 'Dark')
$look.Controls.AddRange(@($rbSystem, $rbLight, $rbDark))

$perf = New-Card (GX 0) 204 $cardW 180 'Performance while scanning and cleaning'
$rbNormal = New-Radio 'Normal' 20 46 ($Settings.PowerMode -eq 'Normal')
$rbEco    = New-Radio 'Eco  (recommended)' 20 90 ($Settings.PowerMode -eq 'Eco')
$rbSaver  = New-Radio 'Power saver' 20 134 ($Settings.PowerMode -eq 'PowerSaver')
foreach ($r in $rbNormal, $rbEco, $rbSaver) { $r.Font = $F.Bold }
$perf.Controls.AddRange(@($rbNormal, $rbEco, $rbSaver,
    (New-Label 'Fastest. Scans several apps in parallel for a few seconds.' 40 66 $F.Small 'muted'),
    (New-Label 'Low priority, short rests and Windows Efficiency mode. About 60% of one core.' 40 110 $F.Small 'muted'),
    (New-Label 'Lowest CPU and battery use (about a third of one core). Slowest.' 40 154 $F.Small 'muted')))


# ---- Other tools: Windows temp cleaner ----
$tools = New-Card (GX 0) 400 $cardW 204 'Other tools: Windows temp cleaner'
$chkTempSystem = New-Check 'Include system temp  (Windows Temp, Windows Update cache, error reports)  -  asks for administrator' 20 74 $false
$chkTempBoost  = New-Check 'Boost: flush DNS cache, release unused RAM, SSD TRIM  (TRIM needs administrator)' 20 100 $false
$btnTemp = New-Button 'Clean temp files' 20 134 170 'accentBtn'
$lblTemp = New-Label 'Not run yet.' 204 141 $F.Small 'muted'
$tools.Controls.AddRange(@(
    (New-Label 'Cleans Windows temp files, crash dumps, internet and thumbnail caches outside AppData. Downloads is never touched.' 20 48 $F.Small 'muted'),
    $chkTempSystem, $chkTempBoost, $btnTemp, $lblTemp,
    (New-Label 'Command line:  ByteCut.exe --tempclean [--system] [--boost]' 20 176 $F.Small 'muted')))

function Show-TempResult($R) {
    $btnTemp.Enabled = $true
    $cleaned = @($R.Items | Where-Object { [int64]$_.Freed -gt 0 }).Count
    Add-AdcHistory 'Temp cleaner' $(if ($R.System) { 'User + system temp' } else { 'User temp' }) $cleaned ([int64]$R.Freed)
    $lblTemp.Text = "Freed $(Format-AdcSize ([int64]$R.Freed)) on $(Get-Date -Format 'HH:mm')  $Dot  files in use were skipped"
    $lines = foreach ($i in @($R.Items)) {
        $what = if ([int64]$i.Freed -gt 0) { Format-AdcSize ([int64]$i.Freed) } elseif ($i.Note) { $i.Note } else { 'nothing to clean' }
        "   $Dot $($i.Item):  $what"
    }
    [void][Windows.Forms.MessageBox]::Show("Freed $(Format-AdcSize ([int64]$R.Freed)).`n`n$($lines -join "`n")", 'Temp cleaner', 'OK', 'Information')
}

# Elevated run (system temp): a second, elevated ByteCut does the work and writes a JSON result file
$script:TempProc = $null
$tempTimer = New-Object Windows.Forms.Timer
$tempTimer.Interval = 300
$tempTimer.Add_Tick({
    if (-not $script:TempProc.HasExited) { return }
    $tempTimer.Stop(); $script:TempProc = $null
    $file = Join-Path $AdcDataDir 'tempclean-result.json'
    $r = $null; try { $r = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch {}
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if ($r) { Show-TempResult $r } else { $btnTemp.Enabled = $true; $lblTemp.Text = 'The administrator run did not finish.' }
})

$btnTemp.Add_Click({
    if ($script:Job -or $script:TempProc) { return }
    $sys = $chkTempSystem.Checked; $boost = $chkTempBoost.Checked
    if ($sys -and -not (Test-AdcAdmin)) {
        New-Item -ItemType Directory -Force $AdcDataDir | Out-Null
        $file = Join-Path $AdcDataDir 'tempclean-result.json'
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if ($IsExe) { $exe = $AppExePath; $argLine = "--tempclean --system$(if ($boost) { ' --boost' }) --result `"$file`"" }
        else { $exe = 'powershell.exe'; $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptFile`" -TempClean -System$(if ($boost) { ' -Boost' }) -ResultFile `"$file`"" }
        try { $script:TempProc = Start-Process $exe -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop }
        catch { $lblTemp.Text = 'Cancelled: administrator permission was not given.'; return }
        $btnTemp.Enabled = $false; $lblTemp.Text = 'Cleaning with administrator rights...'
        $tempTimer.Start()
        return
    }
    $btnTemp.Enabled = $false; $lblTemp.Text = 'Cleaning...'
    Start-BackgroundTask 'Cleaning temp' {
        param($Sys, $Boost)
        Invoke-AdcTempClean -System:$Sys -Boost:$Boost -Sync $Sync
    } @($sys, $boost) {
        param($s)
        if ($s.Error) { $btnTemp.Enabled = $true; $lblTemp.Text = "Failed: $($s.Error)"; return }
        Show-TempResult $s.Result
    }
})

$exCard = New-Card (GX 0) 620 $cardW 160 'Never clean these apps'

$exList = New-Object Windows.Forms.ListBox
$exList.Location = New-Object Drawing.Point(20, 46); $exList.Size = New-Object Drawing.Size(($cardW - 200), 96)
$exList.BorderStyle = 'FixedSingle'; $exList.IntegralHeight = $false
[void](Reg $exList 'listbox')
$btnExRemove = New-Button 'Remove' ($cardW - 164) 46 144
$exTip = New-Label "Tip: right-click an app on the`nCleaner page > Never clean." ($cardW - 164) 88 $F.Small 'muted'
$exCard.Controls.AddRange(@($exList, $btnExRemove, $exTip))

$appCard = New-Card (GX 0) 796 $cardW 104 'App'
$btnInstall = New-Button 'Install to this PC' 20 50 170 'accentBtn'
$btnData    = New-Button 'Open data folder' 202 50 160
$lblInstall = New-Label $(if ($IsExe) { "Copies ByteCut to your user Programs folder and adds Start Menu and`nDesktop shortcuts. Recommended if you use the schedule." } else { 'Install is available in the .exe version (see the dist folder).' }) 380 52 $F.Small 'muted'
$btnInstall.Enabled = $IsExe
$appCard.Controls.AddRange(@($btnInstall, $btnData, $lblInstall))
$pset.Controls.AddRange(@($look, $perf, $tools, $exCard, $appCard))
foreach ($x in $look, $perf, $tools, $exCard, $appCard) { $x.Anchor = 'Top,Left,Right' }
# bottom margin for the scrolling page
$pset.Controls.Add((New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 924)); Size = (New-Object Drawing.Size(1, 1)) }))
$exList.Anchor = 'Top,Left,Right'; $btnExRemove.Anchor = 'Top,Right'; $exTip.Anchor = 'Top,Right'

foreach ($r in $rbSystem, $rbLight, $rbDark) {
    $r.Add_CheckedChanged({
        if (-not $this.Checked) { return }
        $Settings.Theme = if ($rbLight.Checked) { 'Light' } elseif ($rbDark.Checked) { 'Dark' } else { 'System' }
        Save-AdcSettings $Settings
        Set-Theme $Settings.Theme
    })
}
foreach ($r in $rbNormal, $rbEco, $rbSaver) {
    $r.Add_CheckedChanged({
        if (-not $this.Checked) { return }
        $Settings.PowerMode = if ($rbNormal.Checked) { 'Normal' } elseif ($rbSaver.Checked) { 'PowerSaver' } else { 'Eco' }
        Save-AdcSettings $Settings
    })
}

function Update-ExclusionList {
    $exList.BeginUpdate(); $exList.Items.Clear()
    foreach ($x in @($Settings.Exclusions)) { [void]$exList.Items.Add($x) }
    if (-not $exList.Items.Count) { [void]$exList.Items.Add('(none)') }
    $exList.EndUpdate()
}
$btnExRemove.Add_Click({
    $sel = "$($exList.SelectedItem)"
    if (-not $sel -or $sel -eq '(none)') { return }
    $Settings.Exclusions = @($Settings.Exclusions | Where-Object { $_ -ne $sel })
    Save-AdcSettings $Settings
    foreach ($r in $script:Rows) { if ($r.Path -eq $sel) { Set-AdcPriority $r @($Settings.Exclusions) } }
    Update-ExclusionList; Show-Rows; Update-Stats
})
$btnData.Add_Click({ New-Item -ItemType Directory -Force $AdcDataDir | Out-Null; Start-Process explorer.exe $AdcDataDir })
$btnInstall.Add_Click({
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'Programs\ByteCut'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $target = Join-Path $dir 'ByteCut.exe'
        if ($AppExePath -ne $target) { Copy-Item -LiteralPath $AppExePath -Destination $target -Force -ErrorAction Stop }
        $sh = New-Object -ComObject WScript.Shell
        foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'ByteCut.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ByteCut.lnk'))) {
            $l = $sh.CreateShortcut($lnk); $l.TargetPath = $target; $l.WorkingDirectory = $dir
            $l.Description = "ByteCut by $Developer"; $l.Save()
        }
        if ($Settings.Schedule.Enabled) { Register-AdcSchedule $Settings -ExePath $target }
        [void][Windows.Forms.MessageBox]::Show("Installed to:`n$target`n`nStart Menu and Desktop shortcuts were created.", $AppName, 'OK', 'Information')
    } catch { [void][Windows.Forms.MessageBox]::Show("Install failed: $($_.Exception.Message)", $AppName, 'OK', 'Error') }
})

# =====================================================================
#  PAGE: About
# =====================================================================
$pa = New-Page 'About'
$about = New-Card (GX 0) 32 $cardW 540
$bigLogo = New-Object Windows.Forms.Label
$bigLogo.Location = New-Object Drawing.Point(32, 32); $bigLogo.Size = New-Object Drawing.Size(88, 88); $bigLogo.Image = New-LogoImage ([int](88 * $UiScale))
[void](Reg $bigLogo 'text')
$features = @(
    'Scans Local, Roaming and LocalLow and shows every app with its size, cache size and last-used date',
    'Smart priorities (High / Medium / Low) and sorting by size, cache, priority, last used or name',
    'Cleans only cache / temp / logs by default, so settings and logins are kept',
    'Weekly schedule: notify you, or clean automatically by priority and unused days',
    'Low-CPU Eco and Power saver modes with Windows Efficiency mode',
    'Light and dark theme, Fluent design',
    'Built-in Windows temp cleaner (Settings > Other tools, or ByteCut.exe --tempclean)',
    'Safe by design: never follows junctions, never touches Windows folders or Downloads'
) | ForEach-Object { "$Dot  $_" }
$about.Controls.AddRange(@(
    $bigLogo,
    (New-Label $AppName 140 34 $F.Huge 'text'),
    (New-Label "Version $AppVersion" 143 80 $F.Bold 'text:AccentText'),
    (New-Label "Developed by $Developer" 143 102 $F.Body 'muted'),
    (New-Label 'The AppData cleaner for Windows: free up disk space by clearing the cache, temp and log files apps leave behind.' 34 148 $F.Body 'text'),
    (New-Label 'Features' 34 186 $F.Card 'text'),
    (New-Label ($features -join "`n`n") 34 216 $F.Body 'text'),
    (New-Label "MIT License  $Dot  (c) $((Get-Date).Year) $Developer" 34 508 $F.Small 'muted')
))
if ($RepoUrl) {
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = $RepoUrl; $link.Location = New-Object Drawing.Point(34, 484); $link.AutoSize = $true
    [void](Reg $link 'text')
    $link.Add_LinkClicked({ Start-Process $RepoUrl })
    $about.Controls.Add($link)
}
$about.Anchor = 'Top,Left,Right'
$pa.Controls.Add($about)

# =====================================================================
#  Theme switching (live) + start
# =====================================================================
function Set-WindowChrome {
    $s = $T.Stroke; $colorRef = $s.R -bor ($s.G -shl 8) -bor ($s.B -shl 16)
    [Adc.Ui]::SetWindowChrome($form.Handle, ($T.Mode -eq 'Dark'), $colorRef)
}

function Set-Theme([string]$Name) {
    Set-Palette $Name
    $form.SuspendLayout()
    foreach ($entry in $Themed) { Apply-Role $entry[0] $entry[1] }
    Set-WindowChrome
    if ($script:Rows.Count) { Show-Rows }
    Update-HistoryPage -Force
    Update-ListHeader $histHeader
    Show-ScheduleInfo
    $form.ResumeLayout()
    $form.Refresh()
}

# Top bar first, then each page brought to front: pages fill only the space below the bar
# and never get a temporary full-size layout (which breaks anchors).
$form.Controls.Add($topBar)
foreach ($k in $Pages.Keys) { $Pages[$k].Dock = 'Fill'; $form.Controls.Add($Pages[$k]); $Pages[$k].BringToFront() }

# Everything above is laid out at 96 DPI; scale positions and sizes once for the real display
if ($UiScale -ne 1.0) { $form.Scale((New-Object Drawing.SizeF([float]$UiScale, [float]$UiScale))) }
$form.MinimumSize = $form.Size

$form.Add_HandleCreated({ Set-WindowChrome })
# Right after the window appears, create the window handles of every page once, so the first
# visit to a page is as fast as the second one.
$warmUp = New-Object Windows.Forms.Timer
$warmUp.Interval = 50
$warmUp.Add_Tick({
    $warmUp.Stop()
    $stack = New-Object System.Collections.Stack
    foreach ($k in $Pages.Keys) { $stack.Push($Pages[$k]) }
    while ($stack.Count) { $ctl = $stack.Pop(); [void]$ctl.Handle; foreach ($child in $ctl.Controls) { $stack.Push($child) } }
    Update-HistoryPage
    Start-Quiet { Get-AdcScheduleInfo } { param($info) $script:SchedInfo = $info; Show-ScheduleInfo }
})

$form.Add_Shown({
    $warmUp.Start()
    Set-Cue $txtSearch 'Search apps...'
    Update-SortUi
    $form.ActiveControl = $btnScan
    if ($AutoScan) { Start-Scan }
})
$form.Add_FormClosing({ if ($script:Job) { $script:Job.Sync.Cancel = $true }; if ($script:QuietPool) { $script:QuietPool.Close() } })

Show-Page 'Cleaner'
if ($env:ADC_NO_SHOW) { return }    # used by build\Take-Screenshots.ps1
[void]$form.ShowDialog()
