using System.Text.Json;
using System.Text.Json.Serialization;

namespace PeakPack.Core;

/// <summary>
/// The pack manifest Joshua publishes. Friends' apps download this, verify it, and make their
/// profile match it exactly. It is pure data: there is deliberately no field that can make the
/// app run a script or a program.
/// </summary>
public sealed class PackManifest
{
    public const int CurrentSchema = 1;

    public int Schema { get; set; } = CurrentSchema;
    public string PackName { get; set; } = "PEAK mods";
    /// <summary>Monotonic counter, bumped on every publish. Shown to friends ("pack revision 7").</summary>
    public int Revision { get; set; }
    public DateTimeOffset Published { get; set; }
    public int GameAppId { get; set; } = SteamLocator.PeakAppId;
    /// <summary>Informational: PEAK build the host tested with (from the game's version.txt).</summary>
    public string? GameVersion { get; set; }
    /// <summary>Optional short note shown to friends ("Added HeliPilot!").</summary>
    public string? Notes { get; set; }

    /// <summary>Optional self-update info for the friend app.</summary>
    public AppRelease? App { get; set; }

    /// <summary>The BepInEx pack (from Thunderstore). Installed into the app's profile folder,
    /// and only its two proxy files (winhttp.dll + doorstop_config.ini) go into the game folder.</summary>
    public PackageEntry Loader { get; set; } = new();

    /// <summary>Thunderstore packages, already fully resolved (dependencies included) and pinned.</summary>
    public List<PackageEntry> Packages { get; set; } = new();

    /// <summary>Loose files hosted by Joshua (his own DLLs, config files).</summary>
    public List<FileEntry> Files { get; set; } = new();

    /// <summary>True if a player without these mods can't properly join the host's lobby (some mod is tagged
    /// "All Clients" on Thunderstore, or the host said so). The app uses it to warn before "Play normal PEAK".</summary>
    public bool ModsRequiredToJoin { get; set; }

    /// <summary>Mods the host runs that friends don't need (informational only, never installed).</summary>
    public List<string> HostOnly { get; set; } = new();

    // ---- v0.3 additions. All optional, so v0.2 apps (which ignore unknown fields) still read new manifests. ----

    /// <summary>Who runs the pack ("Joshua"). Shown to friends and in in-game notices.</summary>
    public string? HostName { get; set; }
    /// <summary>Stable identifier of the pack (lower-case slug). The in-game lobby check only compares
    /// revisions between players whose pack ids match.</summary>
    public string? PackId { get; set; }
    /// <summary>Most recent first; the publisher keeps the last 20 entries.</summary>
    public List<ChangelogEntry> Changelog { get; set; } = new();
    /// <summary>Settings for the in-game companion plugin (lobby revision check, live settings).</summary>
    public LobbySettings? Lobby { get; set; }

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static PackManifest Parse(string json)
    {
        var m = JsonSerializer.Deserialize<PackManifest>(json, JsonOptions)
                ?? throw new InvalidDataException("Manifest is empty.");
        m.Validate();
        return m;
    }

    public string ToJson() => JsonSerializer.Serialize(this, JsonOptions);

