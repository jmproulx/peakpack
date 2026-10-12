using System;

namespace PeakPack.Companion
{
    /// <summary>
    /// Pure decision + wording logic for the lobby check (no Unity or Photon types, so the sandbox tests can compile
    /// this file on its own). Wording follows PEAK's feed ("X joined the expedition."): short, plain, no exclamation.
    /// </summary>
    public static class LobbyCheck
    {
        public enum Verdict { NoHostInfo, OtherPack, Match, YouAreOlder, YouAreNewer }

        public static Verdict Compare(string myPack, int myRev, string roomPack, int? roomRev)
        {
            if (string.IsNullOrEmpty(roomPack) || roomRev == null) return Verdict.NoHostInfo;
            if (!string.Equals(myPack, roomPack, StringComparison.OrdinalIgnoreCase)) return Verdict.OtherPack;
            if (roomRev.Value == myRev) return Verdict.Match;
            return roomRev.Value > myRev ? Verdict.YouAreOlder : Verdict.YouAreNewer;
        }

        /// <summary>What a player sees after joining someone's lobby. Null = say nothing.</summary>
        /// <param name="name">Wraps a player name in the game's name colour.</param>
        public static string ClientMessage(Verdict v, string host, int myRev, int roomRev, string shortcut, bool block, Func<string, string> name)
        {
            switch (v)
            {
                case Verdict.YouAreOlder:
                    return name(host) + "'s expedition uses mod pack rev " + roomRev + ". You have rev " + myRev +
                           ". Restart PEAK from the " + shortcut + " icon to update." + (block ? " Leaving in 10 seconds." : "");
                case Verdict.YouAreNewer:
                    return "You have mod pack rev " + myRev + ". " + name(host) + " is on rev " + roomRev + " and should restart PEAK to update.";
                default:
                    return null;
            }
        }

        /// <summary>What the lobby host sees about a player. Null = say nothing.</summary>
        public static string HostMessage(string player, string theirPack, int? theirRev, string myPack, int myRev,
            bool modsRequired, string shortcut, Func<string, string> name)
        {
            if (string.IsNullOrEmpty(theirPack) || theirRev == null)
                return modsRequired ? name(player) + " joined without the mod pack." : null;
            if (!string.Equals(theirPack, myPack, StringComparison.OrdinalIgnoreCase))
                return name(player) + " is using a different mod pack.";
            if (theirRev.Value < myRev)
                return name(player) + " has mod pack rev " + theirRev.Value + ". Yours is rev " + myRev + ".";
            if (theirRev.Value > myRev)
                return name(player) + " has a newer mod pack (rev " + theirRev.Value + "). Restart PEAK from the " + shortcut + " icon to update.";
            return null;
        }

        /// <summary>Strips rich-text tags out of player names (they are shown inside a TMP text with rich text on).</summary>
        public static string SafeName(string nick)
        {
            if (string.IsNullOrEmpty(nick)) return "Someone";
            var sb = new System.Text.StringBuilder();
            foreach (var c in nick) if (c != '<' && c != '>' && !char.IsControl(c)) sb.Append(c);
            var s = sb.ToString().Trim();
            if (s.Length == 0) return "Someone";
            if (s.Length <= 32) return s;
            return s.Substring(0, char.IsHighSurrogate(s[31]) ? 31 : 32); // don't cut an emoji in half
        }
    }
}
