using System;
using PeakPack.Companion;
using Verdict = PeakPack.Companion.LobbyCheck.Verdict;

internal static class Program
{
    private const string MyPack = "Joshuas-Peak-Mods";
    private const string Shortcut = "PEAK (Modded)";

    // Name formatter handed to ClientMessage / HostMessage so the wrapping is visible in the expected strings.
    private static readonly Func<string, string> Name = s => "[" + s + "]";

    private static int _failures;

    private static void Check(bool cond, string name)
    {
        if (cond)
        {
            Console.WriteLine("  PASS  " + name);
        }
        else
        {
            _failures++;
            Console.WriteLine("  FAIL  " + name);
        }
    }

    // Equality check that also prints the actual value when it fails.
    private static void Eq<T>(T actual, T expected, string name)
    {
        bool ok = EqualityComparer<T>.Default.Equals(actual, expected);
        Check(ok, name);
        if (!ok) Console.WriteLine("        expected: " + Show(expected) + "\n        actual:   " + Show(actual));
    }

    // Substring check that also prints the actual string when it fails.
    private static void Has(string actual, string part, string name)
    {
        bool ok = actual != null && actual.Contains(part, StringComparison.Ordinal);
        Check(ok, name);
        if (!ok) Console.WriteLine("        actual:   " + Show(actual));
    }

    private static string Show<T>(T v) => v == null ? "null" : "\"" + v + "\"";

