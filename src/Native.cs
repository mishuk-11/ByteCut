// ByteCut - native helpers (compiled into the .exe, or loaded with Add-Type when run from source)
// Developer: Inzamam Islam
// Keep this C# 5 compatible: it is compiled by the csc.exe that ships with Windows (.NET Framework 4.x).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Adc
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct PowerThrottlingState { public uint Version; public uint ControlMask; public uint StateMask; }

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref PowerThrottlingState info, int size);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        [DllImport("psapi.dll")]
        private static extern bool EmptyWorkingSet(IntPtr hProcess);

        // "Boost": ask every process we may touch to release unused RAM (Windows pages it back in on demand).
        // Returns how many processes were trimmed; others (protected/system) are skipped.
        public static int TrimWorkingSets()
        {
            int n = 0;
            foreach (Process p in Process.GetProcesses())
            {
                try { if (EmptyWorkingSet(p.Handle)) n++; } catch (Exception) { }
                finally { p.Dispose(); }
            }
            return n;
        }

        // Sharp rendering on scaled displays: the app scales its own layout (system DPI aware)
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        // Windows 11 "Efficiency mode" (EcoQoS) for the whole process.
        // Only for runs WITHOUT a window (scheduled mode): after a few seconds in process-wide
        // Efficiency mode Windows draws the app's text without ClearType (jagged, pixelated).
        public static bool SetEfficiencyMode(bool on)
        {
            PowerThrottlingState s = new PowerThrottlingState();
            s.Version = 1; s.ControlMask = 1; s.StateMask = on ? 1u : 0u;
            return SetProcessInformation(GetCurrentProcess(), 4, ref s, Marshal.SizeOf(typeof(PowerThrottlingState)));
        }

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentThread();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetThreadInformation(IntPtr hThread, int infoClass, ref PowerThrottlingState info, int size);

        // EcoQoS for the calling thread only (the background scan thread). The UI thread keeps
        // full rendering quality while the scan still runs on efficient, low-power scheduling.
        public static bool SetThreadEfficiencyMode(bool on)
        {
            PowerThrottlingState s = new PowerThrottlingState();
            s.Version = 1; s.ControlMask = 1; s.StateMask = on ? 1u : 0u;
            return SetThreadInformation(GetCurrentThread(), 3, ref s, Marshal.SizeOf(typeof(PowerThrottlingState)));   // ThreadPowerThrottling
        }
    }

    // Window chrome and native control theming (Fluent look without owner-drawing)
    public static class Ui
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string subIdList);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendHeaderItem(IntPtr hWnd, int msg, IntPtr wParam, ref HeaderItem item);

        [StructLayout(LayoutKind.Sequential)]
        private struct HeaderItem
        {
            public uint Mask; public int Cxy; public IntPtr Text; public IntPtr Bitmap; public int TextMax;
            public int Format; public IntPtr Param; public int Image; public int Order; public uint FilterType;
            public IntPtr Filter; public uint State;
        }

        // Dark title bar (Windows 10 20H1+ / 11), rounded corners and a 1px border color (Windows 11)
        public static void SetWindowChrome(IntPtr hwnd, bool dark, int borderColorRef)
        {
            int v = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref v, 4);
            int round = 2;
            DwmSetWindowAttribute(hwnd, 33, ref round, 4);
            DwmSetWindowAttribute(hwnd, 34, ref borderColorRef, 4);
        }

        // Native dark/light theme for a ListView, its header and scrollbars
        // (Light uses the default theme: the "Explorer" theme draws column lines when the header is hidden.)
        public static void ThemeListView(IntPtr listView, bool dark)
        {
            SetWindowTheme(listView, dark ? "DarkMode_Explorer" : null, null);
            IntPtr header = SendMessage(listView, 0x101F, IntPtr.Zero, IntPtr.Zero);          // LVM_GETHEADER
            if (header != IntPtr.Zero) SetWindowTheme(header, dark ? "DarkMode_ItemsView" : "ItemsView", null);
        }

        public static void ThemeControl(IntPtr hwnd, bool dark)
        {
            SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : null, null);
        }

        // Native sort arrow in a ListView column header. order: 1 = ascending, -1 = descending, 0 = none
        public static void SetSortIcon(IntPtr listView, int column, int order)
        {
            IntPtr header = SendMessage(listView, 0x101F, IntPtr.Zero, IntPtr.Zero);
            if (header == IntPtr.Zero) return;
            int count = (int)SendMessage(header, 0x1200, IntPtr.Zero, IntPtr.Zero);          // HDM_GETITEMCOUNT
            for (int i = 0; i < count; i++)
            {
                HeaderItem item = new HeaderItem();
                item.Mask = 0x4;                                                               // HDI_FORMAT
                SendHeaderItem(header, 0x120B, new IntPtr(i), ref item);                       // HDM_GETITEMW
                item.Format &= ~(0x400 | 0x200);                                               // HDF_SORTUP | HDF_SORTDOWN
                if (i == column && order > 0) item.Format |= 0x400;
                if (i == column && order < 0) item.Format |= 0x200;
                SendHeaderItem(header, 0x120C, new IntPtr(i), ref item);                       // HDM_SETITEMW
            }
        }
    }

    public class FolderStats
    {
        public long Size;
        public long CacheSize;
        public int Files;
        public DateTime NewestUtc;
        public string[] CacheDirs;
    }

    public static class Scanner
    {
        // Set by the power modes.
        // Duty cycle: work WorkMs, then sleep SleepMs (0 = never sleep). Threads: app folders scanned at once.
        public static int WorkMs = 0;
        public static int SleepMs = 0;
        public static int Threads = 1;

        [ThreadStatic] private static Stopwatch watch;

        public static void Throttle()
        {
            if (WorkMs <= 0) return;
            if (watch == null) watch = Stopwatch.StartNew();
            if (watch.ElapsedMilliseconds >= WorkMs) { Thread.Sleep(SleepMs); watch.Restart(); }
        }

        // ---- Raw Win32 directory listing (about 2x faster than DirectoryInfo on .NET Framework) ----
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint SizeHigh, SizeLow, Reserved0, Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileEx(string fileName, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool FindNextFile(IntPtr handle, out FindData data);
        [DllImport("kernel32.dll")]
        private static extern bool FindClose(IntPtr handle);

        private const uint AttrDirectory = 0x10, AttrReparse = 0x400;
        private const int FindExInfoBasic = 1, FindFirstExLargeFetch = 2;
        private static readonly IntPtr Invalid = new IntPtr(-1);

        // One pass over an app folder: total size, cache size, cache folders and newest file.
        // Junctions / symlinks are never followed. Folders that cannot be read are skipped.
        public static FolderStats Measure(string path, string[] cacheNames, int cacheDepth)
        {
            HashSet<string> names = new HashSet<string>(cacheNames, StringComparer.OrdinalIgnoreCase);
            FolderStats st = new FolderStats();
            List<string> cacheDirs = new List<string>();
            long newest = 0;
            Stack<Tuple<string, int, bool>> stack = new Stack<Tuple<string, int, bool>>();
            stack.Push(Tuple.Create(path.TrimEnd('\\'), 0, false));

            while (stack.Count > 0)
            {
                Tuple<string, int, bool> t = stack.Pop();
                FindData fd;
                IntPtr h = FindFirstFileEx(@"\\?\" + t.Item1 + @"\*", FindExInfoBasic, out fd, 0, IntPtr.Zero, FindFirstExLargeFetch);
                if (h == Invalid) continue;
                try
                {
                    do
                    {
                        if (fd.Name == "." || fd.Name == "..") continue;
                        if ((fd.Attributes & AttrDirectory) != 0)
                        {
                            if ((fd.Attributes & AttrReparse) != 0) continue;           // never follow links
                            string full = t.Item1 + "\\" + fd.Name;
                            bool isCache = t.Item3;
                            if (!t.Item3 && t.Item2 < cacheDepth && names.Contains(fd.Name)) { cacheDirs.Add(full); isCache = true; }
                            stack.Push(Tuple.Create(full, t.Item2 + 1, isCache));
                        }
                        else
                        {
                            long len = ((long)fd.SizeHigh << 32) | fd.SizeLow;
                            long written = ((long)(uint)fd.Written.dwHighDateTime << 32) | (uint)fd.Written.dwLowDateTime;
                            st.Size += len; st.Files++;
                            if (t.Item3) st.CacheSize += len;
                            if (written > newest) newest = written;
                        }
                    } while (FindNextFile(h, out fd));
                }
                finally { FindClose(h); }
                Throttle();
            }
            st.NewestUtc = newest > 0 ? DateTime.FromFileTimeUtc(newest) : DateTime.MinValue;
            st.CacheDirs = cacheDirs.ToArray();
            return st;
        }

        // ---- Work-sharing parallel scan ----
        // Every directory of every app folder is one work item in a shared queue, so all threads
        // stay busy until the very end (one huge app folder no longer holds the scan up).
        // Each app counts its unfinished directories; when that reaches 0 the app is done.
        private sealed class WorkItem { public int App; public string Path; public int Depth; public bool InCache; }
        private sealed class AppAcc
        {
            public long Size, Cache, Newest; public int Files; public int Pending = 1;
            public readonly List<string> CacheDirs = new List<string>();
        }

        // Progress goes into the optional synchronized hashtable: Done / Current are written,
        // Cancel = $true stops early (app folders that did not finish come back as null).
        public static FolderStats[] MeasureMany(string[] paths, string[] cacheNames, int cacheDepth, System.Collections.Hashtable sync)
        {
            HashSet<string> names = new HashSet<string>(cacheNames, StringComparer.OrdinalIgnoreCase);
            int n = paths.Length;
            AppAcc[] acc = new AppAcc[n];
            System.Collections.Concurrent.ConcurrentQueue<WorkItem> queue = new System.Collections.Concurrent.ConcurrentQueue<WorkItem>();
            int[] counters = new int[2];                       // [0] = unfinished directories overall, [1] = apps done
            for (int i = 0; i < n; i++)
            {
                acc[i] = new AppAcc();
                WorkItem w = new WorkItem(); w.App = i; w.Path = paths[i].TrimEnd('\\');
                queue.Enqueue(w);
            }
            counters[0] = n;

            ThreadStart worker = delegate
            {
                while (true)
                {
                    if (sync != null && sync["Cancel"] is bool && (bool)sync["Cancel"]) return;
                    WorkItem w;
                    if (!queue.TryDequeue(out w))
                    {
                        if (Volatile.Read(ref counters[0]) == 0) return;     // everything finished
                        Thread.Sleep(1);                                     // others are still adding work
                        continue;
                    }
                    ScanDirectory(w, acc[w.App], names, cacheDepth, queue, counters);
                    if (Interlocked.Decrement(ref acc[w.App].Pending) == 0)
                    {
                        int done = Interlocked.Increment(ref counters[1]);
                        if (sync != null) { sync["Done"] = done; sync["Current"] = paths[w.App]; }
                    }
                    Interlocked.Decrement(ref counters[0]);
                    Throttle();
                }
            };

            int threads = Math.Max(1, Math.Min(Threads, 16));
            if (threads == 1) worker();                       // Eco / Power saver: stay on this (low-priority) thread
            else
            {
                ThreadPriority prio = Thread.CurrentThread.Priority;
                Thread[] pool = new Thread[threads];
                for (int i = 0; i < threads; i++) { pool[i] = new Thread(worker); pool[i].IsBackground = true; pool[i].Priority = prio; pool[i].Start(); }
                foreach (Thread t in pool) t.Join();
            }

            FolderStats[] result = new FolderStats[n];
            for (int i = 0; i < n; i++)
            {
                AppAcc a = acc[i];
                if (a.Pending != 0) continue;                 // cancelled before this app finished
                FolderStats st = new FolderStats();
                st.Size = a.Size; st.CacheSize = a.Cache; st.Files = a.Files;
                st.NewestUtc = a.Newest > 0 ? DateTime.FromFileTimeUtc(a.Newest) : DateTime.MinValue;
                st.CacheDirs = a.CacheDirs.ToArray();
                result[i] = st;
            }
            return result;
        }

        private static void ScanDirectory(WorkItem w, AppAcc a, HashSet<string> names, int cacheDepth,
            System.Collections.Concurrent.ConcurrentQueue<WorkItem> queue, int[] counters)
        {
            long size = 0, cache = 0, newest = 0; int files = 0;
            FindData fd;
            IntPtr h = FindFirstFileEx(@"\\?\" + w.Path + @"\*", FindExInfoBasic, out fd, 0, IntPtr.Zero, FindFirstExLargeFetch);
            if (h == Invalid) return;
            try
            {
                do
                {
                    string name = fd.Name;
                    if ((fd.Attributes & AttrDirectory) != 0)
                    {
                        if (name == "." || name == ".." || (fd.Attributes & AttrReparse) != 0) continue;   // never follow links
                        WorkItem sub = new WorkItem();
                        sub.App = w.App; sub.Path = w.Path + "\\" + name; sub.Depth = w.Depth + 1; sub.InCache = w.InCache;
                        if (!w.InCache && w.Depth < cacheDepth && names.Contains(name))
                        {
                            sub.InCache = true;
                            lock (a.CacheDirs) a.CacheDirs.Add(sub.Path);
                        }
                        // Count the child before the parent finishes, so "pending" never hits 0 too early
                        Interlocked.Increment(ref a.Pending);
                        Interlocked.Increment(ref counters[0]);
                        queue.Enqueue(sub);
                    }
                    else
                    {
                        long len = ((long)fd.SizeHigh << 32) | fd.SizeLow;
                        long written = ((long)(uint)fd.Written.dwHighDateTime << 32) | (uint)fd.Written.dwLowDateTime;
                        size += len; files++;
                        if (w.InCache) cache += len;
                        if (written > newest) newest = written;
                    }
                } while (FindNextFile(h, out fd));
            }
            finally { FindClose(h); }
            lock (a)
            {
                a.Size += size; a.Cache += cache; a.Files += files;
                if (newest > a.Newest) a.Newest = newest;
            }
        }
    }
}
