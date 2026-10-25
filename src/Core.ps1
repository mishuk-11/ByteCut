# =====================================================================
#  ByteCut - Core engine (no UI)
#  Shared by the desktop app, the background scanner, scheduled runs
#  and the stress test.
#  Developer: Inzamam Islam
# =====================================================================
# Keep this file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI.

$AdcCacheNames = @('Cache', 'Cache2', 'CachedData', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
    'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'Temp', 'Tmp', 'Logs', 'Log', 'CrashDumps', 'Crashpad',
    'Crash Reports', 'crashes', 'CacheStorage', 'ScriptCache', 'INetCache', 'D3DSCache')

# Never deleted as a whole folder, never picked by scheduled cleaning
$AdcProtected = @('Microsoft', 'Packages', 'Programs', 'Temp', 'Comms', 'ConnectedDevicesPlatform',
    'PlaceholderTileLogoFolder', 'Publishers', 'VirtualStore', 'Windows', 'ByteCut', 'AppDataCleaner')

$AdcDataDir    = Join-Path $env:APPDATA 'ByteCut'
$AdcTaskName   = 'ByteCut - Scheduled Clean'
# Earlier name: "AppData Cleaner" (up to v3.0)
$AdcLegacyTasks = @('AppData Cleaner - Scheduled Clean')

# Carry settings and history over once from the earlier version
if (-not (Test-Path -LiteralPath $AdcDataDir)) {
    foreach ($old in @('AppDataCleaner')) {
        $legacyDir = Join-Path $env:APPDATA $old
        if (Test-Path -LiteralPath $legacyDir) {
            try { Copy-Item -LiteralPath $legacyDir -Destination $AdcDataDir -Recurse -ErrorAction Stop } catch {}
            break
        }
    }
}
$AdcCacheDepth = 6                                   # how deep to look for cache folders

