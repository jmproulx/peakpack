using System.Text;
using Microsoft.Win32;

namespace PeakPack.Core;

/// <summary>
/// Read-only helpers for locating Steam, its library folders and installed games.
/// Methods return null/empty instead of throwing for missing keys, files or malformed data.
/// </summary>
public static class SteamLocator
{
    /// <summary>Steam app id of PEAK.</summary>
    public const int PeakAppId = 3527290;

    private const string DefaultSteamDir = @"C:\Program Files (x86)\Steam";

    /// <summary>Returns the Steam install directory, or null if no candidate exists on disk.</summary>
    public static string? FindSteamDir()
    {
        string?[] candidates =
        {
            ReadRegistryString(Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath"),
            ReadRegistryString(Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
            ReadRegistryString(Registry.LocalMachine, @"SOFTWARE\Valve\Steam", "InstallPath"),
            DefaultSteamDir,
        };

        foreach (var candidate in candidates)
        {
            var dir = TryNormalizeExisting(candidate, directory: true);
            if (dir != null) return dir;
        }
        return null;
    }

    /// <summary>Returns the full path to steam.exe, or null if it cannot be found.</summary>
    public static string? FindSteamExe()
    {
        var fromRegistry = TryNormalizeExisting(
            ReadRegistryString(Registry.CurrentUser, @"Software\Valve\Steam", "SteamExe"), directory: false);
        if (fromRegistry != null) return fromRegistry;

        var steamDir = FindSteamDir();
        return steamDir == null
            ? null
            : TryNormalizeExisting(Path.Combine(steamDir, "steam.exe"), directory: false);
    }

    /// <summary>
    /// Returns the Steam root followed by every library listed in steamapps\libraryfolders.vdf,
    /// keeping only directories that exist and removing case-insensitive duplicates.
    /// </summary>
    public static IReadOnlyList<string> GetLibraryFolders(string steamDir)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddIfExists(string? path)
        {
            var dir = TryNormalizeExisting(path, directory: true);
            if (dir != null && seen.Add(dir)) result.Add(dir);
        }

        AddIfExists(steamDir);

        try
        {
            var vdfPath = Path.Combine(steamDir, "steamapps", "libraryfolders.vdf");
            if (File.Exists(vdfPath))
            {
                var root = ParseVdf(File.ReadAllText(vdfPath));

                // Current format: "libraryfolders" { "0" { "path" "D:\\SteamLibrary" ... } }
                // Legacy format: "LibraryFolders" { "1" "D:\\SteamLibrary" }
                // Keys are case-insensitive, so both spellings resolve to the same entry.
                if (root.TryGetValue("libraryfolders", out var section) && section is Dictionary<string, object> folders)
                {
                    foreach (var (key, entry) in folders)
                    {
                        if (entry is Dictionary<string, object> libraryEntry
                            && libraryEntry.TryGetValue("path", out var path))
                        {
                            AddIfExists(path as string);
                        }
                        else if (entry is string legacyPath && IsAllDigits(key))
                        {
                            AddIfExists(legacyPath);
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
            // Unreadable or malformed VDF: keep the libraries collected so far.
        }

        return result;
    }

    /// <summary>
    /// Finds the install directory of an app by checking each library's appmanifest_{appId}.acf
    /// and returning <library>\steamapps\common\&lt;installdir&gt; if that folder exists.
    /// </summary>
    public static string? FindGameDir(int appId = PeakAppId)
    {
        var steamDir = FindSteamDir();
        if (steamDir == null) return null;

        var manifestName = $"appmanifest_{appId}.acf";
        foreach (var library in GetLibraryFolders(steamDir))
        {
            try
            {
                var manifest = Path.Combine(library, "steamapps", manifestName);
                if (!File.Exists(manifest)) continue;

                var root = ParseVdf(File.ReadAllText(manifest));
                var state = root.TryGetValue("AppState", out var appState) && appState is Dictionary<string, object> nested
                    ? nested
                    : root;
                if (!state.TryGetValue("installdir", out var value) || value is not string installDir) continue;

                // installdir must be a single folder name so it cannot escape steamapps\common.
                if (installDir.Length == 0 || Path.GetFileName(installDir) != installDir || (installDir is "." or ".."))
                    continue;

                var gameDir = Path.Combine(library, "steamapps", "common", installDir);
                if (Directory.Exists(gameDir)) return NormalizePath(gameDir);
            }
            catch (Exception)
            {
                // Skip libraries whose manifest cannot be read.
            }
        }
        return null;
    }

    /// <summary>
    /// Parses Valve KeyValues (VDF) text. Values are strings or nested Dictionary&lt;string, object&gt;,
    /// keys are case-insensitive. Supports quoted/unquoted tokens, \\ \" \n \t escapes and // comments.
    /// Malformed input is tolerated rather than thrown.
    /// </summary>
    public static Dictionary<string, object> ParseVdf(string text)
    {
        var root = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(text)) return root;

        int pos = 0;
        ParseEntries(text, ref pos, root, topLevel: true);
        return root;
    }

    private enum TokenKind { End, Text, Open, Close }

    // Reads "key value" pairs into target until a closing brace (or end of text).
    private static void ParseEntries(string s, ref int pos, Dictionary<string, object> target, bool topLevel)
    {
        while (true)
        {
            var kind = NextToken(s, ref pos, out var key);
            if (kind == TokenKind.End) return;
            if (kind == TokenKind.Close)
            {
                if (topLevel) continue; // stray '}' at top level: ignore
                return;
            }
            if (kind == TokenKind.Open)
            {
                // Block without a key: parse and discard it.
                ParseEntries(s, ref pos, new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase), topLevel: false);
                continue;
            }

            kind = NextToken(s, ref pos, out var value);
            switch (kind)
            {
                case TokenKind.Text:
                    target[key] = value;
                    break;
                case TokenKind.Open:
                    var child = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                    ParseEntries(s, ref pos, child, topLevel: false);
                    target[key] = child;
                    break;
                case TokenKind.Close: // key with no value immediately before '}'
                    if (topLevel) continue;
                    return;
                default: // End of text
                    return;
            }
        }
    }

    // Returns the next token, skipping whitespace, BOM and // comments.
    private static TokenKind NextToken(string s, ref int pos, out string value)
    {
        value = string.Empty;
        while (pos < s.Length)
        {
            char c = s[pos];
            if (char.IsWhiteSpace(c) || c == '\uFEFF')
            {
                pos++;
                continue;
            }
            if (c == '/' && pos + 1 < s.Length && s[pos + 1] == '/')
            {
                while (pos < s.Length && s[pos] != '\n') pos++;
                continue;
            }
            if (c == '{') { pos++; return TokenKind.Open; }
            if (c == '}') { pos++; return TokenKind.Close; }

            value = c == '"' ? ReadQuoted(s, ref pos) : ReadUnquoted(s, ref pos);
            return TokenKind.Text;
        }
        return TokenKind.End;
    }

    private static string ReadQuoted(string s, ref int pos)
    {
        var sb = new StringBuilder();
        pos++; // opening quote
        while (pos < s.Length)
        {
            char c = s[pos];
            if (c == '"')
            {
                pos++; // closing quote
                break;
            }
            if (c == '\\' && pos + 1 < s.Length)
            {
                switch (s[pos + 1])
                {
                    case '\\': sb.Append('\\'); pos += 2; continue;
                    case '"': sb.Append('"'); pos += 2; continue;
                    case 'n': sb.Append('\n'); pos += 2; continue;
                    case 't': sb.Append('\t'); pos += 2; continue;
                }
                // Unknown escape: keep the backslash so unescaped Windows paths survive.
            }
            sb.Append(c);
            pos++;
        }
        return sb.ToString();
    }

    private static string ReadUnquoted(string s, ref int pos)
    {
        int start = pos;
        while (pos < s.Length && !char.IsWhiteSpace(s[pos]) && s[pos] is not ('{' or '}' or '"'))
            pos++;
        return s[start..pos];
    }

    private static string? ReadRegistryString(RegistryKey hive, string subKey, string valueName)
    {
        try
        {
            using var key = hive.OpenSubKey(subKey);
            return key?.GetValue(valueName) as string;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Normalizes the path and returns it only if it exists as a directory or file as requested.
    private static string? TryNormalizeExisting(string? path, bool directory)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var full = NormalizePath(path);
            return (directory ? Directory.Exists(full) : File.Exists(full)) ? full : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Converts forward slashes to backslashes, resolves the path and drops any trailing separator.
    private static string NormalizePath(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path.Trim()));

    private static bool IsAllDigits(string s) => s.Length > 0 && s.All(char.IsDigit);
}
