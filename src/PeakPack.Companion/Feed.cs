using System.Collections.Generic;
using System.Reflection;
using UnityEngine;

namespace PeakPack.Companion
{
    /// <summary>
    /// Posts lines into PEAK's own connection feed (PlayerConnectionLog: the "X joined the expedition." list),
    /// so notices use the game's TextMeshPro text, its colours (joinedColor / leftColor / userColor), its 8-second
    /// fade-out and its join/leave sounds. Nothing is drawn by the plugin itself.
    /// PlayerConnectionLog.AddMessage is private, so it is called by reflection; if a game update renames it,
    /// the notice still goes to the BepInEx log and nothing breaks.
    /// Lines posted before the feed exists (e.g. during a loading screen) wait up to a minute.
    /// </summary>
    internal sealed class Feed
    {
        const char NameStart = '\u0001', NameEnd = '\u0002';
        static readonly MethodInfo AddMessage =
            typeof(PlayerConnectionLog).GetMethod("AddMessage", BindingFlags.Instance | BindingFlags.NonPublic, null, new[] { typeof(string) }, null);

        readonly List<(string Text, bool Warning, bool Sound, float Expires)> _queue = new List<(string, bool, bool, float)>();

        /// <summary>Marks a player name; rendered in the game's player-name colour.</summary>
        public static string Name(string s) => NameStart + s + NameEnd;

        public void Post(string text, bool warning, bool sound = true)
        {
            BepInEx.Logging.Logger.CreateLogSource("PeakPack").LogInfo("Notice: " + text.Replace(NameStart.ToString(), "").Replace(NameEnd.ToString(), ""));
            _queue.Add((text, warning, sound, Time.unscaledTime + 60f));
            Flush();
        }

        public void Flush()
        {
            if (_queue.Count == 0) return;
            _queue.RemoveAll(q => Time.unscaledTime > q.Expires);
            if (_queue.Count == 0 || AddMessage == null) return;
            var log = Object.FindAnyObjectByType<PlayerConnectionLog>();
            if (log == null || !log.isActiveAndEnabled) return;
            foreach (var q in _queue)
            {
                var body = q.Text.Replace(NameStart.ToString(), Tag(log.userColor)).Replace(NameEnd.ToString(), "</color>");
                AddMessage.Invoke(log, new object[] { Tag(q.Warning ? log.leftColor : log.joinedColor) + body + "</color>" });
                if (q.Sound)
                {
                    var sfx = q.Warning ? log.sfxLeave : log.sfxJoin;
                    if (sfx != null) sfx.Play();
                }
            }
            _queue.Clear();
        }

        static string Tag(Color c) => "<color=#" + ColorUtility.ToHtmlStringRGB(c) + ">";
    }
}