# ---------------------------------------------------------------------
#  Native helpers (src\Native.cs): fast scanner, Efficiency mode, search placeholder.
#  The .exe has them compiled in; from source they are compiled once with Add-Type.
# ---------------------------------------------------------------------
#  Callers that load this file as text (the app) pass the C# source in $NativeCode.
if (-not ('Adc.Scanner' -as [type])) {
    if (-not $NativeCode) { $NativeCode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Native.cs')) }
    Add-Type -TypeDefinition $NativeCode
}

# ---------------------------------------------------------------------
#  Formatting
# ---------------------------------------------------------------------
function Get-AdcRoots {
    [ordered]@{
        Local    = $env:LOCALAPPDATA
        Roaming  = $env:APPDATA
        LocalLow = Join-Path (Split-Path $env:LOCALAPPDATA) 'LocalLow'
    }
}

function Format-AdcSize([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-AdcAge($Date) {
    if (-not $Date) { return 'Never' }
    $days = [int][math]::Floor(((Get-Date) - $Date).TotalDays)
    if ($days -lt 1)   { return 'Today' }
    if ($days -lt 2)   { return 'Yesterday' }
    if ($days -lt 30)  { return "$days days ago" }
    if ($days -lt 365) { $m = [int][math]::Floor($days / 30); return $(if ($m -eq 1) { '1 month ago' } else { "$m months ago" }) }
    return '{0:N1} years ago' -f ($days / 365)
}

# ---------------------------------------------------------------------
#  Power modes
#   Normal     : full speed, up to 8 threads sharing one queue of folders
#   Eco        : below-normal priority, rests 1/3 of the time (~66% of one core), Efficiency mode
#   PowerSaver : lowest priority, rests 2/3 of the time (~33% of one core), Efficiency mode
# ---------------------------------------------------------------------
# Efficiency mode (EcoQoS). Process-wide only when there is no window (scheduled runs):
# process-wide EcoQoS makes Windows draw the app's text without ClearType after a few seconds.
# With a window, only the calling (background scan) thread gets EcoQoS.
function Set-AdcEfficiencyMode([bool]$On, [switch]$WholeProcess) {
    try {
        if ($WholeProcess) { [void][Adc.Native]::SetEfficiencyMode($On) }
        else { [void][Adc.Native]::SetThreadEfficiencyMode($On) }
    } catch {}
}

function Set-AdcPowerMode([string]$Mode, [switch]$WholeProcess) {
    switch ($Mode) {
        'PowerSaver' { $work = 15; $rest = 30; $threads = 1; $tp = 'Lowest';      $pp = 'Idle';        $eco = $true }
        'Eco'        { $work = 30; $rest = 15; $threads = 1; $tp = 'BelowNormal'; $pp = 'BelowNormal'; $eco = $true }
        default      { $work = 0;  $rest = 0;  $threads = [math]::Min(8, [Environment]::ProcessorCount); $tp = 'Normal'; $pp = 'Normal'; $eco = $false }
    }
    [Adc.Scanner]::WorkMs = $work; [Adc.Scanner]::SleepMs = $rest; [Adc.Scanner]::Threads = $threads
    try { [Threading.Thread]::CurrentThread.Priority = $tp } catch {}
    if ($WholeProcess) { try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = $pp } catch {} }
    Set-AdcEfficiencyMode $eco -WholeProcess:$WholeProcess
}

function Wait-AdcThrottle { [Adc.Scanner]::Throttle() }

# ---------------------------------------------------------------------
#  Scanning
# ---------------------------------------------------------------------
# Turns the C# scan result (Adc.FolderStats, see Native.cs) into a row for the app.
function New-AdcRow($Stats, [string]$Path, [string]$RootName = '') {
    $lastUsed = if ($Stats.Files) { $Stats.NewestUtc.ToLocalTime() } else { $null }
    [pscustomobject]@{
        Name          = Split-Path $Path -Leaf
        Root          = $RootName
        Path          = $Path
        Size          = $Stats.Size
        CacheSize     = $Stats.CacheSize
        Files         = $Stats.Files
        CacheDirs     = $Stats.CacheDirs
        LastUsed      = $lastUsed
        LastUsedTicks = $(if ($lastUsed) { $lastUsed.Ticks } else { 0L })
        DaysUnused    = $(if ($lastUsed) { [int][math]::Floor(((Get-Date) - $lastUsed).TotalDays) } else { 99999 })
        PriorityRank  = 0
        Priority      = 'None'
    }
}

# One app folder: total size, cache size, cache folders and newest file. Never follows junctions.
function Measure-AdcFolder([string]$Path, [string]$RootName = '') {
    New-AdcRow ([Adc.Scanner]::Measure($Path, $AdcCacheNames, $AdcCacheDepth)) $Path $RootName
}

# Cleanup priority = how much an app is worth cleaning
function Set-AdcPriority($Row, [string[]]$Exclusions = @()) {
    if ($Exclusions -contains $Row.Path)        { $rank = -2; $label = 'Excluded' }
    elseif ($AdcProtected -contains $Row.Name)  { $rank = -1; $label = 'Protected' }
    elseif ($Row.CacheSize -ge 100MB)           { $rank = 3;  $label = 'High' }
    elseif ($Row.CacheSize -ge 10MB)            { $rank = 2;  $label = 'Medium' }
    elseif ($Row.CacheSize -gt 0)               { $rank = 1;  $label = 'Low' }
    else                                        { $rank = 0;  $label = 'None' }
    $Row.PriorityRank = $rank
    $Row.Priority = $label
}

# $Paths (name -> folder) lets tests scan any folder; otherwise the real AppData roots are used.
function Invoke-AdcScan {
    param([string[]]$RootNames = @('Local'), [System.Collections.IDictionary]$Paths, [string[]]$Exclusions = @(), $Sync)
    if (-not $Paths) {
        $all = Get-AdcRoots; $Paths = [ordered]@{}
        foreach ($n in $RootNames) { if ($all.Contains($n)) { $Paths[$n] = $all[$n] } }
    }
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($n in $Paths.Keys) {
        foreach ($d in (Get-ChildItem -LiteralPath $Paths[$n] -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $jobs.Add(@($n, $d.FullName)) }
        }
    }
    if ($Sync) { $Sync.Total = $jobs.Count; $Sync.Done = 0 }
    if (-not $jobs.Count) { return @() }
    # The heavy lifting runs in C# (in parallel in Normal mode); it updates $Sync.Done itself
    $stats = [Adc.Scanner]::MeasureMany([string[]]@($jobs | ForEach-Object { $_[1] }), $AdcCacheNames, $AdcCacheDepth, $Sync)
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        if (-not $stats[$i]) { continue }                     # not scanned (cancelled)
        $row = New-AdcRow $stats[$i] $jobs[$i][1] $jobs[$i][0]
        Set-AdcPriority $row $Exclusions
        $rows.Add($row)
    }
    return $rows.ToArray()
}

# Which apps a scheduled run should clean
function Select-AdcTargets($Rows, [string[]]$Priorities, [bool]$UnusedOnly = $false, [int]$UnusedDays = 30) {
    return @($Rows | Where-Object {
        $_.PriorityRank -gt 0 -and $Priorities -contains $_.Priority -and
        (-not $UnusedOnly -or $_.DaysUnused -ge $UnusedDays)
    })
}

# ---------------------------------------------------------------------
#  Deleting
# ---------------------------------------------------------------------
# Only paths strictly inside an AppData root may ever be deleted.
function Test-AdcSafePath([string]$Path) {
    if (-not $Path -or $Path -match '\\Downloads(\\|$)') { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($r in (Get-AdcRoots).Values) {
        $root = [IO.Path]::GetFullPath($r).TrimEnd('\')
        if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Deletes a folder tree without ever following junctions/symlinks (links are removed, never their targets).
# Files in use are skipped. Returns the number of bytes deleted.
function Remove-AdcTree([string]$Path, [switch]$KeepRoot) {
    if (-not (Test-AdcSafePath $Path)) { return 0L }
    return (Remove-AdcTreeCore $Path -KeepRoot:$KeepRoot)
}

# The actual tree remover (no path guard). Callers must check the path first:
# Remove-AdcTree (AppData only) and Clear-AdcTempFolder (fixed temp folder list only).
function Remove-AdcTreeCore([string]$Path, [switch]$KeepRoot) {
    $root = New-Object IO.DirectoryInfo $Path
    if (-not $root.Exists) { return 0L }
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if (-not $KeepRoot) { try { $root.Delete() } catch {} }
        return 0L
    }
    $freed = 0L
    $dirs = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop(); $dirs.Add($d)
        try {
            foreach ($f in $d.GetFiles()) {
                try {
                    if ($f.Attributes -band [IO.FileAttributes]::ReadOnly) { $f.Attributes = 'Normal' }
                    $len = $f.Length; $f.Delete(); $freed += $len
                } catch {}
            }
            foreach ($s in $d.GetDirectories()) {
                if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { try { $s.Delete() } catch {} }   # link only
                else { $stack.Push($s) }
            }
        } catch {}
        Wait-AdcThrottle
    }
    # Children were listed after their parents, so delete in reverse order
    for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
        if ($KeepRoot -and $i -eq 0) { continue }
        try { $dirs[$i].Delete() } catch {}
    }
    return $freed
}

function Invoke-AdcClean {
    param($Rows, [ValidateSet('Cache', 'Entire')][string]$Mode = 'Cache', $Sync)
    $Rows = @($Rows)
    $freed = 0L; $cleaned = 0; $skipped = New-Object System.Collections.Generic.List[string]
    if ($Sync) { $Sync.Total = $Rows.Count; $Sync.Done = 0 }
    foreach ($r in $Rows) {
        if ($Sync) { if ($Sync.Cancel) { break }; $Sync.Current = $r.Path }
        if ($r.PriorityRank -eq -2) { $skipped.Add($r.Name) }                          # excluded by user
        elseif ($Mode -eq 'Entire') {
            if ($AdcProtected -contains $r.Name) { $skipped.Add($r.Name) }             # Windows needs it
            else { $freed += Remove-AdcTree $r.Path; $cleaned++ }
        } else {
            foreach ($c in @($r.CacheDirs)) { $freed += Remove-AdcTree $c -KeepRoot }  # keep the folder, empty it
            $cleaned++
        }
        if ($Sync) { $Sync.Done++ }
    }
    [pscustomobject]@{ Freed = $freed; Cleaned = $cleaned; Skipped = $skipped.ToArray() }
}

# ---------------------------------------------------------------------
#  Windows temp cleaner (Settings > Other tools, or ByteCut.exe --tempclean)
#  Cleans a FIXED list of Windows temp/cache folders outside AppData. Downloads is never touched.
# ---------------------------------------------------------------------
function Test-AdcAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AdcTempTargets {
    @(
        [pscustomobject]@{ Name = 'User temp';               Path = $env:TEMP;                                              Admin = $false; Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Crash dumps';             Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps');             Admin = $false; Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Internet cache';          Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache'); Admin = $false; Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Thumbnail cache';         Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Admin = $false; Kind = 'Thumbs' }
        [pscustomobject]@{ Name = 'Windows temp';            Path = (Join-Path $env:SystemRoot 'Temp');                     Admin = $true;  Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Error reports (archive)'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Admin = $true; Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Error reports (queue)';   Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue');   Admin = $true; Kind = 'Folder' }
        [pscustomobject]@{ Name = 'Windows Update cache';    Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); Admin = $true; Kind = 'WindowsUpdate' }
        [pscustomobject]@{ Name = 'Delivery Optimization';   Path = '';                                                     Admin = $true;  Kind = 'DeliveryOptimization' }
    )
}

# Empties one folder from the fixed temp list (the folder itself stays). Files in use are skipped.
function Clear-AdcTempFolder([string]$Path, [string[]]$Allowed) {
    if (-not $Path -or $Path -match '\\Downloads(\\|$)') { return 0L }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not ($Allowed | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') -ieq $full })) { return 0L }   # only listed folders
    if (-not (Test-Path -LiteralPath $full)) { return 0L }
    return (Remove-AdcTreeCore $full -KeepRoot)
}

# $Targets lets tests point the cleaner at fake folders.
function Invoke-AdcTempClean([switch]$System, [switch]$Boost, $Targets, $Sync) {
    $isAdmin = Test-AdcAdmin
    if (-not $Targets) { $Targets = Get-AdcTempTargets }
    $Targets = @($Targets | Where-Object { $System -or -not $_.Admin })
    $allowed = @($Targets | Where-Object { $_.Path } | ForEach-Object { $_.Path })
    $items = New-Object System.Collections.Generic.List[object]
    if ($Sync) { $Sync.Total = $Targets.Count + $(if ($Boost) { 3 } else { 0 }); $Sync.Done = 0 }
    foreach ($t in $Targets) {
        if ($Sync) { if ($Sync.Cancel) { break }; $Sync.Current = $t.Name }
        $freed = 0L; $note = ''
        if ($t.Admin -and -not $isAdmin) { $note = 'needs administrator' }
        else {
            switch ($t.Kind) {
                'Folder' { $freed = Clear-AdcTempFolder $t.Path $allowed }
                'Thumbs' {
                    foreach ($f in @(Get-ChildItem -LiteralPath $t.Path -Filter 'thumbcache_*.db' -Force -File -ErrorAction SilentlyContinue)) {
                        try { $len = $f.Length; $f.Delete(); $freed += $len } catch {}      # files in use by Explorer stay
                    }
                }
                'WindowsUpdate' {
                    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
                    $freed = Clear-AdcTempFolder $t.Path $allowed
                    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
                }
                'DeliveryOptimization' {
                    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue; $note = 'cleared' }
                    else { $note = 'not available' }
                }
            }
        }
        $items.Add([pscustomobject]@{ Item = $t.Name; Freed = [int64]$freed; Note = $note })
        if ($Sync) { $Sync.Done++ }
    }
    if ($Boost) {
        ipconfig /flushdns | Out-Null
        $items.Add([pscustomobject]@{ Item = 'DNS cache'; Freed = 0L; Note = 'flushed' }); if ($Sync) { $Sync.Done++ }
        $n = [Adc.Native]::TrimWorkingSets()
        $items.Add([pscustomobject]@{ Item = 'Unused RAM'; Freed = 0L; Note = "released from $n processes" }); if ($Sync) { $Sync.Done++ }
        $trim = 'needs administrator'
        if ($isAdmin) {
            $trim = 'skipped (not an SSD)'
            try {
                $disk = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
                if ((Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$disk" }).MediaType -eq 'SSD') { Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop; $trim = 'done on C:' }
            } catch { $trim = 'not available' }
        }
        $items.Add([pscustomobject]@{ Item = 'SSD TRIM'; Freed = 0L; Note = $trim }); if ($Sync) { $Sync.Done++ }
    }
    $total = 0L; foreach ($i in $items) { $total += $i.Freed }
    [pscustomobject]@{ Freed = $total; Items = $items.ToArray(); Admin = $isAdmin; System = [bool]$System; Boost = [bool]$Boost }
}

# ---------------------------------------------------------------------
#  Settings and history  (%APPDATA%\ByteCut)
# ---------------------------------------------------------------------
function Get-AdcDefaultSettings {
    [pscustomobject]@{
        PowerMode  = 'Eco'
        Exclusions = @()
        LastRoot   = 'Local'
        SortKey    = 'Size'
        SortDesc   = $true
        Theme      = 'System'           # System | Light | Dark
        Schedule   = [pscustomobject]@{
            Enabled    = $false
            Days       = @('Sunday')
            Time       = '20:00'
            Action     = 'Notify'          # Notify | Clean
            Priorities = @('High', 'Medium')
            UnusedOnly = $false
            UnusedDays = 30
            Roots      = @('Local', 'Roaming', 'LocalLow')
            OnlyOnAC   = $true
            OnlyIdle   = $false
        }
    }
}

function Get-AdcSettings {
    $d = Get-AdcDefaultSettings
    $file = Join-Path $AdcDataDir 'settings.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $s = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            foreach ($p in $d.PSObject.Properties.Name) {
                if ($p -ne 'Schedule' -and $null -ne $s.$p) { $d.$p = $s.$p }
            }
            if ($s.Schedule) {
                foreach ($p in $d.Schedule.PSObject.Properties.Name) {
                    if ($null -ne $s.Schedule.$p) { $d.Schedule.$p = $s.Schedule.$p }
                }
            }
        } catch {}
    }
    $d.Exclusions          = @($d.Exclusions | Where-Object { $_ })
    $d.Schedule.Days       = @($d.Schedule.Days)
    $d.Schedule.Priorities = @($d.Schedule.Priorities)
    $d.Schedule.Roots      = @($d.Schedule.Roots)
    return $d
}

