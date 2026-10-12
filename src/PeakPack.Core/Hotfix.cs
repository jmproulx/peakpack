using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// Host-side commands for the companion in the HOST's own game: small JSON files dropped into
/// &lt;host BepInEx&gt;\PeakPack\commands\. The host's companion picks them up (about once a second while hosting)
/// and turns them into Photon events for the lobby. This is how the CLI, the Host window and agents talk to the
/// running game without any network port or IPC.
/// </summary>
public static class LobbyCommands
{
    public const string Snapshot = "snapshot", HotUpdate = "hot-update";

    public static string Dir(string bepInExDir) => Path.Combine(bepInExDir, "PeakPack", "commands");

    /// <summary>Folder where the host's companion writes friends' relayed logs.</summary>
    public static string RemoteLogsDir(string bepInExDir) => Path.Combine(bepInExDir, "PeakPack-remote-logs");

    public static string Write(string bepInExDir, string command, int revision = 0)
    {
        if (!Directory.Exists(bepInExDir)) throw new DirectoryNotFoundException($"No BepInEx folder at {bepInExDir}");
        var dir = Dir(bepInExDir);
        Directory.CreateDirectory(dir);
        var id = DateTime.UtcNow.ToString("yyyyMMddHHmmssfff") + "-" + command;
        var path = Path.Combine(dir, id + ".json");
        var json = JsonSerializer.Serialize(new { command, revision, id, time = DateTimeOffset.Now }, PackManifest.JsonOptions);
        File.WriteAllText(path + ".tmp", json, new UTF8Encoding(false));
        File.Move(path + ".tmp", path, true);
        return path;
    }
}

/// <summary>Helpers for "hotfix": publishing a new build of one of the host's own mods as a normal pack release.</summary>
public static class Hotfix
{
    public sealed record DllCheck(bool IsManaged, bool HasEmbeddedPdb, bool HasOnDestroy, string? PluginGuid, string? PluginName,
        string? PluginVersion, List<string> Problems)
    {
        /// <summary>What AutoReload needs: a BepInEx plugin class with OnDestroy, and symbols embedded in the DLL.</summary>
        public bool LiveReloadOk => IsManaged && HasEmbeddedPdb && HasOnDestroy && PluginGuid is not null;
    }

    /// <summary>Reads the DLL's metadata (no loading): BepInPlugin attribute, OnDestroy on the plugin class, embedded PDB.</summary>
    public static DllCheck Inspect(string dll)
    {
        var problems = new List<string>();
        try
        {
            using var fs = File.OpenRead(dll);
            using var pe = new PEReader(fs);
            if (!pe.HasMetadata) return new(false, false, false, null, null, null, ["Not a .NET assembly."]);
            bool pdb = pe.ReadDebugDirectory().Any(d => d.Type == DebugDirectoryEntryType.EmbeddedPortablePdb);
            var md = pe.GetMetadataReader();
            string? guid = null, name = null, version = null;
            bool onDestroy = false;
            foreach (var th in md.TypeDefinitions)
            {
                var t = md.GetTypeDefinition(th);
                if (t.BaseType.Kind != HandleKind.TypeReference) continue;
                var bt = md.GetTypeReference((TypeReferenceHandle)t.BaseType);
                if (md.GetString(bt.Name) != "BaseUnityPlugin") continue;
                onDestroy |= t.GetMethods().Any(m => md.GetString(md.GetMethodDefinition(m).Name) == "OnDestroy");
                foreach (var ah in t.GetCustomAttributes())
                {
                    var a = md.GetCustomAttribute(ah);
                    if (AttributeName(md, a) != "BepInPlugin") continue;
                    var br = md.GetBlobReader(a.Value);
                    if (br.ReadUInt16() != 1) continue; // prolog
                    guid = br.ReadSerializedString(); name = br.ReadSerializedString(); version = br.ReadSerializedString();
                }
            }
            if (guid is null) problems.Add("No [BepInPlugin] class found.");
            if (!onDestroy) problems.Add("The plugin class has no OnDestroy (AutoReload can't unload it cleanly).");
            if (!pdb) problems.Add("No embedded PDB (<DebugType>embedded</DebugType>); AutoReload needs it.");
            return new(true, pdb, onDestroy, guid, name, version, problems);
        }
        catch (BadImageFormatException) { return new(false, false, false, null, null, null, ["Not a .NET assembly."]); }
    }

    static string? AttributeName(MetadataReader md, CustomAttribute a)
    {
        if (a.Constructor.Kind == HandleKind.MemberReference)
        {
            var mr = md.GetMemberReference((MemberReferenceHandle)a.Constructor);
            if (mr.Parent.Kind == HandleKind.TypeReference)
            {
                var n = md.GetString(md.GetTypeReference((TypeReferenceHandle)mr.Parent).Name);
                return n.EndsWith("Attribute") ? n[..^9] : n;
            }
        }
        return null;
    }

    /// <summary>Finds an own build by id ("Joshua-ScoutmasterMode"), short name ("ScoutmasterMode"), title or DLL name.</summary>
    public static PublishConfig.CustomFile? FindMod(PublishConfig cfg, string mod)
    {
        static string N(string s) => new string(s.Where(char.IsAsciiLetterOrDigit).ToArray()).ToLowerInvariant();
        var key = N(mod);
        return cfg.CustomFiles.Where(c => c.Dest.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).FirstOrDefault(c =>
            N(c.Id) == key || N(c.Id.Contains('-') ? c.Id[(c.Id.IndexOf('-') + 1)..] : c.Id) == key
            || (c.Title is not null && N(c.Title) == key) || N(Path.GetFileNameWithoutExtension(c.Dest)) == key);
    }

    /// <summary>"0.1.0" -> "0.1.1"; anything unparsable -> "1.0.1".</summary>
    public static string BumpVersion(string? v) =>
        Version.TryParse(v, out var x) ? new Version(x.Major, x.Minor, Math.Max(0, x.Build) + 1).ToString(3) : "1.0.1";

    /// <summary>The build friends had before the current one (for --rollback): searches &lt;work&gt;\history\rev-N
    /// newest first for a different SHA-256 of this mod's DLL than the current release.</summary>
    public static string? PreviousBuild(string workDir, PublishConfig.CustomFile cf)
    {
        var hist = Path.Combine(workDir, "history");
        if (!Directory.Exists(hist)) return null;
        var revs = Directory.GetDirectories(hist, "rev-*")
            .Select(d => (Dir: d, N: int.TryParse(Path.GetFileName(d)[4..], out var n) ? n : -1)).Where(x => x.N > 0)
            .OrderByDescending(x => x.N).ToList();
        string? current = null;
        foreach (var (dir, _) in revs)
        {
            var mf = Path.Combine(dir, "manifest.json");
            if (!File.Exists(mf)) continue;
            var f = PackManifest.Parse(File.ReadAllText(mf)).Files.FirstOrDefault(x => x.Path.Equals(cf.Dest, StringComparison.OrdinalIgnoreCase));
            if (f is null) continue;
            current ??= f.Sha256;
            if (!f.Sha256.Equals(current, StringComparison.OrdinalIgnoreCase))
            {
                var asset = Path.Combine(dir, f.Url.Split('/')[^1]);
                if (File.Exists(asset)) return asset;
            }
        }
        return null;
    }
}
