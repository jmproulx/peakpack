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
    /// <summary>Per-platform additions (signed like the rest). Only "mac" so far: friends running PeakPack inside
    /// our Wine prefix on macOS (MacPort Track D). Windows ignores it.</summary>
    public PlatformSettings? Platforms { get; set; }

    // ---- v0.6 additions (mac/app/proposals/friendinstaller-platforms-mac.md). Optional and additive: apps that don't
    // know them (every Windows PeakPack up to 0.4.2, older Mac front ends) skip unknown members. ----

    /// <summary>The PEAK depot build the host's own game was on when this revision was published (read from his
    /// steamapps/appmanifest_&lt;appid&gt;.acf). Informational: the Mac front end uses it to say "PEAK has an update".
    /// Windows PeakPack never acts on it.</summary>
    public GameDepot? GameDepot { get; set; }

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
        if (Platforms?.Mac is { } mac)
        {
            foreach (var a in mac.ExtraArgs)
                if (string.IsNullOrWhiteSpace(a) || !a.StartsWith('-') || a.Contains("doorstop", StringComparison.OrdinalIgnoreCase) || a.IndexOfAny(['"', '\n', '\r']) >= 0)
                    throw new InvalidDataException($"Mac launch argument '{a}' isn't allowed.");
            var macDests = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var f in mac.Files)
            {
                if (string.IsNullOrWhiteSpace(f.Url) || !IsSha256(f.Sha256))
                    throw new InvalidDataException($"Mac file entry '{f.Path}' is incomplete.");
                f.Path = SafePath.NormalizeRelative(f.Path);
                bool isConfig = f.Path.StartsWith("config/", StringComparison.OrdinalIgnoreCase);
                bool isPlugin = f.Path.StartsWith("plugins/", StringComparison.OrdinalIgnoreCase) && f.Path.Split('/').Length >= 3;
                if (!(isConfig && f.Path.Split('/').Length >= 2) && !isPlugin)
                    throw new InvalidDataException($"Mac file '{f.Path}' must go under config/ or plugins/<folder>/.");
                if (isConfig) f.Overwrite = OverwriteMode.IfMissing; // never overwrite a friend's own settings
                f.HotReload = false;                                  // Mac-only files change only with a restart
                if (isPlugin && Files.Any(w => w.Path.Equals(f.Path, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidDataException($"Mac plugin file '{f.Path}' also exists for every platform.");
                if (!macDests.Add(f.Path)) throw new InvalidDataException($"Mac file '{f.Path}' is listed twice.");
            }
            // runtime / frontEnd are deliberately NOT checked here (nor gameDepot below): they are for the Mac front end,
            // which applies the same rules and falls back to its embedded pin. A bad pin must never stop a Windows
            // friend's sync. The publisher refuses them instead (ValidateForPublish).
        }
        foreach (var ls in Lobby?.LiveSettings ?? [])
            if (string.IsNullOrWhiteSpace(ls.Plugin) || string.IsNullOrWhiteSpace(ls.Section) || string.IsNullOrWhiteSpace(ls.Key)
                || (ls.Plugin + ls.Section + ls.Key).IndexOfAny(BadSettingChars) >= 0)
                throw new InvalidDataException($"Live setting '{ls.Plugin}/{ls.Section}/{ls.Key}' is incomplete or has invalid characters.");
    }

    /// <summary>Validate() plus the rules for the optional Mac pins and gameDepot. The publisher calls this and refuses
    /// to publish on any problem; friends' apps only call Validate() (see the comment there).</summary>
    public void ValidateForPublish()
    {
        Validate();
        var problems = PinProblems();
        if (problems.Count > 0) throw new InvalidDataException(string.Join(" ", problems));
    }

    /// <summary>Every rule violation in platforms.mac.runtime, platforms.mac.frontEnd and gameDepot (empty = fine or absent).</summary>
    public List<string> PinProblems()
    {
        var p = new List<string>();
        if (Platforms?.Mac?.Runtime is { } rt) p.AddRange(rt.Problems());
        if (Platforms?.Mac?.FrontEnd is { } fe) p.AddRange(fe.Problems());
        if (GameDepot is { } gd)
        {
            p.AddRange(gd.Problems());
            if (gd.AppId != GameAppId) p.Add($"gameDepot.appId {gd.AppId} isn't the pack's game ({GameAppId}).");
        }
        return p;
    }

    static readonly char[] BadSettingChars = ['|', '\n', '\r'];

    /// <summary>"Joshua's PEAK mods" -> "joshuas-peak-mods"</summary>
    public static string Slug(string s)
    {
        var chars = s.Replace("'", "").Replace("’", "").ToLowerInvariant().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray();
        var slug = string.Join('-', new string(chars).Split('-', StringSplitOptions.RemoveEmptyEntries));
        return slug.Length == 0 ? "pack" : slug.Length > 40 ? slug[..40] : slug;
    }

    /// <summary>The loose files to install on this platform: on Mac, the Mac config defaults replace (same path) or add to
    /// the Windows ones.</summary>
    public List<FileEntry> FilesFor(Platform.Kind platform)
    {
        if (platform != Platform.Kind.WineMac || Platforms?.Mac?.Files is not { Count: > 0 } mac) return Files;
        var macPaths = mac.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return Files.Where(f => !macPaths.Contains(f.Path)).Concat(mac).ToList();
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
    /// <summary>Test lobby: friends who opted in get new builds of Joshua's reload-safe mods applied live
    /// (AutoReload is added to the pack). Off by default.</summary>
    public bool TestLobby { get; set; }
    /// <summary>The host wants friends' error logs relayed while they're in his lobby (each friend still decides).</summary>
    public bool Diagnostics { get; set; } = true;
    /// <summary>Photon user ids of the pack's host(s) (Joshua). Friends relay logs and accept live-update signals only
    /// from a lobby host on this list. Empty = pack id match only (weaker; the publisher fills it from the host's game).</summary>
    public List<string> HostIds { get; set; } = new();
}

public sealed class PlatformSettings
{
    public MacSettings? Mac { get; set; }
}

public sealed class MacSettings
{
    /// <summary>Extra game arguments on Mac, e.g. "-force-d3d11" (the DXMT path). Never Doorstop arguments.</summary>
    public List<string> ExtraArgs { get; set; } = new();
    /// <summary>Mac-only files. Under config/: Mac defaults for friends' config files (laptop-friendly keys...), always
    /// "ifMissing", so a friend's own changes are never overwritten; same path as a Windows file = replaces it on Mac.
    /// Under plugins/&lt;folder&gt;/: Mac-only plugins (e.g. PeakPack.MacPreset), enforced like any pack file and never
    /// installed on Windows.</summary>
    public List<FileEntry> Files { get; set; } = new();
    /// <summary>Lowest Mac front-end version that understands this pack (informational for the front end).</summary>
    public string? MinFrontEnd { get; set; }
    /// <summary>Optional signed pin of the Wine runtime the Mac front end should use (from a mac-build-runtime-*
    /// prerelease's SHA256SUMS). Absent = the front end keeps its embedded pin.</summary>
    public RuntimePin? Runtime { get; set; }
    /// <summary>Optional signed pin of the Mac front end's self-update (from a mac-build-app-* prerelease's
    /// SHA256SUMS). Absent = the front end uses the newest mac-build-app-* prerelease.</summary>
    public FrontEndPin? FrontEnd { get; set; }
}

/// <summary>platforms.mac.runtime: { id, tag, asset, sha256, size }.</summary>
public sealed class RuntimePin
{
    public const string TagPrefix = "mac-build-runtime-";
    public string Id { get; set; } = "";
    public string Tag { get; set; } = "";
    public string Asset { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long? Size { get; set; }

    /// <summary>The asset name the runtime workflow gives a runtime id.</summary>
    public static string AssetFor(string id) => $"peakpack-runtime-{id}-x86_64.tar.xz";

    static readonly System.Text.RegularExpressions.Regex IdRx = new(@"^pp[0-9]+-cx[0-9.]+$");
    public static bool IsValidId(string? id) => id is not null && IdRx.IsMatch(id);

    /// <summary>The proposal's rules (the Mac front end's RuntimePin.isWellFormed), plus size &gt; 0 when present.</summary>
    public List<string> Problems()
    {
        var p = new List<string>();
        if (!IsValidId(Id)) p.Add($"platforms.mac.runtime.id '{Id}' must look like pp<N>-cx<version>.");
        if (Tag != TagPrefix + Id) p.Add($"platforms.mac.runtime.tag '{Tag}' must be '{TagPrefix}{Id}'.");
        if (!Asset.EndsWith(".tar.xz", StringComparison.Ordinal) || Asset.IndexOfAny(['/', '\\']) >= 0)
            p.Add($"platforms.mac.runtime.asset '{Asset}' must be a plain .tar.xz file name.");
        if (!PackManifest.IsSha256(Sha256)) p.Add("platforms.mac.runtime.sha256 must be 64 hex characters.");
        if (Size is <= 0) p.Add("platforms.mac.runtime.size must be positive.");
        return p;
    }
}

/// <summary>platforms.mac.frontEnd: { version, tag, zip, sha256 }.</summary>
public sealed class FrontEndPin
{
    public const string TagPrefix = "mac-build-app-";
    public const string ZipPrefix = "PEAK-Modded-Mac-";
    public string Version { get; set; } = "";
    public string Tag { get; set; } = "";
    public string Zip { get; set; } = "";
    public string Sha256 { get; set; } = "";

    public static string ZipFor(string version) => $"{ZipPrefix}{version}.zip";

    // Same shape the Mac front end's DottedVersion accepts: numbers separated by dots, optional "-suffix".
    static readonly System.Text.RegularExpressions.Regex VersionRx = new(@"^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$");
    public static bool IsValidVersion(string? v) => v is not null && VersionRx.IsMatch(v);

    public List<string> Problems()
    {
        var p = new List<string>();
        if (!IsValidVersion(Version)) p.Add($"platforms.mac.frontEnd.version '{Version}' isn't a dotted version.");
        if (Tag != TagPrefix + Version) p.Add($"platforms.mac.frontEnd.tag '{Tag}' must be '{TagPrefix}{Version}'.");
        if (!Zip.EndsWith(".zip", StringComparison.Ordinal) || Zip.IndexOfAny(['/', '\\']) >= 0)
            p.Add($"platforms.mac.frontEnd.zip '{Zip}' must be a plain .zip file name.");
        if (!PackManifest.IsSha256(Sha256)) p.Add("platforms.mac.frontEnd.sha256 must be 64 hex characters.");
        return p;
    }
}

/// <summary>gameDepot: { appId, depotId, manifestId, buildId } of the host's own PEAK install. Ids are decimal strings
/// (depot manifest gids don't fit every JSON reader's number type).</summary>
public sealed class GameDepot
{
    public int AppId { get; set; }
    public int DepotId { get; set; }
    public string ManifestId { get; set; } = "";
    public string BuildId { get; set; } = "";

    static bool IsDecimalId(string? s) => s is { Length: > 0 and <= 20 } && s.All(char.IsAsciiDigit) && ulong.TryParse(s, out var v) && v > 0;

    public List<string> Problems()
    {
        var p = new List<string>();
        if (AppId <= 0) p.Add("gameDepot.appId must be positive.");
        if (DepotId <= 0) p.Add("gameDepot.depotId must be positive.");
        if (!IsDecimalId(ManifestId)) p.Add($"gameDepot.manifestId '{ManifestId}' must be a decimal id.");
        if (!IsDecimalId(BuildId)) p.Add($"gameDepot.buildId '{BuildId}' must be a decimal id.");
        return p;
    }
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
    /// <summary>Joshua's own mod that supports AutoReload (full OnDestroy cleanup, embedded PDB). In a test lobby,
    /// friends who opted in get new builds of it applied live. Never set for third-party files.</summary>
    public bool HotReload { get; set; }
}

public sealed class AppRelease
{
    public string Version { get; set; } = "0.0.0";
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public long Size { get; set; }
}