    private static int Main()
    {
        Console.WriteLine("Compare");
        Eq(LobbyCheck.Compare(MyPack, 7, null, 7), Verdict.NoHostInfo, "room pack null -> NoHostInfo");
        Eq(LobbyCheck.Compare(MyPack, 7, "", 7), Verdict.NoHostInfo, "room pack empty -> NoHostInfo");
        Eq(LobbyCheck.Compare(MyPack, 7, MyPack, null), Verdict.NoHostInfo, "room rev null -> NoHostInfo");
        Eq(LobbyCheck.Compare("A", 7, "B", null), Verdict.NoHostInfo, "no host info wins over pack mismatch");
        Eq(LobbyCheck.Compare(MyPack, 6, "joshuas-peak-mods", 6), Verdict.Match, "pack compare is case-insensitive (lower)");
        Eq(LobbyCheck.Compare(MyPack, 6, "JOSHUAS-PEAK-MODS", 6), Verdict.Match, "pack compare is case-insensitive (upper)");
        Eq(LobbyCheck.Compare(MyPack, 6, "Someone-Else-Pack", 6), Verdict.OtherPack, "different pack id -> OtherPack");
        Eq(LobbyCheck.Compare(MyPack, 6, "Someone-Else-Pack", 7), Verdict.OtherPack, "different pack wins over rev difference");
        Eq(LobbyCheck.Compare(MyPack, 6, MyPack, 7), Verdict.YouAreOlder, "room 7 vs mine 6 -> YouAreOlder");
        Eq(LobbyCheck.Compare(MyPack, 7, MyPack, 6), Verdict.YouAreNewer, "room 6 vs mine 7 -> YouAreNewer");
        Eq(LobbyCheck.Compare(MyPack, 7, MyPack, 7), Verdict.Match, "equal revs -> Match");
        Eq(LobbyCheck.Compare(MyPack, 9, MyPack, 10), Verdict.YouAreOlder, "rev 10 vs 9 compared numerically");

        Console.WriteLine("ClientMessage");
        Eq(LobbyCheck.ClientMessage(Verdict.YouAreOlder, "Joshua", 6, 7, Shortcut, false, Name),
            "[Joshua]'s expedition uses mod pack rev 7. You have rev 6. Restart PEAK from the PEAK (Modded) icon to update.",
            "YouAreOlder exact text (no block)");
        Eq(LobbyCheck.ClientMessage(Verdict.YouAreOlder, "Joshua", 6, 7, Shortcut, true, Name),
            "[Joshua]'s expedition uses mod pack rev 7. You have rev 6. Restart PEAK from the PEAK (Modded) icon to update. Leaving in 10 seconds.",
            "YouAreOlder exact text (with block)");
        Has(LobbyCheck.ClientMessage(Verdict.YouAreNewer, "Joshua", 7, 6, Shortcut, false, Name),
            "[Joshua] is on rev 6", "YouAreNewer names host and rev");
        Has(LobbyCheck.ClientMessage(Verdict.YouAreNewer, "Joshua", 7, 6, Shortcut, false, Name),
            "You have mod pack rev 7", "YouAreNewer states my rev");
        Eq(LobbyCheck.ClientMessage(Verdict.YouAreNewer, "Joshua", 7, 6, Shortcut, false, Name),
            "You have mod pack rev 7. [Joshua] is on rev 6 and should restart PEAK to update.",
            "YouAreNewer exact text");
        Eq(LobbyCheck.ClientMessage(Verdict.Match, "Joshua", 7, 7, Shortcut, true, Name), null, "Match -> null");
        Eq(LobbyCheck.ClientMessage(Verdict.NoHostInfo, "Joshua", 7, 7, Shortcut, true, Name), null, "NoHostInfo -> null");
        Eq(LobbyCheck.ClientMessage(Verdict.OtherPack, "Joshua", 7, 7, Shortcut, true, Name), null, "OtherPack -> null");

        Console.WriteLine("HostMessage");
        Eq(LobbyCheck.HostMessage("Sam", null, null, MyPack, 7, true, Shortcut, Name),
            "[Sam] joined without the mod pack.", "no pack, mods required -> joined without pack");
        Eq(LobbyCheck.HostMessage("Sam", null, null, MyPack, 7, false, Shortcut, Name),
            null, "no pack, mods not required -> null");
        Eq(LobbyCheck.HostMessage("Sam", "", null, MyPack, 7, true, Shortcut, Name),
            "[Sam] joined without the mod pack.", "empty pack string counts as no pack");
        Eq(LobbyCheck.HostMessage("Sam", "Someone-Else-Pack", null, MyPack, 7, true, Shortcut, Name),
            "[Sam] joined without the mod pack.", "pack with null rev counts as no pack");
        Has(LobbyCheck.HostMessage("Sam", "Someone-Else-Pack", 7, MyPack, 7, true, Shortcut, Name),
            "different mod pack", "other pack -> different mod pack");
        Eq(LobbyCheck.HostMessage("Sam", "joshuas-peak-mods", 7, MyPack, 7, true, Shortcut, Name),
            null, "same pack different case and equal rev -> null");
        Eq(LobbyCheck.HostMessage("Sam", MyPack, 6, MyPack, 7, true, Shortcut, Name),
            "[Sam] has mod pack rev 6. Yours is rev 7.", "their 6 vs mine 7 -> older message");
        Has(LobbyCheck.HostMessage("Sam", MyPack, 8, MyPack, 7, true, Shortcut, Name),
            "newer mod pack (rev 8)", "their 8 vs mine 7 -> newer message names rev");
        Has(LobbyCheck.HostMessage("Sam", MyPack, 8, MyPack, 7, true, Shortcut, Name),
            "PEAK (Modded)", "their 8 vs mine 7 -> newer message names shortcut");
        Eq(LobbyCheck.HostMessage("Sam", MyPack, 7, MyPack, 7, true, Shortcut, Name),
            null, "equal revs -> null");

        Console.WriteLine("SafeName");
        Eq(LobbyCheck.SafeName(null), "Someone", "null -> Someone");
        Eq(LobbyCheck.SafeName(""), "Someone", "empty -> Someone");
        Eq(LobbyCheck.SafeName("Sam"), "Sam", "plain name unchanged");
        string tagged = LobbyCheck.SafeName("<b>Sam</b>");
        Check(tagged != null && !tagged.Contains('<') && !tagged.Contains('>'), "rich-text brackets stripped");
        Has(tagged, "Sam", "name text survives bracket stripping");
        Check(LobbyCheck.SafeName(new string('a', 40)).Length == 32, "40-char name truncated to 32");
        Eq(LobbyCheck.SafeName(new string('a', 40)), new string('a', 32), "40-char name is first 32 chars");
        Check(LobbyCheck.SafeName(new string('b', 32)).Length == 32, "exactly 32-char name kept at 32");

        Console.WriteLine("Scrub");
        const string profile = @"C:\Users\joshu";
        string scrubbed = DiagLogic.Scrub(@"C:\Users\joshu\AppData\LocalLow\x", profile, "joshu", "DESKTOP-ABC");
        Eq(scrubbed, @"%USERPROFILE%\AppData\LocalLow\x", "backslash profile path -> %USERPROFILE%");
        Check(!scrubbed.Contains("joshu", StringComparison.OrdinalIgnoreCase), "user name gone from scrubbed path");
        Eq(DiagLogic.Scrub("C:/Users/joshu/x", profile, "joshu", "DESKTOP-ABC"), "%USERPROFILE%/x", "forward-slash profile path -> %USERPROFILE%");
        Eq(DiagLogic.Scrub(@"c:\users\JOSHU\x", profile, "joshu", "DESKTOP-ABC"), @"%USERPROFILE%\x", "profile match is case-insensitive");
        Eq(DiagLogic.Scrub("Host DESKTOP-ABC here", profile, "joshu", "DESKTOP-ABC"), "Host <pc> here", "machine name -> <pc>");
        Eq(DiagLogic.Scrub(@"E:\Users\joshu\x", null, "joshu", null), @"E:\Users\<user>\x", "user name alone -> <user> in \\Users\\ path");
        Eq(DiagLogic.Scrub(@"D:\Users\jo\x", null, "jo", null), @"D:\Users\jo\x", "2-char user name not replaced");
        Eq(DiagLogic.Scrub(null, profile, "joshu", "DESKTOP-ABC"), "", "null input -> empty string");
        Eq(DiagLogic.Scrub("", profile, "joshu", "DESKTOP-ABC"), "", "empty input -> empty string");

        Console.WriteLine("Chunk");
        Check(DiagLogic.Chunk("").Count == 0, "empty -> 0 chunks");
        Check(DiagLogic.Chunk(null).Count == 0, "null -> 0 chunks");
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < 100; i++) sb.Append((char)('a' + i % 26), 99).Append('\n');
        string big = sb.ToString();
        Eq(big.Length, 10000, "test input is 10,000 chars (100 lines of 100)");
        var chunks = DiagLogic.Chunk(big, 3000);
        Check(chunks.TrueForAll(ch => ch.Length <= 3000), "every chunk <= 3000 chars");
        Check(chunks.TrueForAll(ch => ch.EndsWith('\n')), "every chunk ends at a line break");
        Eq(chunks.Count, 4, "10,000 chars -> 4 chunks");
        Eq(string.Concat(chunks), big, "chunks concatenate back to the input");
        var oneLine = DiagLogic.Chunk(new string('x', 7000), 3000);
        Eq(oneLine.Count, 3, "7000-char line with no newline -> 3 chunks");
        Eq(string.Concat(oneLine), new string('x', 7000), "no-newline chunks concatenate back");

