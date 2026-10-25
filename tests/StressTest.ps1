<#
.SYNOPSIS
    Stress + safety test for the ByteCut engine (src\Core.ps1).

.DESCRIPTION
    1. Builds a fake AppData folder with hundreds of apps, thousands of files, cache folders at
       different depths, big cache files, read-only files, old "unused" apps, a protected
       "Microsoft" folder and junction traps that point OUTSIDE the scanned folder.
    2. Benchmarks a full scan in each power mode (Normal / Eco / PowerSaver): time, CPU, memory.
    3. Checks that every size, cache size, priority and "unused" value is exactly right.
    4. Cleans (cache-only and entire-folder) and checks that only the right files disappeared:
       non-cache files survive, junction targets survive, protected/excluded apps are refused.
    5. Runs the Windows temp cleaner on fake folders (junction trap, a "Downloads" folder, unlisted folder).
    6. Optionally registers + removes a test scheduled task (-TestScheduler).

    Everything happens inside a temp folder that is deleted afterwards. Your real AppData is never touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\StressTest.ps1
    powershell -ExecutionPolicy Bypass -File tests\StressTest.ps1 -Apps 800 -TestScheduler
#>
param(
    [ValidateRange(12, 5000)][int]$Apps = 300,       # at least 12: the special cases use App_0001..App_0010
    [string]$WorkDir = (Join-Path $env:TEMP 'ADC-StressTest'),
    [switch]$TestScheduler,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
. (Join-Path $repo 'src\Core.ps1')

$root    = Join-Path $WorkDir 'AppData'     # the folder we scan
$victim  = Join-Path $WorkDir 'Victim'      # junctions point here - must NEVER be deleted
$results = New-Object System.Collections.Generic.List[object]
$rand    = New-Object Random 42
$old     = (Get-Date).AddDays(-200)

function Add-Result([string]$Name, [bool]$Pass, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Test = $Name; Pass = $Pass; Detail = $Detail })
    $tag = if ($Pass) { '[PASS]' } else { '[FAIL]' }
    $col = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  {0} {1}  {2}" -f $tag, $Name, $Detail) -ForegroundColor $col
}

function New-TestFile([string]$Path, [int64]$Size, $Time) {
    $fs = [IO.File]::Create($Path)
    if ($Size -gt 0) { $fs.SetLength($Size) }
    $fs.Close()
    if ($Time) { [IO.File]::SetLastWriteTime($Path, $Time) }
}

function Get-TreeStats([string]$Path) {
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
    $sum = 0L; foreach ($f in $files) { $sum += $f.Length }
    [pscustomobject]@{ Count = $files.Count; Bytes = $sum }
}

# ---------------------------------------------------------------------
Write-Host "`n=== ByteCut stress test ===" -ForegroundColor Cyan
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($env:TEMP))      # .NET, not WMI (WMI can hang)
$need = [math]::Max(100MB, $Apps * 10MB)
if ($drive.AvailableFreeSpace -lt $need) { throw ("Need at least {0:N0} MB free on {1} for the test data." -f ($need / 1MB), $drive.Name) }
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force $root, $victim | Out-Null

# ---------------------------------------------------------------------
Write-Host "`n[1] Generating $Apps fake apps..." -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()

# Victim folder (outside the scanned root)
1..50 | ForEach-Object { New-TestFile (Join-Path $victim "precious_$_.dat") 4096 $null }
$victimBefore = Get-TreeStats $victim

$expected = @{}
$cacheNamesPool = @('Cache', 'Code Cache', 'GPUCache', 'Temp', 'Logs', 'Crashpad', 'ShaderCache', 'CacheStorage')
$specialNames = @('App With Spaces & (Symbols)', ('Caf' + [char]0x00E9 + ' Unicode ' + [char]0x00DC + 'ber'))

