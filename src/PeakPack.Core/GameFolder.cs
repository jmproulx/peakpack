using System.Diagnostics;
using System.Text;

namespace PeakPack.Core;

/// <summary>
/// The only things PeakPack ever puts in the PEAK game folder are the two Doorstop proxy files:
///   winhttp.dll          (Unity Doorstop 4 - shipped inside BepInExPack_PEAK)
///   doorstop_config.ini  (written by us with enabled = false)
/// With enabled = false, launching PEAK from Steam is 100% vanilla: Doorstop loads, reads the ini,
/// and does nothing. Only the app's "Play Modded" launch turns it on, per launch, with
/// --doorstop-enabled true --doorstop-target-assembly &lt;profile&gt;\BepInEx\core\BepInEx.Preloader.dll
/// (Doorstop 4 parses the ini first and the command line second, so the command line wins -
/// see NeighTools/UnityDoorstop src/windows/config.c load_config()).
/// </summary>
public static class GameFolder
{
    public const string ProxyDll = "winhttp.dll";
    public const string DoorstopIni = "doorstop_config.ini";
    static readonly string[] ForeignLoaderItems = [ProxyDll, DoorstopIni, ".doorstop_version", "BepInEx"];

    /// <summary>First line of PEAK's version.txt (e.g. "2.6.b"), or null.</summary>
    public static string? GameVersion(string gameDir)
    {
        try { return File.ReadLines(Path.Combine(gameDir, "version.txt")).FirstOrDefault()?.Trim(); } catch { return null; }
    }

    public static bool LooksLikePeak(string? dir) =>
        dir is not null && File.Exists(Path.Combine(dir, "PEAK.exe")) && Directory.Exists(Path.Combine(dir, "PEAK_Data"));

    /// <summary>Is PEAK.exe from this game folder running? (Matched by path, so a sandbox test isn't
    /// confused by the real game, and vice versa. If the path can't be read, assume it's the same game.)</summary>
    public static bool IsGameRunning(string gameDir)
    {
        var exe = Path.GetFullPath(Path.Combine(gameDir, "PEAK.exe"));
        foreach (var p in Process.GetProcessesByName("PEAK"))
        {
            using (p)
            {
                string? path = null;
                try { path = p.MainModule?.FileName; } catch { }
                if (path is null || path.Equals(exe, StringComparison.OrdinalIgnoreCase)) return true;
            }
        }
        return false;
    }

    public sealed record Inspection(bool HasProxy, bool ProxyIsOurs, bool HasIni, bool? IniEnabled, bool HasBepInExFolder)
    {
        /// <summary>Someone (a manual install, r2modman, Gale...) put a mod loader here that isn't ours.</summary>
        public bool HasForeignLoader => (HasProxy && !ProxyIsOurs) || HasBepInExFolder;
        public bool IsVanilla => !HasProxy && !HasIni && !HasBepInExFolder;
        /// <summary>Launching from Steam would load mods.</summary>
        public bool SteamLaunchIsModded => HasProxy && IniEnabled != false;
    }

    public static Inspection Inspect(string gameDir, InstallState state)
    {
        var dll = Path.Combine(gameDir, ProxyDll);
        var ini = Path.Combine(gameDir, DoorstopIni);
        bool hasDll = File.Exists(dll);
        bool ours = hasDll && state.GameDirFiles.TryGetValue(ProxyDll, out var h) && Downloader.Sha256OfFile(dll) == h;
        bool? enabled = null;
        if (File.Exists(ini))
        {
            // Mirror Doorstop: missing key defaults to true.
            enabled = true;
            foreach (var raw in File.ReadAllLines(ini))
            {
                var line = raw.Trim();
                if (line.StartsWith("enabled", StringComparison.OrdinalIgnoreCase) && line.Contains('='))
                    enabled = !line[(line.IndexOf('=') + 1)..].Trim().Equals("false", StringComparison.OrdinalIgnoreCase);
            }
        }
        return new Inspection(hasDll, ours, File.Exists(ini), enabled, Directory.Exists(Path.Combine(gameDir, "BepInEx")));
    }