        Console.WriteLine("KeepTail");
        Eq(DiagLogic.KeepTail("short text", 100), "short text", "short text unchanged");
        Eq(DiagLogic.KeepTail(big), big, "10,000 chars under the 60,000 default unchanged");
        string tail = DiagLogic.KeepTail(big, 500);
        Check(tail.Length <= 500 + 40, "long text capped near max (marker allowed)");
        Check(tail.StartsWith("[... older lines dropped ...]", StringComparison.Ordinal), "starts with the drop marker");
        Check(tail.EndsWith(big.Substring(big.Length - 50), StringComparison.Ordinal), "ends with the original ending");

        Console.WriteLine("SafeFileName");
        string sam = DiagLogic.SafeFileName("Sam <3", 5);
        Check(!sam.Contains('<') && !sam.Contains(' '), "\"Sam <3\" has no '<' or space");
        Eq(DiagLogic.SafeFileName("", 7), "player-7", "empty name -> player-<actor>");
        Eq(DiagLogic.SafeFileName(null, 9), "player-9", "null name -> player-<actor>");
        Eq(DiagLogic.SafeFileName("CON", 2), "player-2", "reserved CON -> player-<actor>");
        Check(DiagLogic.SafeFileName(new string('n', 60), 1).Length <= 40, "60-char name capped at 40");
        Eq(DiagLogic.SafeFileName("Jo.sh", 3), "Jo.sh", "dot inside name kept");

