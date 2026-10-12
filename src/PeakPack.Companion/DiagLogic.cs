using System;
using System.Collections.Generic;
using System.Text;

namespace PeakPack.Companion
{
    /// <summary>
    /// Pure logic for remote diagnostics (no Unity/Photon/BepInEx types, so tools\LobbyCheckTests compiles it on its own):
    /// scrubbing personal paths, chunking for Photon events, rate limiting, safe file names, Player.log error filtering.
    /// </summary>
    public static class DiagLogic
    {
        public const int ChunkChars = 3000;          // per Photon event (well under Photon's message limits)
        public const int SnapshotMaxChars = 60000;   // per snapshot; oldest lines are dropped first
        public const int BytesPerSecond = 8000;      // per friend, to the host only

        /// <summary>Replaces the Windows user profile path, user name and machine name with placeholders.
        /// Handles both slash styles and is case-insensitive.</summary>
        public static string Scrub(string text, string userProfile, string userName, string machineName)
        {
            if (string.IsNullOrEmpty(text)) return text ?? "";
            var s = text;
            if (!string.IsNullOrEmpty(userProfile) && userProfile.Length > 3)
            {
                s = ReplaceIgnoreCase(s, userProfile, "%USERPROFILE%", wholeName: true);
                s = ReplaceIgnoreCase(s, userProfile.Replace('\\', '/'), "%USERPROFILE%", wholeName: true);
            }
            if (!string.IsNullOrEmpty(userName) && userName.Length >= 3)
            {
                s = ReplaceIgnoreCase(s, "\\Users\\" + userName, "\\Users\\<user>", wholeName: true);
                s = ReplaceIgnoreCase(s, "/Users/" + userName, "/Users/<user>", wholeName: true);
            }
            if (!string.IsNullOrEmpty(machineName) && machineName.Length >= 3) s = ReplaceIgnoreCase(s, machineName, "<pc>");
            return s;
        }

        /// <param name="wholeName">Only replace when the match isn't followed by another name character
        /// (so a profile "...\jo" doesn't eat the start of "...\joe").</param>
        static string ReplaceIgnoreCase(string s, string find, string with, bool wholeName = false)
        {
            if (find.Length == 0) return s;
            var sb = new StringBuilder();
            int i = 0;
            while (true)
            {
                int j = s.IndexOf(find, i, StringComparison.OrdinalIgnoreCase);
                if (j < 0) { sb.Append(s, i, s.Length - i); break; }
                int end = j + find.Length;
                if (wholeName && end < s.Length && (char.IsLetterOrDigit(s[end]) || s[end] == '_' || s[end] == '-' || s[end] == '.'))
                {
                    sb.Append(s, i, end - i);
                    i = end;
                    continue;
                }
                sb.Append(s, i, j - i).Append(with);
                i = end;
            }
            return sb.ToString();
        }

        /// <summary>Splits text into chunks of at most <paramref name="max"/> chars, preferring line breaks.</summary>
        public static List<string> Chunk(string text, int max = ChunkChars)
        {
            var list = new List<string>();
            if (string.IsNullOrEmpty(text)) return list;
            if (max < 2) max = 2;
            int i = 0;
            while (i < text.Length)
            {
                int len = Math.Min(max, text.Length - i);
                if (i + len < text.Length)
                {
                    int nl = text.LastIndexOf('\n', i + len - 1, len);
                    if (nl > i) len = nl - i + 1;
                    else if (char.IsHighSurrogate(text[i + len - 1])) len--; // don't split an emoji in two
                }
                list.Add(text.Substring(i, len));
                i += len;
            }
            return list;
        }

        /// <summary>Keeps the END of the text (the most recent lines) within <paramref name="max"/> chars.</summary>
        public static string KeepTail(string text, int max = SnapshotMaxChars)
        {
            if (text == null || text.Length <= max) return text ?? "";
            var cut = text.IndexOf('\n', text.Length - max);
            return "[... older lines dropped ...]\n" + (cut >= 0 ? text.Substring(cut + 1) : text.Substring(text.Length - max));
        }

        /// <summary>"Sam <3" -> "Sam__3"; never empty, never a reserved name, max 40 chars.</summary>
        public static string SafeFileName(string nick, int actor)
        {
            var sb = new StringBuilder();
            foreach (var c in nick ?? "")
                sb.Append(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.' ? c : '_');
            var s = sb.ToString().Trim('.', '_');
            if (s.Length > 40) s = s.Substring(0, 40);
            // Windows reserves device names before the first dot too ("con.x" means CON).
            var stem = (s.IndexOf('.') >= 0 ? s.Substring(0, s.IndexOf('.')) : s).ToUpperInvariant();
            if (s.Length == 0 || stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL"
                || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsDigit(stem[3]))
                s = "player-" + actor;
            return s;
        }

        /// <summary>From the end of Player.log: error/exception lines plus the stack lines that follow them.</summary>
        public static List<string> PlayerLogErrors(IList<string> lines, int maxLines = 400)
        {
            var result = new List<string>();
            for (int i = 0; i < lines.Count; i++)
            {
                var l = lines[i];
                if (!IsErrorLine(l)) continue;
                result.Add(l);
                for (int k = 1; k <= 8 && i + k < lines.Count; k++)
                {
                    var n = lines[i + k];
                    if (n.Length == 0 || IsErrorLine(n)) break;
                    if (n.StartsWith("  at ") || n.StartsWith("at ") || n.Contains("(at ") || n.StartsWith("UnityEngine.") || n.StartsWith("  "))
                        result.Add(n);
                    else break;
                }
            }
            return result.Count <= maxLines ? result : result.GetRange(result.Count - maxLines, maxLines);
        }

        public static bool IsErrorLine(string l) =>
            l.IndexOf("Exception", StringComparison.Ordinal) >= 0 || l.StartsWith("Error", StringComparison.Ordinal)
            || l.IndexOf("[Error", StringComparison.Ordinal) >= 0 || l.IndexOf("error:", StringComparison.OrdinalIgnoreCase) >= 0
            || l.StartsWith("Failed", StringComparison.Ordinal) || l.IndexOf("NullReference", StringComparison.Ordinal) >= 0
            || l.IndexOf("Missing", StringComparison.Ordinal) >= 0 && l.IndexOf("Missing", StringComparison.Ordinal) < 40;
    }

    /// <summary>Token bucket: allows <c>rate</c> units per second with a burst of <c>burst</c>.</summary>
    public sealed class RateLimiter
    {
        readonly double _rate, _burst;
        double _tokens, _last;

        public RateLimiter(double ratePerSecond, double burst) { _rate = ratePerSecond; _burst = burst; _tokens = burst; _last = double.NaN; }

        public bool TryTake(double amount, double now)
        {
            if (double.IsNaN(_last)) _last = now;
            _tokens = Math.Min(_burst, _tokens + (now - _last) * _rate);
            _last = now;
            if (_tokens < amount) return false;
            _tokens -= amount;
            return true;
        }
    }
}
