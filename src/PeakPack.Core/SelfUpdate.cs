using System.Diagnostics;

namespace PeakPack.Core;

/// <summary>
/// The friend app updates itself from the manifest's "app" entry (hash-pinned like everything else).
/// Windows can't overwrite a running exe but CAN rename it, so: download new -> rename running exe to
/// PeakPack.old.exe -> move new into place -> restart with the same arguments. The .old file is deleted
/// on the next start.
/// </summary>
public static class SelfUpdate
{
    public static Version CurrentVersion =>
        (System.Reflection.Assembly.GetEntryAssembly() ?? typeof(SelfUpdate).Assembly).GetName().Version is { } v ? new Version(v.Major, v.Minor, Math.Max(v.Build, 0)) : new Version(0, 0, 0);

    /// <summary>The updated copy started by the last successful TryUpdateAsync (headless mode waits for it).</summary>
    public static Process? LastStarted { get; private set; }

    public static void CleanupOld(AppPaths paths)
    {
        try { File.Delete(Path.Combine(paths.DataDir, AppPaths.AppName + ".old.exe")); } catch { }
    }

    public static bool IsNewer(AppRelease? rel) =>
        rel is not null && Version.TryParse(rel.Version, out var v) && v > CurrentVersion;

    /// <summary>Returns true if an update was installed and the app should restart (caller exits).
    /// Only updates the installed copy in the data folder; dev builds run from elsewhere are left alone.</summary>
    public static async Task<bool> TryUpdateAsync(AppPaths paths, Downloader dl, PackManifest m, string manifestLocation, string[] restartArgs, CancellationToken ct = default)
    {
        if (!IsNewer(m.App)) return false;
        var running = Environment.ProcessPath;
        if (running is null || !running.Equals(paths.InstalledExePath, StringComparison.OrdinalIgnoreCase)) return false;

        var (cached, _, _) = await dl.GetVerifiedAsync(Downloader.ResolveRelative(manifestLocation, m.App!.Url), m.App.Sha256, null, ct);
        var old = Path.Combine(paths.DataDir, AppPaths.AppName + ".old.exe");
        if (File.Exists(old)) File.Delete(old);
        File.Move(running, old);
        try { File.Copy(cached, running); }
        catch { File.Move(old, running); throw; }
        paths.Log($"Self-updated {CurrentVersion} -> {m.App.Version}");

        var psi = new ProcessStartInfo(running) { UseShellExecute = false };
        foreach (var a in restartArgs) psi.ArgumentList.Add(a);
        LastStarted = Process.Start(psi);
        return true;
    }
}
