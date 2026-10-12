using Microsoft.Win32;

namespace PeakPack.Core;

/// <summary>First-run setup (copy the app to its home, shortcuts, Add/Remove Programs entry) and
/// the full "Remove everything" uninstall. All per-user; never needs admin.</summary>
public static class Setup
{
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\PeakPack";

    public sealed record Options(string ShortcutName, string? DesktopDir, string? StartMenuDir, bool RegisterUninstall);

    public static Options DefaultOptions(PackConfig cfg, AppPaths paths, string? shortcutDirOverride) =>
        shortcutDirOverride is null
            ? new Options(cfg.ShortcutName, ShortcutHelper.DesktopDir, Path.Combine(ShortcutHelper.StartMenuProgramsDir, AppPaths.AppName), paths.IsDefaultLocation)
            : new Options(cfg.ShortcutName, Path.Combine(shortcutDirOverride, "Desktop"), Path.Combine(shortcutDirOverride, "StartMenu"), false);

    public const string AppShortcutName = "PeakPack";
    const string LegacyAppShortcut = "PeakPack (mods, normal PEAK, uninstall).lnk"; // v0.2 name

    public sealed record SelfInstallResult(string InstalledExe, bool Copied, bool KeptNewerInstalledCopy);

    /// <summary>
    /// First run: install the app the way any per-user installer does, so that the downloaded file is never
    /// needed again. Writes the running exe's bytes to %LOCALAPPDATA%\PeakPack\PeakPack.exe as a NEW file
    /// (a stream copy, like an installer writing its payload). Unlike File.Copy / CopyFileEx, a stream copy
    /// doesn't carry over the download's alternate data streams (Mark-of-the-Web), so later launches of the
    /// installed copy don't show SmartScreen again: the friend already approved this exact program once.
    /// If a NEWER copy is already installed (e.g. self-updated), it is kept.
    /// </summary>
    public static SelfInstallResult EnsureInstalledCopy(AppPaths paths, string? runningExe = null)
    {
        runningExe ??= Environment.ProcessPath!;
        Directory.CreateDirectory(paths.DataDir);
        var exe = paths.InstalledExePath;
        if (string.Equals(Path.GetFullPath(runningExe), Path.GetFullPath(exe), StringComparison.OrdinalIgnoreCase))
            return new SelfInstallResult(exe, false, false);
        if (File.Exists(exe) && FileVersion(exe) is { } inst && FileVersion(runningExe) is { } run && inst > run)
            return new SelfInstallResult(exe, false, true);
        // Same file already installed (the friend opened the download again): nothing to do. This also avoids
        // failing when the installed copy is running right now.
        if (File.Exists(exe) && new FileInfo(exe).Length == new FileInfo(runningExe).Length
            && Downloader.Sha256OfFile(exe) == Downloader.Sha256OfFile(runningExe))
            return new SelfInstallResult(exe, false, false);

        var tmp = exe + ".new";
        CopyBytesOnly(runningExe, tmp);
        File.Move(tmp, exe, true);
        paths.Log($"App installed to {exe} (from {runningExe})");
        return new SelfInstallResult(exe, true, false);
    }

