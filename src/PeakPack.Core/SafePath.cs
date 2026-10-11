namespace PeakPack.Core;

/// <summary>Path hygiene for everything that comes from a manifest or a zip (zip-slip protection).</summary>
public static class SafePath
{
    static readonly string[] AllowedRoots = ["plugins/", "patchers/", "config/"];

    /// <summary>Normalizes to forward slashes and rejects rooted paths, drive letters, "..", empty segments.</summary>
    public static string NormalizeRelative(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new InvalidDataException("Empty path.");
        var p = path.Replace('\\', '/').Trim();
        if (p.StartsWith('/') || p.Contains(':') || p.Contains('\0'))
            throw new InvalidDataException($"Unsafe path '{path}'.");
        var segs = p.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segs.Length == 0 || segs.Any(s => s is "." or ".." || s.EndsWith('.') || s.EndsWith(' ')))
            throw new InvalidDataException($"Unsafe path '{path}'.");
        return string.Join('/', segs);
    }

    public static bool IsAllowedProfileDestination(string normalized) =>
        AllowedRoots.Any(r => normalized.StartsWith(r, StringComparison.OrdinalIgnoreCase)) &&
        normalized.Split('/').Length >= 2;

    /// <summary>Combines and verifies the result stays inside root.</summary>
    public static string Combine(string root, string relative)
    {
        var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(Path.Combine(rootFull, NormalizeRelative(relative).Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Path '{relative}' escapes '{root}'.");
        return full;
    }
}
