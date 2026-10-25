<#
.SYNOPSIS
    Opens the app, visits every page and saves a PNG of each one.

.DESCRIPTION
    -Demo (default) : fills the app with made-up demo data (no disk scan, no real paths or
                      user names) - used for the screenshots in docs\screenshots.
    -Real           : runs a real (read-only) scan of the Local folder - used to check that
                      the whole app works end to end. Errors are written to errors.log.
    Nothing is ever deleted by this script.
#>
param(
    [switch]$Real,
    [ValidateSet('Light', 'Dark')][string]$Theme = 'Light',
    [string]$Suffix = '',
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'docs\screenshots')
)

$repo = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force $OutDir | Out-Null
$CoreCode = [IO.File]::ReadAllText((Join-Path $repo 'src\Core.ps1'))

if (-not $Real) {
    # Demo mode: private settings/history folder + a fake schedule
    $demoData = Join-Path $env:TEMP 'ADC-Demo-Data'
    if (Test-Path $demoData) { Remove-Item $demoData -Recurse -Force }
    $CoreCode += @"

`$AdcDataDir = '$demoData'
function Get-AdcScheduleInfo { [pscustomobject]@{ NextRun = (Get-Date).Date.AddDays(1).AddHours(20); LastRun = (Get-Date).Date.AddDays(-3).AddHours(20); State = 'Ready' } }
"@
    # Demo settings are written before the app loads, so every page shows them
    New-Item -ItemType Directory -Force $demoData | Out-Null
    @{
        PowerMode = 'Eco'; Theme = $Theme; LastRoot = 'All folders'; SortKey = 'Size'; SortDesc = $true
        Exclusions = @('C:\Users\Alex\AppData\Roaming\Telegram Desktop')
        Schedule = @{ Enabled = $true; Days = @('Monday', 'Thursday'); Time = '20:00'; Action = 'Clean'; Priorities = @('High', 'Medium')
                      UnusedOnly = $false; UnusedDays = 30; Roots = @('Local', 'Roaming', 'LocalLow'); OnlyOnAC = $true; OnlyIdle = $true }
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $demoData 'settings.json') -Encoding UTF8
}

$env:ADC_NO_SHOW = '1'
. (Join-Path $repo 'src\ByteCut.ps1')
$env:ADC_NO_SHOW = $null

if (-not $Real) {

    $now = Get-Date
    @(  @(-21, 'Scheduled', 'Cache only', 14, 2.1GB), @(-14, 'Manual', 'Cache only', 6, 812MB), @(-10, 'Scheduled', 'Cache only', 11, 1.4GB),
        @(-7, 'Manual', 'Entire folder', 3, 3.2GB), @(-3, 'Scheduled', 'Cache only', 9, 966MB) ) | ForEach-Object {
        Add-AdcHistory $_[1] $_[2] $_[3] $_[4]
    }
    $h = @(Get-AdcHistory); for ($i = 0; $i -lt $h.Count; $i++) { $h[$i].Date = $now.AddDays(@(-21, -14, -10, -7, -3)[$i]).ToString('yyyy-MM-dd 20:00') }
    ConvertTo-Json -InputObject $h | Set-Content (Join-Path $AdcDataDir 'history.json') -Encoding UTF8
}

if (-not ('Shot.Win' -as [type])) {
    Add-Type -Namespace Shot -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);'
}

# PrintWindow asks the window to draw itself, so display scaling does not matter
function Save-Shot([string]$Name) {
    $form.Refresh()
    for ($i = 0; $i -lt 6; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][Shot.Win]::PrintWindow($form.Handle, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $bmp.Save((Join-Path $OutDir "$Name$Suffix.png"), [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function New-DemoRows {
    $base = 'C:\Users\Alex\AppData'
    $data = @(
        @('Google', 'Local', 9560, 498, 0), @('Spotify', 'Local', 2310, 1650, 2), @('Discord', 'Roaming', 1210, 412, 1),
        @('Code', 'Roaming', 3150, 198, 0), @('Microsoft', 'Local', 2310, 38, 0), @('CapCut', 'Local', 2270, 439, 12),
        @('Slack', 'Roaming', 980, 220, 3), @('Zoom', 'Roaming', 946, 41, 20), @('Steam', 'Local', 294, 224, 5),
        @('Adobe', 'Roaming', 642, 27, 45), @('Packages', 'Local', 1540, 75, 0), @('NVIDIA', 'Local', 410, 360, 1),
        @('pip', 'Local', 125, 125, 60), @('Postman', 'Roaming', 520, 88, 130), @('JetBrains', 'Local', 1830, 310, 9),
        @('Unity', 'LocalLow', 210, 150, 240), @('Figma', 'Roaming', 330, 95, 14), @('Telegram Desktop', 'Roaming', 860, 54, 2),
        @('OldGame Studio', 'LocalLow', 1200, 0, 420), @('Arduino15', 'Local', 385, 0, 300), @('obs-studio', 'Roaming', 120, 35, 50),
        @('WhatsApp', 'Local', 1450, 12, 0), @('Programs', 'Local', 4060, 0, 0), @('Notion', 'Roaming', 690, 260, 4),
        @('Blender Foundation', 'Roaming', 75, 6, 95), @('Mozilla', 'Local', 1120, 840, 1)
    )
    foreach ($d in $data) {
        $last = (Get-Date).AddDays(-$d[4]).AddHours(-2)
        $row = [pscustomobject]@{
            Name = $d[0]; Root = $d[1]; Path = "$base\$($d[1])\$($d[0])"; Size = [int64]$d[2] * 1MB; CacheSize = [int64]$d[3] * 1MB
            Files = 100; CacheDirs = @(); LastUsed = $last; LastUsedTicks = $last.Ticks; DaysUnused = $d[4]
            PriorityRank = 0; Priority = 'None'; Checked = $false
        }
        Set-AdcPriority $row @($Settings.Exclusions)
        $row
    }
}

$form.TopMost = $true
$form.Add_Shown({
    $form.Activate()
    if ($Real) {
        $cbRoot.SelectedItem = 'Local'
        Start-Scan
        while ($script:Job) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    } else {
        $cbRoot.SelectedItem = 'All folders'
        $script:Rows = @(New-DemoRows)
        foreach ($r in $script:Rows) { if ($r.Priority -eq 'High') { $r.Checked = $true } }
        $script:SortKey = 'Size'; $script:SortDesc = $true
        Show-Rows; Update-Stats
        $status.Text = 'Scan complete: 26 app folders in 3.8s  (Eco mode)'
    }
    Save-Shot '1-cleaner'
    $script:SortKey = 'Priority'; $script:SortDesc = $true; Show-Rows; Save-Shot '2-cleaner-priority'
    $script:SortKey = 'LastUsed'; $script:SortDesc = $false; Show-Rows; Save-Shot '3-cleaner-last-used'
    Show-Page 'Schedule'; Save-Shot '4-schedule'
    Show-Page 'History'
    $w = [Diagnostics.Stopwatch]::StartNew(); while ($w.ElapsedMilliseconds -lt 2600) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 }   # let the odometer roll
    Save-Shot '5-history'
    Show-Page 'Settings'; Save-Shot '6-settings'
    Show-Page 'About';    Save-Shot '7-about'
    if ($Real) { ($Error | ForEach-Object { "$_  @ $($_.InvocationInfo.PositionMessage)" }) | Set-Content (Join-Path $OutDir 'errors.log') }
    $form.Close()
})
$Error.Clear()
[void]$form.ShowDialog()
if (-not $Real) { Remove-Item $demoData -Recurse -Force -ErrorAction SilentlyContinue }
