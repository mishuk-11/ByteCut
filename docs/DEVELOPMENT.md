# Developer Guide

How ByteCut is put together, how to build and test it, and the traps to avoid.

## Architecture

```
            ByteCut.exe  (launcher/Launcher.cs + src/Native.cs, compiled by csc.exe)
                  │  hosts a PowerShell runspace (STA) and passes:
                  │    $CoreCode   = embedded src/Core.ps1
                  │    $AppExePath = path of the .exe
                  │    $AppArgs    = command line ("--scheduled")
                  ▼
   src/ByteCut.ps1  ── UI: Fluent top bar, 5 pages, live light/dark themes, DPI scaling
        │   loads $CoreCode
        │   long work runs in a background runspace (Start-BackgroundTask)
        ▼                        ▼
   src/Core.ps1  ◄──────── background runspace (also loads $CoreCode)
        │  scan rows, priorities, clean, settings, history, Task Scheduler
        ▼
   src/Native.cs   [Adc.Scanner]::MeasureMany  (FindFirstFileEx, Parallel.For, duty cycle)
                   [Adc.Native]::SetEfficiencyMode / SendMessage
```

Running from source is the same, except `ByteCut.ps1` reads `Core.ps1` and `Native.cs`
from disk and compiles `Native.cs` once with `Add-Type`.

### Key flows

| Flow | Path |
|---|---|
| Scan | UI `Start-Scan` → background `Invoke-AdcScan` → C# `MeasureMany` (writes `Done`/`Current` into the synchronized hashtable, honours `Cancel`) → `New-AdcRow` + `Set-AdcPriority` → UI `Show-Rows` |
| Clean | UI confirm → background `Invoke-AdcClean` → `Remove-AdcTree` per cache folder (or per app folder in *entire* mode) → `Add-AdcHistory` |
| Schedule | `Register-AdcSchedule` creates a user-level weekly task running `ByteCut.exe --scheduled` |
| Scheduled run | `--scheduled` → `Invoke-AdcScheduledRun` (cache-only) → tray notification → if clicked, the normal window opens and scans |

### Windows temp cleaner
`Invoke-AdcTempClean` cleans the fixed list from `Get-AdcTempTargets`. `Clear-AdcTempFolder` refuses any path
that is not on that list or contains `\Downloads`, and empties folders with `Remove-AdcTreeCore` (never follows
junctions). Without administrator rights, admin-only targets are reported as "needs administrator". The
Settings page runs the user part in the background job; with *system temp* it starts an elevated
`ByteCut.exe --tempclean --system --result <json>` (UAC) and reads the result file when that process exits.

### Safety rules (enforced in Core.ps1 / Native.cs)
1. **Never follow reparse points.** The scanner skips them. `Remove-AdcTree` deletes a link
   with `DirectoryInfo.Delete()` (non-recursive, removes only the link) and never descends into it.
2. **`Test-AdcSafePath`** is checked before every delete: the path must be strictly *inside* one
   of the three AppData roots and must not contain `\Downloads`.
3. **`$AdcProtected`** folders are never deleted whole and are never auto-selected.
4. **Scheduled runs are cache-only.**
5. Excluded apps (`Settings.Exclusions`, stored as full paths) are skipped by `Invoke-AdcClean`.

### Power modes (`Set-AdcPowerMode`)
| Mode | `Scanner.Threads` | Duty cycle | Thread / process priority | Efficiency mode |
|---|---|---|---|---|
| Normal | min(8, cores), shared folder queue | off | Normal | off |
| Eco | 1 | 30 ms work / 15 ms sleep | BelowNormal | on |
| PowerSaver | 1 | 15 ms work / 30 ms sleep | Lowest / Idle | on |

`-WholeProcess` (used by scheduled runs) also sets the process priority class. The UI sets only
the background thread, so the window stays responsive.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File build\Build.ps1             # stress test + build
powershell -ExecutionPolicy Bypass -File build\Build.ps1 -SkipTests  # build only
```

Output: `dist\ByteCut.exe` and `dist\ByteCut.exe.sha256`. The version comes from
`$AppVersion` in `src\ByteCut.ps1`. The build uses
`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, which is **C# 5 only** (no `$"..."`,
no `=>` members, no `nameof`).

Other tools:
- `build\New-Icon.ps1` redraws `assets\app.ico` and `assets\icon-256.png`.
- `build\Take-Screenshots.ps1` renders every page to `docs\screenshots` with demo data (no real
  paths). `-Real` scans your real Local folder read-only and writes `errors.log`, which is a good
  end-to-end smoke test.

## Test

```powershell
powershell -ExecutionPolicy Bypass -File tests\StressTest.ps1                       # 300 fake apps
powershell -ExecutionPolicy Bypass -File tests\StressTest.ps1 -Apps 800 -TestScheduler
```

It builds a fake AppData tree in `%TEMP%` (hundreds of apps, big cache files, read-only files,
200-day-old apps, Unicode names, a protected folder and **junctions that point outside the tree**),
then checks:

- benchmark per power mode (time, CPU, files/s, RAM) and that Eco < Normal and PowerSaver < Eco in CPU
- exact total and cache sizes, priorities, unused detection, Unicode names
- scheduled-run selection (priorities, unused-only, protected never chosen, WhatIf deletes nothing)
- cache-only cleaning frees exactly the expected bytes, keeps every non-cache file and the cache
  folders themselves, deletes read-only files, skips excluded apps, and leaves junction targets intact
- entire-folder mode refuses protected folders, and the path guards hold
- optional: registering and removing a real scheduled task