    /// <summary>Rejects anything malformed or unsafe before the installer touches the disk.</summary>
    public void Validate()
    {
        if (Schema > CurrentSchema)
            throw new InvalidDataException($"This pack needs a newer version of the app (manifest schema {Schema}). Please download the latest app from the host.");
        if (string.IsNullOrWhiteSpace(Loader.Id) || string.IsNullOrWhiteSpace(Loader.Url) || !IsSha256(Loader.Sha256))
            throw new InvalidDataException("Manifest loader entry is incomplete.");
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in Packages)
        {
            if (string.IsNullOrWhiteSpace(p.Id) || string.IsNullOrWhiteSpace(p.Url) || !IsSha256(p.Sha256))
                throw new InvalidDataException($"Manifest package entry '{p.Id}' is incomplete.");
            var pid = PackageId.Parse(p.Id);
            if (!ids.Add(pid.FullName))
                throw new InvalidDataException($"Package '{pid.FullName}' is listed twice.");
        }
        var dests = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in Files)
        {
            if (string.IsNullOrWhiteSpace(f.Url) || !IsSha256(f.Sha256))
                throw new InvalidDataException($"Manifest file entry '{f.Path}' is incomplete.");
            f.Path = SafePath.NormalizeRelative(f.Path); // throws on "..", rooted paths, etc.
            if (!SafePath.IsAllowedProfileDestination(f.Path))
                throw new InvalidDataException($"File '{f.Path}' must go under plugins/, patchers/ or config/.");
            if (!dests.Add(f.Path))
                throw new InvalidDataException($"File '{f.Path}' is listed twice.");
        }
        foreach (var ls in Lobby?.LiveSettings ?? [])
            if (string.IsNullOrWhiteSpace(ls.Plugin) || string.IsNullOrWhiteSpace(ls.Section) || string.IsNullOrWhiteSpace(ls.Key)
                || (ls.Plugin + ls.Section + ls.Key).IndexOfAny(BadSettingChars) >= 0)
                throw new InvalidDataException($"Live setting '{ls.Plugin}/{ls.Section}/{ls.Key}' is incomplete or has invalid characters.");
    }

    static readonly char[] BadSettingChars = ['|', '\n', '\r'];

    /// <summary>"Joshua's PEAK mods" -> "joshuas-peak-mods"</summary>
    public static string Slug(string s)
    {
        var chars = s.ToLowerInvariant().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray();
        var slug = string.Join('-', new string(chars).Split('-', StringSplitOptions.RemoveEmptyEntries));
        return slug.Length == 0 ? "pack" : slug.Length > 40 ? slug[..40] : slug;
    }

    public static bool IsSha256(string? s) =>
        s is { Length: 64 } && s.All(Uri.IsHexDigit);
}

public sealed class PackageEntry
{
    /// <summary>Thunderstore id with version: Namespace-Name-1.2.3</summary>
    public string Id { get; set; } = "";
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long Size { get; set; }
    /// <summary>"requested" for mods Joshua picked, otherwise which package pulled it in.</summary>
    public string? Reason { get; set; }
    /// <summary>Thunderstore categories at publish time (e.g. "All Clients", "Client Side"); informational.</summary>
    public List<string>? Tags { get; set; }
    /// <summary>Friendly name for the friend app ("Infinite Jetpack"). Optional.</summary>
    public string? Title { get; set; }
    /// <summary>One line: what it does / why it's in the pack. Optional.</summary>
    public string? Description { get; set; }

    [JsonIgnore] public bool IsHelper => Reason is not null && Reason != "requested";
}

public sealed class ChangelogEntry
{
    public int Revision { get; set; }
    public DateTimeOffset Date { get; set; }
    public string Notes { get; set; } = "";
}

public enum MismatchPolicy
{
    /// <summary>Show a notice; let the player stay.</summary>
    Warn,
    /// <summary>Show a notice, then leave the lobby after a few seconds (only for players on an OLDER revision).</summary>
    Block,
}

public sealed class LobbySettings
{
    public MismatchPolicy MismatchPolicy { get; set; } = MismatchPolicy.Warn;
    /// <summary>BepInEx config entries the lobby host's values apply to everyone while in that lobby.
    /// Only entries listed here are ever accepted from the network.</summary>
    public List<LiveSetting> LiveSettings { get; set; } = new();
}

public sealed class LiveSetting
{
    /// <summary>BepInEx plugin GUID, e.g. com.joshua.jetpackboost</summary>
    public string Plugin { get; set; } = "";
    public string Section { get; set; } = "";
    public string Key { get; set; } = "";
}

public enum OverwriteMode
{
    /// <summary>Always make the file match the manifest (DLLs, enforced configs).</summary>
    Always,
    /// <summary>Only write if the friend doesn't have the file yet (default configs they may tweak).</summary>
    IfMissing,
}

public sealed class FileEntry
{
    /// <summary>Logical owner, e.g. "Joshua-HeliPilot". Used for display and cleanup.</summary>
    public string Id { get; set; } = "";
    public string? Version { get; set; }
    /// <summary>Destination relative to the profile's BepInEx folder, e.g. plugins/Joshua-HeliPilot/HeliPilot.dll</summary>
    public string Path { get; set; } = "";
    /// <summary>Absolute https URL, or a path relative to the manifest's own URL.</summary>
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long Size { get; set; }
    public OverwriteMode Overwrite { get; set; } = OverwriteMode.Always;
    public string? Title { get; set; }
    public string? Description { get; set; }
}

public sealed class AppRelease
{
    public string Version { get; set; } = "0.0.0";
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long Size { get; set; }
}