function Save-AdcSettings($Settings) {
    New-Item -ItemType Directory -Force -Path $AdcDataDir | Out-Null
    ConvertTo-Json -InputObject $Settings -Depth 5 | Set-Content -LiteralPath (Join-Path $AdcDataDir 'settings.json') -Encoding UTF8
}

function Get-AdcHistory {
    $file = Join-Path $AdcDataDir 'history.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try { $h = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json; return @($h) } catch { return @() }
}

function Add-AdcHistory([string]$Type, [string]$Mode, [int]$Apps, [int64]$Freed) {
    $h = @(Get-AdcHistory) + [pscustomobject]@{
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Type = $Type; Mode = $Mode; Apps = $Apps; Freed = $Freed
    }
    if ($h.Count -gt 500) { $h = $h[($h.Count - 500)..($h.Count - 1)] }
    New-Item -ItemType Directory -Force -Path $AdcDataDir | Out-Null
    ConvertTo-Json -InputObject @($h) -Depth 3 | Set-Content -LiteralPath (Join-Path $AdcDataDir 'history.json') -Encoding UTF8
}

function Clear-AdcHistory { Remove-Item -LiteralPath (Join-Path $AdcDataDir 'history.json') -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------
#  Weekly schedule (Windows Task Scheduler, current user, no admin)
# ---------------------------------------------------------------------
function Register-AdcSchedule($Settings, [string]$ExePath, [string]$ScriptPath, [string]$TaskName = $AdcTaskName) {
    $sc = $Settings.Schedule
    if (-not $sc.Enabled -or -not @($sc.Days).Count) { Unregister-AdcSchedule $TaskName; foreach ($lt in $AdcLegacyTasks) { Unregister-AdcSchedule $lt }; return }
    if ($ExePath) {
        $action = New-ScheduledTaskAction -Execute $ExePath -Argument '--scheduled'
    } else {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
            '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Scheduled' -f $ScriptPath)
    }
    $at = [datetime]::ParseExact($sc.Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek @($sc.Days) -At $at
    $opts = @{ StartWhenAvailable = $true; ExecutionTimeLimit = (New-TimeSpan -Hours 2); MultipleInstances = 'IgnoreNew' }
    if (-not $sc.OnlyOnAC) { $opts.AllowStartIfOnBatteries = $true; $opts.DontStopIfGoingOnBatteries = $true }
    if ($sc.OnlyIdle) { $opts.RunOnlyIfIdle = $true; $opts.IdleDuration = (New-TimeSpan -Minutes 5); $opts.IdleWaitTimeout = (New-TimeSpan -Hours 4) }
    $set = New-ScheduledTaskSettingsSet @opts
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    if ($TaskName -eq $AdcTaskName) { foreach ($lt in $AdcLegacyTasks) { Unregister-AdcSchedule $lt } }   # replace older tasks
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set -Principal $principal `
        -Description 'ByteCut by Inzamam Islam - weekly cache check' -Force -ErrorAction Stop | Out-Null
}

function Unregister-AdcSchedule([string]$TaskName = $AdcTaskName) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-AdcScheduleInfo([string]$TaskName = $AdcTaskName) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    [pscustomobject]@{ NextRun = $i.NextRunTime; LastRun = $i.LastRunTime; State = "$($t.State)" }
}

# What a scheduled run does. Automatic cleaning is ALWAYS cache-only (never whole folders).
function Invoke-AdcScheduledRun([switch]$WhatIf, [System.Collections.IDictionary]$Paths, $Settings, $Sync) {
    if (-not $Settings) { $Settings = Get-AdcSettings }
    $sc = $Settings.Schedule
    $rows = @(Invoke-AdcScan -RootNames @($sc.Roots) -Paths $Paths -Exclusions @($Settings.Exclusions) -Sync $Sync)
    $targets = Select-AdcTargets $rows @($sc.Priorities) ([bool]$sc.UnusedOnly) ([int]$sc.UnusedDays)
    $size = 0L; foreach ($t in $targets) { $size += $t.CacheSize }
    $result = [pscustomobject]@{ Action = $sc.Action; Scanned = $rows.Count; Targets = $targets; Size = $size; Freed = 0L; Cleaned = 0 }
    if ($sc.Action -eq 'Clean' -and -not $WhatIf -and $targets.Count) {
        $r = Invoke-AdcClean $targets 'Cache' $Sync
        $result.Freed = $r.Freed; $result.Cleaned = $r.Cleaned
        Add-AdcHistory 'Scheduled' 'Cache only' $r.Cleaned $r.Freed
    }
    return $result
}