        Console.WriteLine("PlayerLogErrors");
        var logLines = new List<string> { "ok", "NullReferenceException: Object reference not set", "  at Foo.Bar () [0x00000]", "  at Baz ()", "next normal line", "Error loading asset", "fine" };
        var errs = DiagLogic.PlayerLogErrors(logLines);
        Check(errs.Contains("NullReferenceException: Object reference not set"), "exception line kept");
        Check(errs.Contains("  at Foo.Bar () [0x00000]"), "first stack line kept");
        Check(errs.Contains("  at Baz ()"), "second stack line kept");
        Check(errs.Contains("Error loading asset"), "Error line kept");
        Check(!errs.Contains("ok") && !errs.Contains("next normal line") && !errs.Contains("fine"), "normal lines dropped");
        var manyErrs = new List<string>();
        for (int i = 0; i < 1000; i++) manyErrs.Add("Exception " + i);
        var capped = DiagLogic.PlayerLogErrors(manyErrs, 400);
        Eq(capped.Count, 400, "1000 error lines, maxLines 400 -> 400 results");
        Eq(capped[0], "Exception 600", "keeps the last 400: first is line 600");
        Eq(capped[399], "Exception 999", "keeps the last 400: last is line 999");

        Console.WriteLine("RateLimiter");
        var limiter = new RateLimiter(1000, 2000);
        Check(limiter.TryTake(1500, 0), "t=0 take 1500 from burst 2000 -> true");
        Check(!limiter.TryTake(1000, 0), "t=0 take 1000 again -> false (500 left)");
        Check(limiter.TryTake(1000, 1.0), "t=1.0 take 1000 -> true (refilled)");
        Check(limiter.TryTake(2000, 100), "t=100 take 2000 -> true (refill capped at burst)");
        Check(!limiter.TryTake(1, 100), "t=100 take 1 more -> false (bucket empty)");

        Console.WriteLine("UpdateMessage");
        var scoutMods = new List<string> { "Scoutmaster Mode" };
        Eq(LobbyCheck.UpdateMessage("applied", "Joshua", scoutMods, 8, Shortcut, Name), "[Joshua] updated Scoutmaster Mode.", "applied with mod name");
        Eq(LobbyCheck.UpdateMessage("applied", "Joshua", null, 8, Shortcut, Name), "[Joshua] updated a mod.", "applied with null mods -> a mod");
        const string publishedText = "[Joshua] published mod pack rev 8. Restart PEAK from the PEAK (Modded) icon to get it.";
        Eq(LobbyCheck.UpdateMessage("restart-needed", "Joshua", null, 8, Shortcut, Name), publishedText, "restart-needed text");
        Eq(LobbyCheck.UpdateMessage("not-allowed", "Joshua", null, 8, Shortcut, Name), publishedText, "not-allowed text");
        Eq(LobbyCheck.UpdateMessage("up-to-date", "Joshua", null, 8, Shortcut, Name), null, "up-to-date -> null");
        string failed = LobbyCheck.UpdateMessage("failed", "Joshua", null, 8, Shortcut, Name);
        Check(failed != null && failed.StartsWith("Couldn't apply [Joshua]'s update.", StringComparison.Ordinal), "failed starts with Couldn't apply");

        Console.WriteLine();
        if (_failures == 0)
            Console.WriteLine("ALL LOBBY CHECKS PASSED");
        else
            Console.WriteLine(_failures + " LOBBY CHECK(S) FAILED");
        return _failures;
    }
}