A Markdown report is written to `tests\results\StressTest-Report.md`. Exit code 1 means a failure.

## Gotchas (learned the hard way)

1. **Keep `.ps1` files ASCII-only.** Windows PowerShell 5.1 reads BOM-less files as ANSI. Build
   icons, arrows and bullets with `[char]0x....`.
2. **PowerShell variable names ignore case.** `$g` (Graphics) silently replaced the `$G` icon
   table, and `$ph` (a page) replaced `$PH` (page height). Use distinct names. This one-liner lists
   clashes:
   ```powershell
   [Management.Automation.PSParser]::Tokenize((gc src\ByteCut.ps1 -Raw),[ref]$null) |
     ? Type -eq Variable | % Content | sort -Unique -CaseSensitive | group { $_.ToLower() } | ? Count -gt 1
   ```
3. **`$PSScriptRoot` is empty inside `[ScriptBlock]::Create()` code.** That's why the app passes
   `$NativeCode` / `$CoreCode` in, instead of letting Core find files itself.
4. **Anchors inside panels:** set a page's size to its design size *before* adding anchored
   children, and add the top bar before the pages (each page is brought to front).
5. **Background callbacks:** don't use `.GetNewClosure()` for UI callbacks (closures can't see
   script-scope functions in the hosted .exe). Pass data through the job's `Context` hashtable.
6. **Screenshots:** use `PrintWindow`, not `CopyFromScreen`. Display scaling makes
   `CopyFromScreen` capture the wrong area.
7. **`[math]::Max(0, $double)` returns an int.** PowerShell picks the `(int, int)` overload when
   the first argument is an int literal, which rounds the double (0.5 becomes 0). This froze the
   odometer wheels and made the progress bar jump between empty and full. Write `0.0` / `1.0`.

8. **Keep the UI thread free.** `Get-ScheduledTask` takes about 0.7 s. It runs through `Start-Quiet`
   (a small runspace pool), never directly in a click or page-switch handler.
9. **No PowerShell paint handlers in hot paths.** A ListView with `OwnerDraw` calls back into
   PowerShell for every cell on every repaint, which made page switches slow. Use native controls:
   flat buttons with `FlatAppearance` hover/press colors, cards with a pre-rendered `BackgroundImage`,
   and the label-based header row from `New-ListHeader`.
10. **ListView themes:** the `Explorer` theme draws column lines when the header is hidden, so Light
    uses the default theme. Dark uses `DarkMode_Explorer` (dark scrollbars), and its native header
    text is unreadable, which is another reason for `New-ListHeader`.

11. **Never set `Graphics.TextRenderingHint`.** Setting it to AntiAlias/AntiAliasGridFit on *any* Graphics
    (even a temporary bitmap) turns ClearType off for every WinForms text control in the process. Draw icons
    with `GraphicsPath.AddString` + `FillPath` (`Add-GlyphPath`).
12. **No process-wide Efficiency mode while a window is open.** A few seconds after `SetProcessInformation`
    (EcoQoS) Windows draws the process' text without ClearType. Use `SetThreadEfficiencyMode` on the scan thread.
    Verify text quality on the real screen (CopyFromScreen + count coloured ClearType edge pixels), not with
    PrintWindow, and sample for at least 30 seconds.

## Design system (Fluent)
- Palettes in `$Palettes.Light` / `$Palettes.Dark` (spec colors: background #F3F3F3/#1F1F1F, cards
  #FFFFFF/#2B2B2B, accent #0078D4, hover #106EBE, success/warning/error #107C41/#D83B01/#E81123,
  lightened in Dark for contrast). `$T` always holds the active palette.
- Every themed control is created through a helper that calls `Reg $control 'role'`. `Set-Theme`
  re-applies every role, so switching Light/Dark is live. Role `name:ColorKey` overrides the text color.
- Layout: top bar 56 px with tabs and an accent pill; content on a 12-column grid (`GX col`, `GW span`) with 16 px
  gutters and 32 px margins. Typography: classic Segoe UI in points (10.5 pt = 14 px body, 18 pt = 24 px titles). Segoe UI Variable rendered thin and jagged through GDI.
- DPI: the process calls `SetProcessDPIAware`; the whole UI is built at 96 DPI and `$form.Scale($S)` is
  applied once at the end. Bitmaps (icons, logo, card backgrounds) and rounded regions are rendered at
  `$S`, regions are recomputed on resize, ListView column widths and row height are multiplied by `$S`.
  Test layouts at other scales with `$env:ADC_FORCE_SCALE = 1.5`.
- Window chrome via `[Adc.Ui]::SetWindowChrome`: dark title bar, rounded corners, 1 px border color.
- Page performance: about 50-100 ms per page switch (pages are warmed up right after the window opens).

## Adding a cache folder name
Add it to `$AdcCacheNames` in `src\Core.ps1`. Only add names that are always safe to empty
(rebuildable data). Update the list in `docs/USER_GUIDE.md`.

## Release checklist
1. Bump `$AppVersion` in `src\ByteCut.ps1`, the README badge and `CHANGELOG.md`.
2. `build\Build.ps1` (must show *28 passed, 0 failed*).
3. Smoke test: `build\Take-Screenshots.ps1 -Real -OutDir $env:TEMP\adc-check` → `errors.log` should
   only mention the missing scheduled task. Start `dist\ByteCut.exe` once.
4. If the UI changed: `build\Take-Screenshots.ps1` to refresh `docs\screenshots`.
5. Commit, tag `v3.x.y`, create a GitHub Release, and attach `ByteCut.exe` and
   `ByteCut.exe.sha256`.