for ($i = 1; $i -le $Apps; $i++) {
    $name = if ($i -le $specialNames.Count) { $specialNames[$i - 1] } else { 'App_{0:D4}' -f $i }
    $app = Join-Path $root $name
    New-Item -ItemType Directory -Force $app | Out-Null

    $unused = ($i % 7 -eq 0)
    $time = if ($unused) { $old } else { $null }
    $category = if ($i % 75 -eq 0) { 'High' } elseif ($i % 10 -eq 0) { 'Medium' } elseif ($i % 3 -eq 0) { 'None' } else { 'Low' }
    $size = 0L; $cache = 0L

    # Normal (non-cache) data: settings, profiles, saves
    for ($d = 0; $d -lt $rand.Next(2, 5); $d++) {
        $dir = $app
        for ($lvl = 0; $lvl -lt $rand.Next(1, 5); $lvl++) { $dir = Join-Path $dir "data$d-$lvl" }
        New-Item -ItemType Directory -Force $dir | Out-Null
        for ($f = 0; $f -lt $rand.Next(5, 30); $f++) {
            $len = [int64]$rand.Next(1024, 200KB)
            New-TestFile (Join-Path $dir "file$f.bin") $len $time; $size += $len
        }
    }

    # Cache data
    if ($category -ne 'None') {
        $cdir = $app
        for ($lvl = 0; $lvl -lt $rand.Next(0, 3); $lvl++) { $cdir = Join-Path $cdir "Profile$lvl" }
        $cdir = Join-Path $cdir $cacheNamesPool[$rand.Next($cacheNamesPool.Count)]
        $sub = Join-Path $cdir 'Cache_Data'
        New-Item -ItemType Directory -Force $sub | Out-Null
        $target = switch ($category) { 'High' { 105MB + $rand.Next(0, 40MB) } 'Medium' { 11MB + $rand.Next(0, 50MB) } default { [int64]$rand.Next(4KB, 5MB) } }
        $written = 0L; $n = 0
        while ($written -lt $target) {
            $len = [int64][math]::Min($target - $written, $(if ($category -eq 'Low') { $rand.Next(1KB, 512KB) } else { $rand.Next(1MB, 30MB) }))
            $where = if ($n % 2) { $sub } else { $cdir }
            New-TestFile (Join-Path $where "f_$n") $len $time
            $written += $len; $n++
        }
        $size += $written; $cache += $written
    }

    $expected[$name] = @{ Size = $size; Cache = $cache; Category = $category; Unused = $unused }
}

# --- Special cases ---
# Read-only file inside a cache
$roApp = 'App_0004'; $roFile = Join-Path $root "$roApp\Cache\readonly.bin"
New-Item -ItemType Directory -Force (Split-Path $roFile) | Out-Null
New-TestFile $roFile 8192 $null; (Get-Item $roFile).IsReadOnly = $true
$expected[$roApp].Size += 8192; $expected[$roApp].Cache += 8192
if ($expected[$roApp].Category -eq 'None') { $expected[$roApp].Category = 'Low' }

# "Cache" folder deeper than the detection limit (level 8) -> counted as normal data, never deleted
$deepApp = 'App_0005'; $deepDir = Join-Path $root "$deepApp\a\b\c\d\e\f\g\Cache"
New-Item -ItemType Directory -Force $deepDir | Out-Null
New-TestFile (Join-Path $deepDir 'deep.bin') 10000 $null
$expected[$deepApp].Size += 10000

# Junction traps: inside a cache folder, inside normal data, and at root level
New-Item -ItemType Directory -Force "$root\App_0010\Cache" | Out-Null
cmd /c mklink /J "$root\App_0010\Cache\linked_victim" "$victim" | Out-Null
New-Item -ItemType Directory -Force "$root\App_0008" | Out-Null
cmd /c mklink /J "$root\App_0008\link_out" "$victim" | Out-Null
cmd /c mklink /J "$root\JunctionApp" "$victim" | Out-Null

# Protected folder with lots of cache
$ms = Join-Path $root 'Microsoft\Edge\Cache'
New-Item -ItemType Directory -Force $ms | Out-Null
New-TestFile (Join-Path $ms 'big.bin') 20MB $null
$expected['Microsoft'] = @{ Size = 20MB; Cache = 20MB; Category = 'Protected'; Unused = $false }

