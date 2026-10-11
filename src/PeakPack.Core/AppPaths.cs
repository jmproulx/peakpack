using System.Text.Json;

namespace PeakPack.Core;

/// <summary>Where the app keeps things. Everything lives in one per-user folder (no admin rights needed):
///   %LOCALAPPDATA%\PeakPack\
///     PeakPack.exe        the app itself (copied here on first run; shortcuts point here)
///     profile\BepInEx\    BepInEx + mods - this is the "modded game", kept OUTSIDE the game folder
///     cache\              downloaded zips, named by SHA-256
///     state.json          what is installed, which files we put in the game folder, last launch
///     log.txt             plain-text log for troubleshooting
/// </summary>
public sealed class AppPaths
{
    public const string AppName = "PeakPack";

    public string DataDir { get; }
    public string ProfileDir => Path.Combine(DataDir, "profile");
    public string BepInExDir => Path.Combine(ProfileDir, "BepInEx");
    public string PreloaderPath => Path.Combine(BepInExDir, "core", "BepInEx.Preloader.dll");
    public string LoaderStoreDir => Path.Combine(ProfileDir, "loader"); // pristine winhttp.dll/doorstop_config.ini
    public string CacheDir => Path.Combine(DataDir, "cache");
    public string StatePath => Path.Combine(DataDir, "state.json");
    public string LogPath => Path.Combine(DataDir, "log.txt");
    public string InstalledExePath => Path.Combine(DataDir, AppName + ".exe");
    /// <summary>Backups of anything we move out of the game folder. Deliberately NOT inside DataDir,
    /// so "Remove everything" never deletes a friend's pre-existing files.</summary>
    public string BackupRoot => Path.Combine(Path.GetDirectoryName(DataDir.TrimEnd('\\', '/'))!, AppName + "-backups");

    public AppPaths(string? dataDirOverride = null)
    {
        DataDir = Path.GetFullPath(dataDirOverride ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName));
    }

    public bool IsDefaultLocation =>
        DataDir.Equals(Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName)), StringComparison.OrdinalIgnoreCase);

    public void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch { /* logging must never break the app */ }
    }
}

public enum LaunchMode { Modded, Vanilla }

public sealed class InstallState
{
    public string? GameDir { get; set; }
    public string? ManifestUrl { get; set; }
    public int InstalledRevision { get; set; }
    public string? PackName { get; set; }
    public bool ModsRequiredToJoin { get; set; }
    /// <summary>PEAK build the host published this pack with (manifest.gameVersion).</summary>
    public string? PackGameVersion { get; set; }
    public string? LoaderId { get; set; }
    /// <summary>BepInEx core files written by the loader, relative to BepInEx/.</summary>
    public List<string> LoaderFiles { get; set; } = new();
    /// <summary>Package id (Namespace-Name-ver) -> files we wrote, relative to BepInEx/.</summary>
    public Dictionary<string, List<string>> Packages { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>Loose manifest files we wrote: relative path -> sha256.</summary>
    public Dictionary<string, string> Files { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>Files we placed in the GAME folder: file name -> sha256 of what we wrote.
    /// Uninstall only deletes a file if it still has this hash (so we never delete someone else's file).</summary>
    public Dictionary<string, string> GameDirFiles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string? BackupDir { get; set; }
    public LaunchMode? LastLaunchMode { get; set; }
    public DateTimeOffset? LastLaunchTime { get; set; }
    public DateTimeOffset? LastSyncTime { get; set; }

    public static InstallState Load(AppPaths p)
    {
        try
        {
            if (File.Exists(p.StatePath))
                return JsonSerializer.Deserialize<InstallState>(File.ReadAllText(p.StatePath), PackManifest.JsonOptions) ?? new();
        }
        catch (Exception ex) { p.Log("state.json unreadable, starting fresh: " + ex.Message); }
        return new();
    }

    public void Save(AppPaths p)
    {
        Directory.CreateDirectory(p.DataDir);
        var tmp = p.StatePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, PackManifest.JsonOptions));
        File.Move(tmp, p.StatePath, true);
    }
}
