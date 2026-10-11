namespace PeakPack.Core;

/// <summary>Thunderstore package id "Namespace-Name[-Major.Minor.Patch]". Names never contain '-'.</summary>
public readonly record struct PackageId(string Namespace, string Name, Version? Version)
{
    public string FullName => $"{Namespace}-{Name}";
    public override string ToString() => Version is null ? FullName : $"{FullName}-{Version.ToString(3)}";

    public static PackageId Parse(string s)
    {
        var parts = s.Trim().Split('-');
        if (parts.Length is < 2 or > 3 || parts.Any(p => p.Length == 0 || !p.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.')))
            throw new FormatException($"'{s}' is not a Thunderstore id like Namespace-Name-1.2.3");
        Version? v = null;
        if (parts.Length == 3)
        {
            if (!System.Version.TryParse(parts[2], out v) || v.Build < 0)
                throw new FormatException($"'{s}' has an invalid version (expected Major.Minor.Patch)");
        }
        else if (parts[1].Contains('.'))
            throw new FormatException($"'{s}' is not a Thunderstore id");
        return new PackageId(parts[0], parts[1], v);
    }

    /// <summary>Any BepInExPack variant (BepInEx-BepInExPack, BepInEx-BepInExPack_PEAK, ...) is "the loader".
    /// Some PEAK mods still declare the generic BepInExPack; we always substitute the PEAK pack.</summary>
    public bool IsLoader =>
        Namespace.Equals("BepInEx", StringComparison.OrdinalIgnoreCase) &&
        Name.StartsWith("BepInExPack", StringComparison.OrdinalIgnoreCase);
}