    public static string BuildIni(string preloaderPath) => new StringBuilder()
        .AppendLine("# Written by PeakPack. Do not edit - PeakPack rewrites this file.")
        .AppendLine("#")
        .AppendLine("# enabled = false means launching PEAK from Steam is the NORMAL, unmodded game.")
        .AppendLine("# The \"PEAK (Modded)\" shortcut turns mods on for that one launch only, by passing")
        .AppendLine("#   --doorstop-enabled true --doorstop-target-assembly <PeakPack profile>\\BepInEx\\core\\BepInEx.Preloader.dll")
        .AppendLine("# To remove PeakPack completely, use \"Remove everything\" in the PeakPack app.")
        .AppendLine("[General]")
        .AppendLine("enabled = false")
        .AppendLine($"target_assembly = {preloaderPath}")
        .AppendLine("redirect_output_log = false")
        .AppendLine("boot_config_override =")
        .AppendLine("ignore_disable_switch = false")
        .AppendLine()
        .AppendLine("[UnityMono]")
        .AppendLine("dll_search_path_override =")
        .AppendLine("debug_enabled = false")
        .AppendLine("debug_address = 127.0.0.1:10000")
        .AppendLine("debug_suspend = false")
        .AppendLine()
        .AppendLine("[Extra]")
        .AppendLine("bypass_vulkan = false")
        .ToString();

    /// <summary>Moves a pre-existing (foreign) loader out of the game folder into a timestamped backup.
    /// Never deletes. Returns the backup folder.</summary>
    public static string BackupForeignLoader(string gameDir, AppPaths paths)
    {
        var backup = Path.Combine(paths.BackupRoot, "game-folder-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(backup);
        foreach (var item in ForeignLoaderItems)
        {
            var src = Path.Combine(gameDir, item);
            var dst = Path.Combine(backup, item);
            if (File.Exists(src)) File.Move(src, dst);
            else if (Directory.Exists(src)) MoveDirectory(src, dst);
        }
        File.WriteAllText(Path.Combine(backup, "README.txt"),
            $"These files were in your PEAK folder ({gameDir}) before PeakPack was set up.\r\n" +
            "They were a mod loader installed some other way. PeakPack moved them here instead of deleting them.\r\n" +
            "To go back to that setup: remove PeakPack, then copy these files back into the PEAK folder.\r\n");
        paths.Log($"Backed up foreign loader files to {backup}");
        return backup;
    }

    static void MoveDirectory(string src, string dst)
    {
        try { Directory.Move(src, dst); } // same volume
        catch (IOException)
        {
            foreach (var f in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
            {
                var t = Path.Combine(dst, Path.GetRelativePath(src, f));
                Directory.CreateDirectory(Path.GetDirectoryName(t)!);
                File.Copy(f, t, true);
            }
            Directory.Delete(src, true);
        }
    }

    /// <summary>Writes/repairs our two proxy files. Call before every launch (cheap, idempotent):
    /// it also undoes r2modman/Gale overwriting them, and keeps Steam launches vanilla.</summary>
    public static void ApplyProxy(string gameDir, AppPaths paths, InstallState state)
    {
        var srcDll = Path.Combine(paths.LoaderStoreDir, ProxyDll);
        if (!File.Exists(srcDll)) throw new InvalidOperationException("BepInEx isn't installed in the profile yet.");
        var dstDll = Path.Combine(gameDir, ProxyDll);
        var wantHash = Downloader.Sha256OfFile(srcDll);
        if (!File.Exists(dstDll) || Downloader.Sha256OfFile(dstDll) != wantHash)
            File.Copy(srcDll, dstDll, true);
        state.GameDirFiles[ProxyDll] = wantHash;

        var iniText = BuildIni(paths.PreloaderPath);
        var dstIni = Path.Combine(gameDir, DoorstopIni);
        if (!File.Exists(dstIni) || File.ReadAllText(dstIni) != iniText)
            File.WriteAllText(dstIni, iniText, new UTF8Encoding(false));
        state.GameDirFiles[DoorstopIni] = Downloader.Sha256OfFile(dstIni);
    }

    /// <summary>Removes exactly what we put in the game folder. A file that no longer matches what we
    /// wrote (someone replaced it) is left alone and reported, never deleted blindly.</summary>
    public static List<string> RemoveProxy(string gameDir, InstallState state, AppPaths paths)
    {
        var leftBehind = new List<string>();
        foreach (var (name, hash) in state.GameDirFiles.ToList())
        {
            var f = Path.Combine(gameDir, name);
            if (!File.Exists(f)) { state.GameDirFiles.Remove(name); continue; }
            if (Downloader.Sha256OfFile(f) == hash)
            {
                File.Delete(f);
                state.GameDirFiles.Remove(name);
                paths.Log($"Removed {f}");
            }
            else leftBehind.Add(f);
        }
        return leftBehind;
    }
}
