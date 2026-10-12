using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// The small file the in-game companion plugin reads: &lt;BepInEx root&gt;\PeakPack\pack-info.json.
/// Written by every sync and whenever the friend changes an option in the app (friends), and by the publisher's
/// "stamp" step into the host's own BepInEx folder, so the host's game broadcasts the revision friends should have.
/// Keep this format flat: the companion parses it with Unity's JsonUtility (no Newtonsoft inside PEAK).
/// </summary>
public sealed class PackInfo
{
    public int Schema { get; set; } = 2;
    public string PackId { get; set; } = "";
    public string PackName { get; set; } = "";
    public string HostName { get; set; } = "";
    public int Revision { get; set; }
    public DateTimeOffset Published { get; set; }
    public string ShortcutName { get; set; } = "PEAK (Modded)";
    public bool ModsRequiredToJoin { get; set; }
    public MismatchPolicy MismatchPolicy { get; set; } = MismatchPolicy.Warn;
    /// <summary>"pluginGuid|Section|Key" entries whose values follow the lobby host.</summary>
    public List<string> LiveSettings { get; set; } = new();

    // ---- v0.4: remote diagnostics and live updates ----

    /// <summary>Photon user ids of the pack host(s), from the signed manifest.</summary>
    public List<string> HostIds { get; set; } = new();
    /// <summary>Relay this player's error logs to the lobby host (pack allows it AND the friend consented).</summary>
    public bool Diagnostics { get; set; }
    /// <summary>Accept live updates of the host's reload-safe mods (pack is a test lobby AND the friend opted in).</summary>
    public bool LiveUpdates { get; set; }
    /// <summary>Plugin folders of the host's own mods ("plugins/Joshua-JetpackBoost"): their log lines are relayed in full.</summary>
    public List<string> OwnModFolders { get; set; } = new();
    /// <summary>"folder|Title" of the host's reload-safe mods, for notices ("Joshua updated Jetpack Boost").</summary>
    public List<string> HotMods { get; set; } = new();
    /// <summary>The installed PeakPack.exe and its arguments; the companion starts it with --hot-update.</summary>
    public string AppExe { get; set; } = "";
    public List<string> AppArgs { get; set; } = new();

    public static string PathIn(string bepInExDir) => Path.Combine(bepInExDir, "PeakPack", "pack-info.json");

    static string Folder(string path) { var s = path.Split('/'); return s.Length >= 2 ? s[0] + "/" + s[1] : path; }

    public static PackInfo From(PackManifest m, string shortcutName, InstallState? state = null, AppPaths? paths = null)
    {
        var info = new PackInfo
        {
            PackId = m.PackId ?? PackManifest.Slug(m.PackName),
            PackName = m.PackName,
            HostName = m.HostName ?? "the host",
            Revision = m.Revision,
            Published = m.Published,
            ShortcutName = shortcutName,
            ModsRequiredToJoin = m.ModsRequiredToJoin,
            MismatchPolicy = m.Lobby?.MismatchPolicy ?? MismatchPolicy.Warn,
            LiveSettings = (m.Lobby?.LiveSettings ?? []).Select(l => $"{l.Plugin}|{l.Section}|{l.Key}").ToList(),
            HostIds = (m.Lobby?.HostIds ?? []).ToList(),
            Diagnostics = (m.Lobby?.Diagnostics ?? true) && (state?.ShareDiagnostics ?? false),
            LiveUpdates = m.Lobby?.TestLobby == true && (state?.AcceptLiveUpdates ?? false),
            OwnModFolders = m.Files.Where(f => f.Id != PublishConfig.CompanionId && f.Path.StartsWith("plugins/", StringComparison.OrdinalIgnoreCase))
                .Select(f => Folder(f.Path)).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
            HotMods = m.Files.Where(f => f.HotReload).GroupBy(f => Folder(f.Path), StringComparer.OrdinalIgnoreCase)
                .Select(g => g.Key + "|" + (g.First().Title ?? PackDiff.FriendlyFileTitle(g.First().Id))).ToList(),
        };
        if (paths is not null && File.Exists(paths.InstalledExePath))
        {
            info.AppExe = paths.InstalledExePath;
            if (!paths.IsDefaultLocation) info.AppArgs = ["--data-dir", paths.DataDir];
        }
        return info;
    }

    /// <summary>Rewrites pack-info.json from the installed manifest and the friend's current options (after the friend
    /// toggles an option in the app, or after a live update). No-op if nothing is installed.</summary>
    public static void Refresh(AppPaths paths, string shortcutName)
    {
        var m = Installer.LoadInstalledManifest(paths);
        if (m is null) return;
        From(m, shortcutName, InstallState.Load(paths), paths).Save(paths.PackInfoPath);
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, PackManifest.JsonOptions), new UTF8Encoding(false));
        File.Move(tmp, path, true); // atomic: the companion polls this file
    }

    public static PackInfo? Load(string path) =>
        File.Exists(path) ? JsonSerializer.Deserialize<PackInfo>(File.ReadAllText(path), PackManifest.JsonOptions) : null;
}
