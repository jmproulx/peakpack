using System.IO.Compression;

namespace PeakPack.Core;

/// <summary>
/// Maps files inside a Thunderstore zip to paths under the profile's BepInEx folder, following
/// r2modman's BepInEx install rules (src/assets/data/ecosystem.json in ebkr/r2modmanPlus):
///   plugins/*  -> BepInEx/plugins/&lt;Namespace-Name&gt;/   (default location for loose files)
///   patchers/* -> BepInEx/patchers/&lt;Namespace-Name&gt;/
///   core/*     -> BepInEx/core/&lt;Namespace-Name&gt;/
///   monomod/*  -> BepInEx/monomod/&lt;Namespace-Name&gt;/
///   config/*   -> BepInEx/config/ (no subfolder; only written if the file doesn't exist yet)
/// A leading "BepInEx/" in the zip is stripped first. Keeping each package in its own folder makes
/// removal trivial and exact.
/// </summary>
public static class PackageLayout
{
    public sealed record Planned(string ZipEntry, string Dest, bool IsConfig);

    static readonly string[] Routed = ["plugins", "patchers", "core", "monomod"];

    public static List<Planned> Plan(ZipArchive zip, string packageFullName)
    {
        var result = new List<Planned>();
        foreach (var e in zip.Entries)
        {
            if (e.FullName.EndsWith('/') || e.FullName.EndsWith('\\') || e.Length == 0 && e.Name.Length == 0) continue;
            var rel = SafePath.NormalizeRelative(e.FullName);
            if (rel.StartsWith("BepInEx/", StringComparison.OrdinalIgnoreCase)) rel = rel["BepInEx/".Length..];
            var slash = rel.IndexOf('/');
            var top = slash < 0 ? "" : rel[..slash];
            var rest = slash < 0 ? rel : rel[(slash + 1)..];

            if (top.Equals("config", StringComparison.OrdinalIgnoreCase))
            {
                result.Add(new Planned(e.FullName, "config/" + rest, true));
                continue;
            }
            var routed = Routed.FirstOrDefault(r => r.Equals(top, StringComparison.OrdinalIgnoreCase));
            if (routed is not null)
                result.Add(new Planned(e.FullName, $"{routed}/{packageFullName}/{rest}", false));
            else
                result.Add(new Planned(e.FullName, $"plugins/{packageFullName}/{rel}", false)); // loose files, manifest.json, icon, readme...
        }
        return result;
    }

    /// <summary>Folders a package owns exclusively (deleted wholesale on removal/upgrade).</summary>
    public static IEnumerable<string> OwnedDirs(string packageFullName) =>
        Routed.Select(r => $"{r}/{packageFullName}");
}
