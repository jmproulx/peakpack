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

    /// <summary>Mods the host runs that friends don't need (informational only, never installed).</summary>
    public List<string> HostOnly { get; set; } = new();

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
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
}

public sealed class AppRelease
{
    public string Version { get; set; } = "0.0.0";
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long Size { get; set; }
}
