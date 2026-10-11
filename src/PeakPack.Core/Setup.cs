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

    /// <summary>Copies the running exe into the data folder (so the downloaded file can be deleted) and
    /// creates the shortcuts. Returns the path of the installed exe.</summary>
    public static string InstallApp(AppPaths paths, string gameDir, Options opt, string? runningExe = null, string? extraArgs = null)
    {
        runningExe ??= Environment.ProcessPath!;
        Directory.CreateDirectory(paths.DataDir);
        var exe = paths.InstalledExePath;
        if (!string.Equals(Path.GetFullPath(runningExe), exe, StringComparison.OrdinalIgnoreCase))
            File.Copy(runningExe, exe, true);

        var icon = Path.Combine(gameDir, "PEAK.exe");
        var lnkName = opt.ShortcutName + ".lnk";
        // Normal installs need no extra arguments; test installs pass their overrides (--data-dir etc.).
        var dataArg = extraArgs is { Length: > 0 } ? " " + extraArgs : paths.IsDefaultLocation ? "" : $" --data-dir \"{paths.DataDir}\"";
        if (opt.DesktopDir is not null)
            ShortcutHelper.CreateShortcut(Path.Combine(opt.DesktopDir, lnkName), exe, "--launch" + dataArg, paths.DataDir, icon, 0,
                "Updates the mods if needed, then starts PEAK with mods.");
        if (opt.StartMenuDir is not null)
        {
            ShortcutHelper.CreateShortcut(Path.Combine(opt.StartMenuDir, lnkName), exe, "--launch" + dataArg, paths.DataDir, icon, 0,
                "Updates the mods if needed, then starts PEAK with mods.");
            ShortcutHelper.CreateShortcut(Path.Combine(opt.StartMenuDir, "PeakPack (mods, normal PEAK, uninstall).lnk"), exe, dataArg.Trim(), paths.DataDir, exe, 0,
                "Open PeakPack: play modded or normal PEAK, see the mod list, or remove everything.");
        }
        if (opt.RegisterUninstall)
        {
            using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
            k.SetValue("DisplayName", "PeakPack (PEAK mods from " + opt.ShortcutName + ")");
            k.SetValue("DisplayIcon", exe);
            k.SetValue("Publisher", "PeakPack");
            k.SetValue("InstallLocation", paths.DataDir);
            k.SetValue("UninstallString", $"\"{exe}\" --uninstall");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        paths.Log($"App installed to {exe}; shortcuts: {opt.DesktopDir}, {opt.StartMenuDir}");
        return exe;
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
        foreach (var f in new[] { opt.DesktopDir is null ? null : Path.Combine(opt.DesktopDir, lnk) })
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