$genStats = Get-TreeStats $root
$sw.Stop()
Write-Host ("    {0:N0} files, {1}, {2} app folders, built in {3:N1}s" -f $genStats.Count, (Format-AdcSize $genStats.Bytes), $expected.Count, $sw.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------
Write-Host "`n[2] Benchmark: full scan in each power mode" -ForegroundColor Cyan
$paths = [ordered]@{ Test = $root }
[void](Invoke-AdcScan -Paths $paths)                       # warm-up (fills the Windows file cache)
$proc = [Diagnostics.Process]::GetCurrentProcess()
$cores = [Environment]::ProcessorCount
$bench = @()
foreach ($mode in 'Normal', 'Eco', 'PowerSaver') {
    Set-AdcPowerMode $mode -WholeProcess
    [GC]::Collect()
    $proc.Refresh(); $cpu0 = $proc.TotalProcessorTime
    $t = [Diagnostics.Stopwatch]::StartNew()
    $rows = @(Invoke-AdcScan -Paths $paths)
    $t.Stop(); $proc.Refresh()
    $cpu = ($proc.TotalProcessorTime - $cpu0).TotalSeconds
    $b = [pscustomobject]@{
        Mode       = $mode
        Seconds    = [math]::Round($t.Elapsed.TotalSeconds, 2)
        CoreCpu    = [math]::Round($cpu / $t.Elapsed.TotalSeconds * 100, 1)        # % of ONE core
        MachineCpu = [math]::Round($cpu / $t.Elapsed.TotalSeconds * 100 / $cores, 1) # % of whole CPU
        FilesPerSec = [math]::Round($genStats.Count / $t.Elapsed.TotalSeconds)
        MemoryMB   = [math]::Round($proc.WorkingSet64 / 1MB)
    }
    $bench += $b
    Write-Host ("    {0,-11} {1,6:N2}s   {2,5:N1}% of 1 core   {3,4:N1}% of CPU   {4,7:N0} files/s   {5} MB RAM" -f $b.Mode, $b.Seconds, $b.CoreCpu, $b.MachineCpu, $b.FilesPerSec, $b.MemoryMB)
}
Set-AdcPowerMode 'Normal' -WholeProcess
$n = $bench | Where-Object Mode -eq 'Normal'; $e = $bench | Where-Object Mode -eq 'Eco'; $p = $bench | Where-Object Mode -eq 'PowerSaver'
if ($Apps -ge 100) {      # smaller runs finish in milliseconds: too fast to measure CPU reliably
    Add-Result 'Eco uses less CPU than Normal'        ($e.CoreCpu -lt $n.CoreCpu) ("{0}% vs {1}%" -f $e.CoreCpu, $n.CoreCpu)
    Add-Result 'PowerSaver uses less CPU than Eco'    ($p.CoreCpu -lt $e.CoreCpu) ("{0}% vs {1}%" -f $p.CoreCpu, $e.CoreCpu)
} else { Write-Host '    (CPU comparison skipped: use -Apps 100 or more)' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------
Write-Host "`n[3] Correctness of scan results" -ForegroundColor Cyan
$rows = @(Invoke-AdcScan -Paths $paths)
$byName = @{}; foreach ($r in $rows) { $byName[$r.Name] = $r }

Add-Result 'Root-level junction is skipped'     (-not $byName.ContainsKey('JunctionApp'))
Add-Result 'Every app folder found'             ($rows.Count -eq $expected.Count) ("$($rows.Count) of $($expected.Count)")

$sizeBad = @(); $cacheBad = @(); $prioBad = @(); $unusedBad = @()
foreach ($k in $expected.Keys) {
    $r = $byName[$k]; $x = $expected[$k]
    if (-not $r) { $sizeBad += $k; continue }
    if ($r.Size -ne $x.Size) { $sizeBad += "$k ($($r.Size) vs $($x.Size))" }
    if ($r.CacheSize -ne $x.Cache) { $cacheBad += "$k ($($r.CacheSize) vs $($x.Cache))" }
    $wantPrio = if ($x.Category -eq 'Protected') { 'Protected' }
                elseif ($x.Cache -ge 100MB) { 'High' } elseif ($x.Cache -ge 10MB) { 'Medium' } elseif ($x.Cache -gt 0) { 'Low' } else { 'None' }
    if ($r.Priority -ne $wantPrio) { $prioBad += "$k ($($r.Priority) vs $wantPrio)" }
    if ($x.Unused -and $r.DaysUnused -lt 199) { $unusedBad += $k }
    if (-not $x.Unused -and $r.DaysUnused -gt 1) { $unusedBad += $k }
}
Add-Result 'Total sizes exact (junction targets not counted)' (-not $sizeBad.Count)  (($sizeBad | Select-Object -First 3) -join '; ')
Add-Result 'Cache sizes exact (deep folders ignored)'         (-not $cacheBad.Count) (($cacheBad | Select-Object -First 3) -join '; ')
Add-Result 'Priorities correct'                               (-not $prioBad.Count)  (($prioBad | Select-Object -First 3) -join '; ')
Add-Result 'Unused detection correct (200-day-old apps)'      (-not $unusedBad.Count) (($unusedBad | Select-Object -First 3) -join '; ')
Add-Result 'Unicode / special-character names scanned'        ($byName.ContainsKey($specialNames[0]) -and $byName.ContainsKey($specialNames[1]))

$counts = $rows | Group-Object Priority | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "    Priorities: $($counts -join ', ')"

# ---------------------------------------------------------------------
Write-Host "`n[4] Scheduled-run selection" -ForegroundColor Cyan
$s = Get-AdcDefaultSettings
$s.Schedule.Priorities = @('High', 'Medium'); $s.Schedule.UnusedOnly = $false
$r1 = Invoke-AdcScheduledRun -WhatIf -Paths $paths -Settings $s
$want1 = @($rows | Where-Object { $_.Priority -in 'High', 'Medium' }).Count
Add-Result 'High+Medium selection'                    (@($r1.Targets).Count -eq $want1) ("$(@($r1.Targets).Count) apps, $(Format-AdcSize $r1.Size)")
$s.Schedule.Priorities = @('High', 'Medium', 'Low'); $s.Schedule.UnusedOnly = $true; $s.Schedule.UnusedDays = 100
$r2 = Invoke-AdcScheduledRun -WhatIf -Paths $paths -Settings $s
$want2 = @($rows | Where-Object { $_.PriorityRank -gt 0 -and $_.DaysUnused -ge 100 }).Count
Add-Result 'Unused-only (100+ days) selection'        (@($r2.Targets).Count -eq $want2) ("$(@($r2.Targets).Count) apps")
Add-Result 'Protected apps never auto-selected'       (-not ($r1.Targets | Where-Object Name -eq 'Microsoft'))
Add-Result 'WhatIf deleted nothing'                   ((Get-TreeStats $root).Bytes -eq $genStats.Bytes)

# ---------------------------------------------------------------------
Write-Host "`n[5] Cleaning: cache-only mode" -ForegroundColor Cyan
$excludedApp = ($rows | Where-Object PriorityRank -gt 0 | Sort-Object PriorityRank -Descending | Select-Object -First 1)   # biggest cleanable app
Set-AdcPriority $excludedApp @($excludedApp.Path)                       # user excluded it
$targets = @($rows | Where-Object { $_.PriorityRank -gt 0 -or $_.PriorityRank -eq -2 })
$wantFreed = 0L; foreach ($t in $targets) { if ($t.PriorityRank -gt 0) { $wantFreed += $t.CacheSize } }

$t = [Diagnostics.Stopwatch]::StartNew()
$clean = Invoke-AdcClean $targets 'Cache'
$t.Stop()
Write-Host ("    Cleaned {0} apps, freed {1} in {2:N2}s" -f $clean.Cleaned, (Format-AdcSize $clean.Freed), $t.Elapsed.TotalSeconds)
Add-Result 'Freed exactly the expected cache bytes' ($clean.Freed -eq $wantFreed) ("$(Format-AdcSize $clean.Freed) of $(Format-AdcSize $wantFreed)")
Add-Result 'Excluded app was skipped'               ($clean.Skipped -contains $excludedApp.Name)

$after = @(Invoke-AdcScan -Paths $paths); $afterBy = @{}; foreach ($r in $after) { $afterBy[$r.Name] = $r }
$leftover = @($targets | Where-Object { $_.PriorityRank -gt 0 -and $afterBy[$_.Name].CacheSize -ne 0 })
$lostData = @($targets | Where-Object { $_.PriorityRank -gt 0 -and $afterBy[$_.Name].Size -ne ($_.Size - $_.CacheSize) })
$dirsGone = @($targets | Where-Object { $_.PriorityRank -gt 0 } | ForEach-Object { $_.CacheDirs } | Where-Object { -not (Test-Path -LiteralPath $_) })
Add-Result 'All targeted caches are empty'          (-not $leftover.Count) (($leftover.Name | Select-Object -First 3) -join ', ')
Add-Result 'No non-cache file was deleted'          (-not $lostData.Count) (($lostData.Name | Select-Object -First 3) -join ', ')
Add-Result 'Cache folders themselves kept'          (-not $dirsGone.Count)
Add-Result 'Read-only cache file deleted'           (-not (Test-Path -LiteralPath $roFile))
Add-Result 'Deep "Cache" (beyond limit) untouched'  (Test-Path -LiteralPath (Join-Path $deepDir 'deep.bin'))
Add-Result 'Excluded app cache untouched'           ($afterBy[$excludedApp.Name].CacheSize -eq $excludedApp.CacheSize)
$v = Get-TreeStats $victim
Add-Result 'Junction target (Victim) intact'        ($v.Count -eq $victimBefore.Count -and $v.Bytes -eq $victimBefore.Bytes) ("$($v.Count) files")

# ---------------------------------------------------------------------
Write-Host "`n[6] Cleaning: entire-folder mode + safety guards" -ForegroundColor Cyan
$msRow = $afterBy['Microsoft']; $j8 = $afterBy['App_0008']
$e = Invoke-AdcClean @($msRow, $j8) 'Entire'
Add-Result 'Protected folder refused'               (($e.Skipped -contains 'Microsoft') -and (Test-Path (Join-Path $root 'Microsoft')))
Add-Result 'Normal app folder fully removed'        (-not (Test-Path (Join-Path $root 'App_0008')))
$v = Get-TreeStats $victim
Add-Result 'Victim intact after deleting folder with junction' ($v.Count -eq $victimBefore.Count) ("$($v.Count) files")
Add-Result 'Guard: C:\Windows not deletable'        (-not (Test-AdcSafePath 'C:\Windows\Temp'))
Add-Result 'Guard: Downloads not deletable'         (-not (Test-AdcSafePath (Join-Path $env:LOCALAPPDATA 'x\Downloads\y')))
Add-Result 'Guard: AppData root itself not deletable' (-not (Test-AdcSafePath $env:LOCALAPPDATA))

# ---------------------------------------------------------------------
Write-Host "`n[7] Windows temp cleaner (fake folders)" -ForegroundColor Cyan
$tRoot = Join-Path $WorkDir 'TempTargets'
$tUser = Join-Path $tRoot 'UserTemp'; $tDl = Join-Path $tRoot 'Downloads'; $tSys = Join-Path $tRoot 'SystemTemp'; $tOther = Join-Path $tRoot 'NotListed'
New-Item -ItemType Directory -Force (Join-Path $tUser 'sub\deeper'), $tDl, $tSys, $tOther | Out-Null
$wantTemp = 0L
foreach ($p in @("$tUser\a.tmp", "$tUser\sub\b.tmp", "$tUser\sub\deeper\c.tmp")) { New-TestFile $p 50000 $null; $wantTemp += 50000 }
New-TestFile "$tUser\ro.tmp" 1000 $null; (Get-Item "$tUser\ro.tmp").IsReadOnly = $true; $wantTemp += 1000
cmd /c mklink /J "$tUser\link_to_victim" "$victim" | Out-Null
New-TestFile "$tDl\keep-me.zip" 70000 $null; New-TestFile "$tSys\sys.tmp" 30000 $null; New-TestFile "$tOther\other.tmp" 30000 $null
$fakeTargets = @(
    [pscustomobject]@{ Name = 'Fake user temp'; Path = $tUser; Admin = $false; Kind = 'Folder' }
    [pscustomobject]@{ Name = 'Fake downloads'; Path = $tDl;   Admin = $false; Kind = 'Folder' }
    [pscustomobject]@{ Name = 'Fake system';    Path = $tSys;  Admin = $true;  Kind = 'Folder' }
)
$tc = Invoke-AdcTempClean -Targets $fakeTargets
Add-Result 'Temp folder emptied (incl. read-only)'     ((Get-TreeStats $tUser).Count -eq 0 -and (Test-Path $tUser)) ("freed $(Format-AdcSize $tc.Freed)")
Add-Result 'Freed exactly the temp bytes'              ($tc.Freed -eq $wantTemp)
Add-Result 'Junction in temp: target intact'           ((Get-TreeStats $victim).Count -eq $victimBefore.Count)
Add-Result 'Folder named Downloads never touched'      (Test-Path "$tDl\keep-me.zip")
Add-Result 'System folders skipped without -System'    (Test-Path "$tSys\sys.tmp")
Add-Result 'Folder not on the list is refused'         ((Clear-AdcTempFolder $tOther @($tUser)) -eq 0 -and (Test-Path "$tOther\other.tmp"))

# ---------------------------------------------------------------------
if ($TestScheduler) {
    Write-Host "`n[8] Task Scheduler registration" -ForegroundColor Cyan
    $tn = 'ByteCut - StressTest'
    $s = Get-AdcDefaultSettings; $s.Schedule.Enabled = $true; $s.Schedule.Days = @('Monday', 'Thursday'); $s.Schedule.Time = '21:30'
    try {
        Register-AdcSchedule $s -ScriptPath (Join-Path $repo 'src\ByteCut.ps1') -TaskName $tn
        $info = Get-AdcScheduleInfo $tn
        Add-Result 'Task registered with next run time' ([bool]$info.NextRun) ("next run $($info.NextRun)")
    } catch { Add-Result 'Task registered' $false $_.Exception.Message }
    Unregister-AdcSchedule $tn
    Add-Result 'Task removed again' (-not (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------------
$passed = @($results | Where-Object Pass).Count
$failed = $results.Count - $passed
$resDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $resDir | Out-Null
$cpuName = "$((Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString)".Trim()   # registry, not WMI (WMI can hang)

$md = @()
$md += '# Stress Test Report'
$md += ''
$md += "- **Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$md += "- **Machine:** $cpuName, $cores logical cores, PowerShell $($PSVersionTable.PSVersion)"
$md += ("- **Test data:** {0} app folders, {1:N0} files, {2}" -f $expected.Count, $genStats.Count, (Format-AdcSize $genStats.Bytes))
$md += "- **Result:** $passed passed, $failed failed"
$md += ''
$md += '## Scan benchmark (warm file cache)'
$md += ''
$md += '| Power mode | Time | CPU (one core) | CPU (whole machine) | Files / sec | RAM |'
$md += '|---|---|---|---|---|---|'
foreach ($b in $bench) { $md += ('| {0} | {1:N2} s | {2:N1} % | {3:N1} % | {4:N0} | {5} MB |' -f $b.Mode, $b.Seconds, $b.CoreCpu, $b.MachineCpu, $b.FilesPerSec, $b.MemoryMB) }
$md += ''
$md += '## Checks'
$md += ''
$md += '| Result | Check | Detail |'
$md += '|---|---|---|'
foreach ($r in $results) { $md += ('| {0} | {1} | {2} |' -f $(if ($r.Pass) { 'PASS' } else { '**FAIL**' }), $r.Test, $r.Detail) }
$md | Set-Content (Join-Path $resDir 'StressTest-Report.md') -Encoding UTF8

if (-not $Keep) { cmd /c "rd /s /q `"$WorkDir`"" }
Write-Host ("`n=== {0} passed, {1} failed ===   report: tests\results\StressTest-Report.md`n" -f $passed, $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
if ($failed) { exit 1 }
