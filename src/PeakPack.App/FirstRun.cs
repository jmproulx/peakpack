using System.Diagnostics;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// First open of the downloaded PeakPack.exe: install it like a normal per-user installer would
/// (copy to %LOCALAPPDATA%\PeakPack\PeakPack.exe, desktop + Start Menu shortcuts, Installed Apps entry),
/// then continue from the installed copy. From then on the friend only ever starts the installed copy
/// (through the "PEAK (Modded)" icon or the Start Menu), never the downloaded file, so SmartScreen's
/// first-run prompt for the downloaded file is the only one they see.
/// </summary>
public static class FirstRun
{
    /// <summary>Only a single-file published exe can be copied on its own (a Debug build needs its DLLs next to it).</summary>
    public static bool IsSingleFile => string.IsNullOrEmpty(typeof(FirstRun).Assembly.Location);

    public static bool IsRunningInstalledCopy(AppSession s) =>
        string.Equals(Path.GetFullPath(Environment.ProcessPath!), Path.GetFullPath(s.Paths.InstalledExePath), StringComparison.OrdinalIgnoreCase);

    /// <summary>Install on first open: a real install location, or a test data dir with an explicit shortcut dir.</summary>
    public static bool ShouldInstall(AppSession s) =>
        IsSingleFile && !IsRunningInstalledCopy(s) && !AppSession.Has(s.RawArgs, "--no-self-install")
        && (s.Paths.IsDefaultLocation || s.ShortcutDirOverride is not null);

    public static Setup.SelfInstallResult Install(AppSession s)
    {
        var r = Setup.EnsureInstalledCopy(s.Paths);
        Setup.CreateShortcuts(s.Paths, s.FindGameDir(), s.SetupOptions, ExtraArgs(s));
        return r;
    }

    /// <summary>After the first successful mod install: refresh the shortcuts (PEAK's icon is known now).</summary>
    public static void RefreshShortcuts(AppSession s, string gameDir)
    {
        if (File.Exists(s.Paths.InstalledExePath)) Setup.CreateShortcuts(s.Paths, gameDir, s.SetupOptions, ExtraArgs(s));
    }

    /// <summary>Start the installed copy with the same (test) arguments; the caller then exits.</summary>
    public static void StartInstalledCopy(AppSession s)
    {
        var psi = new ProcessStartInfo(s.Paths.InstalledExePath) { UseShellExecute = false, WorkingDirectory = s.Paths.DataDir };
        foreach (var a in s.PassThroughArgs()) psi.ArgumentList.Add(a);
        Process.Start(psi);
    }

    static string? ExtraArgs(AppSession s)
    {
        var extra = string.Join(' ', s.PassThroughArgs().Select(a => a.Contains(' ') ? $"\"{a}\"" : a));
        return extra.Length == 0 ? null : extra;
    }
}
