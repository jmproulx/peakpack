using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// The small file the in-game companion plugin reads: &lt;BepInEx root&gt;\PeakPack\pack-info.json.
/// Written by every sync (friends), and by the publisher's "stamp" step into the host's own BepInEx folder,
/// so the host's game broadcasts the revision friends should have. Keep this format flat and stable:
/// the companion parses it with a tiny hand-written JSON reader (no Newtonsoft dependency inside PEAK).
/// </summary>
public sealed class PackInfo
{
    public int Schema { get; set; } = 1;
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

    public static string PathIn(string bepInExDir) => Path.Combine(bepInExDir, "PeakPack", "pack-info.json");

    public static PackInfo From(PackManifest m, string shortcutName) => new()
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
    };

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, PackManifest.JsonOptions), new UTF8Encoding(false));
    }

    public static PackInfo? Load(string path) =>
        File.Exists(path) ? JsonSerializer.Deserialize<PackInfo>(File.ReadAllText(path), PackManifest.JsonOptions) : null;
}
