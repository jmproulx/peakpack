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

        Console.WriteLine();
        if (_failures == 0)
            Console.WriteLine("ALL LOBBY CHECKS PASSED");
        else
            Console.WriteLine(_failures + " LOBBY CHECK(S) FAILED");
        return _failures;
    }
}