    /// <summary>Copies file content only (no alternate data streams, no attributes).</summary>
    public static void CopyBytesOnly(string src, string dst)
    {
        using var i = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        using var o = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None);
        i.CopyTo(o);
    }

    /// <summary>True if the file carries a Mark-of-the-Web (Zone.Identifier alternate data stream).</summary>
    public static bool HasMarkOfTheWeb(string path)
    {
        try { return File.Exists(path + ":Zone.Identifier"); } catch { return false; }
    }

    static Version? FileVersion(string path)
    {
        try
        {
            var v = System.Diagnostics.FileVersionInfo.GetVersionInfo(path);
            return new Version(v.FileMajorPart, v.FileMinorPart, v.FileBuildPart);
        }
        catch { return null; }
    }

    /// <summary>
    /// Creates (or refreshes) the shortcuts, all pointing at the INSTALLED copy:
    ///   Desktop:               "PEAK (Modded)"  -> PeakPack.exe --launch   (PEAK.exe's icon when PEAK is known)
    ///   Start Menu\PeakPack:   "PEAK (Modded)"  and  "PeakPack" (the app window: status, normal PEAK, remove)
    /// plus the Installed Apps entry. Desktop "PeakPack" only if <paramref name="desktopAppShortcut"/>.
    /// </summary>
    public static void CreateShortcuts(AppPaths paths, string? gameDir, Options opt, string? extraArgs = null, bool desktopAppShortcut = false)
    {
        if (Platform.IsWine) { paths.Log("Under Wine: no .lnk shortcuts or uninstall entry (the Mac front end owns those)."); return; }
        var exe = paths.InstalledExePath;
        var icon = gameDir is not null && File.Exists(Path.Combine(gameDir, "PEAK.exe")) ? Path.Combine(gameDir, "PEAK.exe") : exe;
        var lnkName = opt.ShortcutName + ".lnk";
        // Normal installs need no extra arguments; test installs pass their overrides (--data-dir etc.).
        var dataArg = extraArgs is { Length: > 0 } ? " " + extraArgs : paths.IsDefaultLocation ? "" : $" --data-dir \"{paths.DataDir}\"";
        const string playDesc = "Updates the mods if needed, then starts PEAK with mods.";
        const string appDesc = "PeakPack: mod pack status, play normal PEAK, or remove the mods.";
        if (opt.DesktopDir is not null)
        {
            ShortcutHelper.CreateShortcut(Path.Combine(opt.DesktopDir, lnkName), exe, "--launch" + dataArg, paths.DataDir, icon, 0, playDesc);
            if (desktopAppShortcut)
                ShortcutHelper.CreateShortcut(Path.Combine(opt.DesktopDir, AppShortcutName + ".lnk"), exe, dataArg.Trim(), paths.DataDir, exe, 0, appDesc);
        }
        if (opt.StartMenuDir is not null)
        {
            ShortcutHelper.CreateShortcut(Path.Combine(opt.StartMenuDir, lnkName), exe, "--launch" + dataArg, paths.DataDir, icon, 0, playDesc);
            ShortcutHelper.CreateShortcut(Path.Combine(opt.StartMenuDir, AppShortcutName + ".lnk"), exe, dataArg.Trim(), paths.DataDir, exe, 0, appDesc);
            try { File.Delete(Path.Combine(opt.StartMenuDir, LegacyAppShortcut)); } catch { }
        }
        if (opt.RegisterUninstall)
        {
            using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
            k.SetValue("DisplayName", "PeakPack (PEAK mods)");
            k.SetValue("DisplayIcon", exe);
            k.SetValue("DisplayVersion", SelfUpdate.CurrentVersion.ToString(3));
            k.SetValue("Publisher", "PeakPack");
            k.SetValue("InstallLocation", paths.DataDir);
            k.SetValue("UninstallString", $"\"{exe}\" --uninstall");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            try { k.SetValue("EstimatedSize", (int)(new FileInfo(exe).Length / 1024), RegistryValueKind.DWord); } catch { }
        }
        paths.Log($"Shortcuts: {opt.DesktopDir}, {opt.StartMenuDir} -> {exe}");
    }

    /// <summary>v0.2 entry point kept for callers: install the copy, then the shortcuts.</summary>
    public static string InstallApp(AppPaths paths, string gameDir, Options opt, string? runningExe = null, string? extraArgs = null)
    {
        var r = EnsureInstalledCopy(paths, runningExe);
        CreateShortcuts(paths, gameDir, opt, extraArgs);
        return r.InstalledExe;
    }

    public sealed record UninstallReport(List<string> Removed, List<string> LeftBehind, string? BackupDir);

    /// <summary>
    /// Leaves PEAK exactly as Steam installed it: removes our winhttp.dll + doorstop_config.ini from the game
    /// folder (only if they're still the files we wrote), the profile, cache, shortcuts and registry entry.
    /// Note: Steam's "Verify integrity of game files" does NOT remove extra files like winhttp.dll, so this
    /// is the only thing that cleans the game folder.
    /// </summary>
    public static UninstallReport Uninstall(AppPaths paths, Options opt, string? gameDirOverride = null)
    {
        var state = InstallState.Load(paths);
        var removed = new List<string>();
        var left = new List<string>();
        var gameDir = gameDirOverride ?? state.GameDir;
        if (gameDir is not null && Directory.Exists(gameDir))
        {
            var before = state.GameDirFiles.Keys.Select(k => Path.Combine(gameDir, k)).ToList();
            left.AddRange(GameFolder.RemoveProxy(gameDir, state, paths));
            removed.AddRange(before.Except(left).Where(f => !File.Exists(f)));
        }

        var lnk = opt.ShortcutName + ".lnk";
        foreach (var f in new[] { opt.DesktopDir is null ? null : Path.Combine(opt.DesktopDir, lnk), opt.DesktopDir is null ? null : Path.Combine(opt.DesktopDir, AppShortcutName + ".lnk") })
            if (f is not null && File.Exists(f)) { File.Delete(f); removed.Add(f); }
        if (opt.StartMenuDir is not null && Directory.Exists(opt.StartMenuDir)) { Directory.Delete(opt.StartMenuDir, true); removed.Add(opt.StartMenuDir); }
        if (opt.RegisterUninstall) { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); removed.Add(@"HKCU\" + UninstallKey); }

        // Delete the data folder, except the running exe (Windows can't delete a running exe):
        // schedule it for deletion after we exit.
        var running = Environment.ProcessPath;
        if (Directory.Exists(paths.DataDir))
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(paths.DataDir))
            {
                if (running is not null && entry.Equals(running, StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    if (Directory.Exists(entry)) Directory.Delete(entry, true); else File.Delete(entry);
                }
                catch (Exception ex) { left.Add($"{entry} ({ex.Message})"); }
            }
            removed.Add(paths.DataDir);
            if (running is not null && running.StartsWith(paths.DataDir, StringComparison.OrdinalIgnoreCase))
                ScheduleSelfDelete(running, paths.DataDir);
            else
                try { Directory.Delete(paths.DataDir, false); } catch (IOException) { }
        }
        return new UninstallReport(removed, left, state.BackupDir);
    }

    static void ScheduleSelfDelete(string exe, string dir)
    {
        // cmd waits ~3 s for us to exit, then removes the exe and the (now empty) folder.
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = $"/c ping 127.0.0.1 -n 4 > nul & del /f /q \"{exe}\" & rmdir \"{dir}\"",
            CreateNoWindow = true,
            UseShellExecute = false,
        });
    }
}
