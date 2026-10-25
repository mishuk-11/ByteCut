# Changelog

All notable changes to AppData Cleaner. Developed by Inzamam Islam.

## [4.2.0] - 2026-10-26

### Added
- **Windows temp cleaner built in** (Settings > Other tools). It cleans user temp, crash dumps, internet and
  thumbnail caches. Optional: system temp (Windows Temp, Windows Update cache, error reports, Delivery
  Optimization; asks for administrator once) and boost (flush DNS, release unused RAM, SSD TRIM).
  Results go to History.
- **Command line:** `ByteCut.exe --tempclean [--system] [--boost]` runs the temp cleaner without a window
  and shows a notification.
- About page links to the GitHub repository.
- Stress test: 6 new temp-cleaner safety checks (34 in total).

### Changed
- The Settings page scrolls (more cards than fit).
- The stress test reads the CPU name from the registry instead of WMI (WMI can hang).

## [4.1.1] - 2026-10-21

### Fixed
- **Jagged, pixelated text.** Two causes, both fixed:
  - Drawing the icons with `Graphics.TextRenderingHint = AntiAliasGridFit` switched ClearType off for every
    text control in the process. Icons are now drawn as anti-aliased vector shapes and the hint is never set.
  - Process-wide Windows **Efficiency mode** (used by Eco / Power saver) made Windows draw the app's text without
    ClearType a few seconds after it switched on. With a window open, Efficiency mode now applies only to the
    background scan thread; process-wide only for scheduled runs without a window. Eco scans stay just as light.

## [4.1.0] - 2026-10-21

### Changed
- **Crisp text:** classic Segoe UI (built into Windows) instead of Segoe UI Variable, which rendered thin
  and jagged. The app is now aware of display scaling (125 %, 150 %...), so Windows no longer stretches a
  blurry bitmap of the window: layout, icons and corners scale sharply.
- **Navigation moved to a top bar** (Fluent top navigation: tabs with an accent pill under the active one).
- **Up to 3x faster scans:** all threads now share one queue of folders instead of one app folder each, so
  a single huge folder (browser, Android SDK) no longer holds the scan up. Normal mode uses up to 8 threads.
  Measured on a real 212k-file AppData\Local: 15.2 s on 1 thread, 4.7 s on 4 threads, 3.5 s on 8 threads.

## [4.0.0] - 2026-10-21

### Changed
- **New name: ByteCut** (was AppData Cleaner). `ByteCut.exe`, `%APPDATA%\ByteCut`, task "ByteCut - Scheduled Clean".
  Settings and history from AppData Cleaner are copied over automatically.
- **Fluent design rebuild:** left navigation rail with an active pill, Fluent colors, Segoe UI Variable
  (24 px headers / 14 px body), 12-column grid with 16 px spacing, 8 px cards, rounded window corners and
  a themed 1 px border.
- **Light and dark theme** (or follow Windows), switchable live in Settings.
- **Much snappier:** all controls are native (no PowerShell paint code on hover/scroll), no animations,
  the Task Scheduler lookup runs in the background, and pages are pre-created. A page switch went from up
  to 1.2 s (Schedule) to under 100 ms.
- History shows **Total cleaned** as a plain number (the odometer was removed).
- Schedule time is now a 15-minute dropdown (themes correctly in dark mode).

### Fixed
- Disabled buttons now look disabled.

## [3.1.0] - 2026-10-21

### Changed
- **Navigation moved from the left sidebar to a top bar** with tabs. The pages are wider and the window is more compact.

### Added
- **Odometer on the History page:** car-style rolling digit wheels showing the total GB cleaned so far.
  It rolls up from the last total you saw, with a fun comparison (photos / HD movies).
- **Cleaned this month** stat on the History page.

### Fixed
- The progress bar only showed empty or full (a PowerShell `[math]::Min(1, double)` integer overload).

## [3.0.0] - 2026-10-21

### Added
- **Weekly schedule** (Windows Task Scheduler, no admin): choose days and time, then *notify only* or
  *clean automatically* (cache-only) by priority, optionally only apps unused for N days. Options:
  *only when plugged in*, *only when idle*. **Run now** does a dry run and asks before cleaning.
- **Power modes:** Normal (parallel), Eco (default) and Power saver, with a work/rest duty cycle,
  low priority and Windows 11 Efficiency mode.
- **Native C# scanner** (Win32 `FindFirstFileEx`): about 3.4x faster than v2 on a real 250k-file folder.
- **Stress test** (`tests/StressTest.ps1`): performance benchmark per power mode plus 28
  correctness and safety checks, including junction traps.
- **History page** with all-time space freed.
- **Never-clean list** (right-click > *Never clean this app*), **CSV export**, **Last used**
  column, **Location** column, *All folders* scan, **Unused 90d+** and **High + Medium** tick buttons,
  row tooltips, *Install to this PC* with shortcuts.
- **Standalone .exe** (about 100 KB) built with the C# compiler that ships with Windows; custom icon and version info.
- GitHub-ready repository: README, user guide, developer guide, MIT license, screenshots.

### Changed
- **New modern UI:** dark sidebar navigation, rounded cards, owner-drawn buttons, toggle switch, day chips,
  thin progress bar, Segoe MDL2 icons.
- Scanning and cleaning run in a **background runspace**, so the window never freezes. **Stop** cancels a scan.
- Deleting uses a dedicated tree remover with a hard path guard (only inside AppData, never Downloads).
- Settings (folder, sort order, power mode) are remembered.

## [2.0.0] - 2026-10-21
- Modern header, stat cards, coloured priority column, progress bar, footer credit.
- Sorting by name, size, cache size and priority (clickable headers and *Sort by* box).
- *Tick High priority* button, ticked counter.

## [1.0.0] - 2026-10-20
- First version: scan an AppData folder, tick apps, delete cache or the entire folder, search box.
