namespace PeakPack.Core;

/// <summary>
/// Plain-language differences between two pack revisions ("Added Infinite Jetpack 1.0.1", "JetpackBoost: new build").
/// Used by the publisher output, the Host view's preview, and the friend app's "Update available: 2 mods changed".
/// Joshua's files are grouped by their id (a mod with a DLL and a config is one item).
/// </summary>
public static class PackDiff
{
    public enum Kind { Added, Removed, Updated }

    public sealed record Item(string Key, string Title, string Version, bool IsHelper, bool IsOwnBuild);

    public sealed record Change(Kind Kind, string Title, string? From, string? To, bool IsHelper, bool IsOwnBuild)
    {
        public override string ToString() => Kind switch
        {
            Kind.Added => $"+ {Title} {To}".TrimEnd(),
            Kind.Removed => $"- {Title} {From}".TrimEnd(),
            _ => IsOwnBuild && From == To ? $"* {Title}: new build" : $"* {Title} {From} -> {To}",
        };

        /// <summary>For friends: "Added Infinite Jetpack", "Updated JetpackBoost (new build)".</summary>
        public string Friendly => Kind switch
        {
            Kind.Added => $"Added {Title}",
            Kind.Removed => $"Removed {Title}",
            _ => IsOwnBuild && From == To ? $"Updated {Title} (new build)" : $"Updated {Title} to {To}",
        };
    }

    public static List<Item> Items(PackManifest? m)
    {
        var list = new List<Item>();
        if (m is null) return list;
        list.Add(new Item("loader", "BepInEx (mod loader)", PackageId.Parse(m.Loader.Id).Version?.ToString(3) ?? "", true, false));
        foreach (var p in m.Packages)
        {
            var id = PackageId.Parse(p.Id);
            list.Add(new Item(id.FullName, p.Title ?? ThunderstoreIndex.Friendly(id.Name), id.Version?.ToString(3) ?? "", p.IsHelper, false));
        }
        foreach (var g in m.Files.GroupBy(f => f.Id, StringComparer.OrdinalIgnoreCase))
        {
            var first = g.First();
            // Content fingerprint: changes whenever any of the mod's always-enforced files changes.
            var fp = string.Join(",", g.Where(f => f.Overwrite == OverwriteMode.Always).OrderBy(f => f.Path).Select(f => f.Sha256[..8]));
            list.Add(new Item("file:" + g.Key + "#" + fp, first.Title ?? g.Key, first.Version ?? "", false, true));
        }
        return list;
    }

    public static List<Change> Compare(PackManifest? before, PackManifest after)
    {
        var a = Items(before);
        var b = Items(after);
        string BaseKey(Item i) => i.Key.Split('#')[0];
        var changes = new List<Change>();
        var aByKey = a.GroupBy(BaseKey, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var bByKey = b.GroupBy(BaseKey, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        foreach (var (k, nb) in bByKey)
        {
            if (!aByKey.TryGetValue(k, out var na))
            {
                if (before is not null || k != "loader") changes.Add(new Change(Kind.Added, nb.Title, null, nb.Version, nb.IsHelper, nb.IsOwnBuild));
            }
            else if (na.Key != nb.Key || na.Version != nb.Version)
                changes.Add(new Change(Kind.Updated, nb.Title, na.Version, nb.Version, nb.IsHelper, nb.IsOwnBuild));
        }
        foreach (var (k, na) in aByKey)
            if (!bByKey.ContainsKey(k)) changes.Add(new Change(Kind.Removed, na.Title, na.Version, null, na.IsHelper, na.IsOwnBuild));
        return changes.OrderBy(c => c.IsHelper).ThenBy(c => c.Kind).ThenBy(c => c.Title, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>"2 mods changed" / "1 mod changed and helper libraries updated" / "helper libraries updated".</summary>
    public static string Summary(IReadOnlyCollection<Change> changes)
    {
        int mods = changes.Count(c => !c.IsHelper);
        bool helpers = changes.Any(c => c.IsHelper);
        if (mods == 0) return helpers ? "helper libraries updated" : "no changes";
        var s = mods == 1 ? "1 mod changed" : $"{mods} mods changed";
        return helpers ? s + " and helper libraries updated" : s;
    }
}
