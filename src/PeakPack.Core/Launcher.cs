using System.Diagnostics;

namespace PeakPack.Core;

/// <summary>
/// Starts PEAK through Steam (exactly like r2modman and Gale do on Windows: steam.exe -applaunch &lt;appid&gt; args).
/// Going through Steam matters: PEAK is a Steamworks game and needs Steam for login/lobbies.
/// </summary>
public static class Launcher
{
    public static IReadOnlyList<string> GameArgs(LaunchMode mode, AppPaths paths) => mode == LaunchMode.Modded
        ? ["--doorstop-enabled", "true", "--doorstop-target-assembly", paths.PreloaderPath]
        // Belt and braces: the ini already says enabled=false; this also overrides any stray ini.
        : ["--doorstop-enabled", "false"];

    public enum Method
    {
        /// <summary>Normal: steam.exe -applaunch.</summary>
        Steam,
        /// <summary>Test only: start &lt;gameDir&gt;\PEAK.exe directly (used with the sandbox fake game).</summary>
        DirectExe,
        /// <summary>Don't start anything; just return the command line.</summary>
        DryRun,
    }

    /// <summary>Returns the command line that was (or would be) run.</summary>
    public static string Launch(LaunchMode mode, AppPaths paths, InstallState state, string gameDir, Method method)
    {
        var psi = new ProcessStartInfo { UseShellExecute = false };
        if (method == Method.DirectExe)
        {
            psi.FileName = Path.Combine(gameDir, "PEAK.exe");
            psi.WorkingDirectory = gameDir;
        }
        else
        {
            psi.FileName = SteamLocator.FindSteamExe()
                ?? throw new FileNotFoundException("Couldn't find Steam. Is Steam installed?");
            psi.ArgumentList.Add("-applaunch");
            psi.ArgumentList.Add(SteamLocator.PeakAppId.ToString());
        }
        foreach (var a in GameArgs(mode, paths)) psi.ArgumentList.Add(a);

        var cmd = $"\"{psi.FileName}\" " + string.Join(' ', psi.ArgumentList.Select(a => a.Contains(' ') ? $"\"{a}\"" : a));
        if (method != Method.DryRun)
        {
            using var _ = Process.Start(psi);
            state.LastLaunchMode = mode;
            state.LastLaunchTime = DateTimeOffset.Now;
            state.Save(paths);
        }
        paths.Log($"Launch {mode} ({method}): {cmd}");
        return cmd;
    }

    /// <summary>
    /// Did the most recent game start actually load BepInEx? BepInEx rewrites profile\BepInEx\LogOutput.log
    /// on every modded start, so if PEAK was started after that file was last written, that start was vanilla.
    /// </summary>
    public static DateTime? LastModdedStartUtc(AppPaths paths)
    {
        var log = Path.Combine(paths.BepInExDir, "LogOutput.log");
        return File.Exists(log) ? File.GetLastWriteTimeUtc(log) : null;
    }
}
