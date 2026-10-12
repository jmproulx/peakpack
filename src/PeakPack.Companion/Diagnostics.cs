using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using BepInEx;
using BepInEx.Bootstrap;
using BepInEx.Logging;
using UnityEngine;

namespace PeakPack.Companion
{
    /// <summary>
    /// Remote diagnostics. Friend side: captures the lines that matter for the host's mods (every line from the
    /// host's own mods and PeakPack, plus errors/exceptions from anything, from BepInEx AND from Unity's own log,
    /// which doesn't reach LogOutput.log here) into a small in-memory buffer, and builds scrubbed snapshots.
    /// Nothing leaves the PC unless the friend consented AND they're in the verified host's lobby (Plugin decides).
    /// Host side: appends what friends send to BepInEx\PeakPack-remote-logs\&lt;friend&gt;.log.
    /// </summary>
    internal sealed class Diagnostics : ILogListener
    {
        const int RingSize = 600;
        readonly object _lock = new object();
        readonly LinkedList<string> _ring = new LinkedList<string>();
        readonly List<string> _live = new List<string>();      // not yet sent
        string _lastLine; int _repeat;
        readonly HashSet<string> _ownSources = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        float _ownSourcesAt = -100f;
        readonly string _profile = SafeEnv(() => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        readonly string _user = SafeEnv(() => Environment.UserName);
        readonly string _machine = SafeEnv(() => Environment.MachineName);
        public List<string> OwnModFolders = new List<string>();
        bool _attached;

        static string SafeEnv(Func<string> f) { try { return f() ?? ""; } catch { return ""; } }

        public void Attach()
        {
            if (_attached) return;
            _attached = true;
            BepInEx.Logging.Logger.Listeners.Add(this);
            Application.logMessageReceivedThreaded += OnUnityLog;
        }

        public void Dispose()
        {
            if (!_attached) return;
            _attached = false;
            BepInEx.Logging.Logger.Listeners.Remove(this);
            Application.logMessageReceivedThreaded -= OnUnityLog;
        }

        // ---------- capture (may run on any thread) ----------

        public void LogEvent(object sender, LogEventArgs e)
        {
            try
            {
                var src = e.Source?.SourceName ?? "";
                if (src == "Unity Log") return; // we take Unity's lines from Application.logMessageReceivedThreaded instead
                bool error = (e.Level & (LogLevel.Error | LogLevel.Fatal)) != 0;
                bool mine = src.StartsWith("PeakPack", StringComparison.OrdinalIgnoreCase) || IsOwnSource(src);
                if (!error && !mine) return;
                Add($"[{e.Level,-7}:{src}] {e.Data}");
            }
            catch { /* a log listener must never throw */ }
        }

        void OnUnityLog(string condition, string stackTrace, LogType type)
        {
            if (type != LogType.Error && type != LogType.Exception && type != LogType.Assert) return;
            var sb = new StringBuilder("[Unity ").Append(type).Append("] ").Append(condition);
            if (!string.IsNullOrEmpty(stackTrace))
                foreach (var l in stackTrace.Split('\n').Take(8)) if (l.Trim().Length > 0) sb.Append("\n    ").Append(l.TrimEnd());
            Add(sb.ToString());
        }

        void Add(string line)
        {
            lock (_lock)
            {
                if (line == _lastLine) { _repeat++; return; }
                if (_repeat > 0) Push($"    (previous line repeated {_repeat} more times)");
                _lastLine = line; _repeat = 0;
                Push(DateTime.Now.ToString("HH:mm:ss ") + line);
            }
        }

        void Push(string line)
        {
            _ring.AddLast(line);
            while (_ring.Count > RingSize) _ring.RemoveFirst();
            _live.Add(line);
            if (_live.Count > RingSize) _live.RemoveRange(0, _live.Count - RingSize);
        }

        /// <summary>Log sources of the host's own mods = plugin names of plugins loaded from their folders (main thread refresh).</summary>
        public void RefreshOwnSources()
        {
            if (Time.unscaledTime - _ownSourcesAt < 10f) return;
            _ownSourcesAt = Time.unscaledTime;
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var pi in Chainloader.PluginInfos.Values)
            {
                var loc = (pi.Location ?? "").Replace('\\', '/');
                if (OwnModFolders.Any(f => loc.IndexOf("/" + f.TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase) >= 0))
                    set.Add(pi.Metadata.Name);
            }
            lock (_lock) { _ownSources.Clear(); _ownSources.UnionWith(set); }
        }

        bool IsOwnSource(string src) { lock (_lock) return _ownSources.Contains(src); }

        // ---------- friend: what gets sent ----------

        public string Scrub(string s) => DiagLogic.Scrub(s, _profile, _user, _machine);

        /// <summary>Lines captured since the last call (scrubbed).</summary>
        public string TakeLive(int maxChars)
        {
            lock (_lock)
            {
                if (_live.Count == 0) return null;
                var sb = new StringBuilder();
                int n = 0;
                while (n < _live.Count && sb.Length + _live[n].Length + 1 <= maxChars) sb.Append(_live[n++]).Append('\n');
                if (n == 0) { sb.Append(_live[0].Substring(0, Math.Min(maxChars - 20, _live[0].Length))).Append(" [cut]\n"); n = 1; }
                _live.RemoveRange(0, n);
                return Scrub(sb.ToString());
            }
        }

        public void ClearLive() { lock (_lock) _live.Clear(); }

        /// <summary>Header (pack revision, game, mods) + recent captured lines + errors from the end of Player.log.</summary>
        public string BuildSnapshot(PackInfoDto info, string nick, string reason)
        {
            var sb = new StringBuilder();
            sb.Append("===== PeakPack diagnostics from ").Append(nick).Append(" at ").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")).Append(" (").Append(reason).Append(") =====\n");
            sb.Append("Pack: ").Append(info.packId).Append(" revision ").Append(info.revision).Append('\n');
            sb.Append("Game: PEAK ").Append(Application.version).Append(", Unity ").Append(Application.unityVersion)
              .Append(", BepInEx ").Append(typeof(Paths).Assembly.GetName().Version).Append('\n');
            sb.Append("Mods:\n");
            foreach (var pi in Chainloader.PluginInfos.Values.OrderBy(p => p.Metadata.Name, StringComparer.OrdinalIgnoreCase))
            {
                var folder = Path.GetFileName(Path.GetDirectoryName(pi.Location ?? "") ?? "");
                sb.Append("  ").Append(pi.Metadata.Name).Append(' ').Append(pi.Metadata.Version).Append("  (").Append(pi.Metadata.GUID).Append(", ").Append(folder).Append(")\n");
            }
            sb.Append("--- recent lines (host's mods, PeakPack, all errors) ---\n");
            lock (_lock) foreach (var l in _ring) sb.Append(l).Append('\n');
            sb.Append("--- errors from the end of Player.log ---\n");
            foreach (var l in PlayerLogErrorLines()) sb.Append(l).Append('\n');
            sb.Append("===== end =====\n");
            return DiagLogic.KeepTail(Scrub(sb.ToString()));
        }

        static IEnumerable<string> PlayerLogErrorLines()
        {
            string path = null;
            try { path = Application.consoleLogPath; } catch { }
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return new[] { "(Player.log not found)" };
            try
            {
                // Unity keeps Player.log open for writing: share it, and read only the last 256 KB.
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    long start = Math.Max(0, fs.Length - 256 * 1024);
                    fs.Seek(start, SeekOrigin.Begin);
                    using (var r = new StreamReader(fs))
                    {
                        if (start > 0) r.ReadLine(); // partial line
                        var lines = new List<string>();
                        string line;
                        while ((line = r.ReadLine()) != null) lines.Add(line);
                        var errors = DiagLogic.PlayerLogErrors(lines);
                        return errors.Count == 0 ? new List<string> { "(no errors)" } : errors;
                    }
                }
            }
            catch (Exception e) { return new[] { "(couldn't read Player.log: " + e.Message + ")" }; }
        }
    }

    /// <summary>Host side: writes what each friend sends into BepInEx\PeakPack-remote-logs\&lt;friend&gt;.log (+ a lobby index).</summary>
    internal sealed class RemoteLogWriter
    {
        const long MaxFileBytes = 2 * 1024 * 1024;
        const int MaxCharsPerMinute = 400000;
        readonly string _dir = Path.Combine(Paths.BepInExRootPath, "PeakPack-remote-logs");
        readonly Dictionary<int, (float Window, int Chars)> _budget = new Dictionary<int, (float, int)>();
        readonly Dictionary<int, string> _index = new Dictionary<int, string>();
        readonly ManualLogSource _log;

        public RemoteLogWriter(ManualLogSource log) { _log = log; }

        public string Dir => _dir;

        public void Write(int actor, string nick, string kind, string text, string packRev)
        {
            try
            {
                var now = Time.unscaledTime;
                if (!_budget.TryGetValue(actor, out var b) || now - b.Window > 60f) b = (now, 0);
                if (b.Chars + text.Length > MaxCharsPerMinute) { _budget[actor] = b; return; } // flood guard
                _budget[actor] = (b.Window, b.Chars + text.Length);

                Directory.CreateDirectory(_dir);
                var file = Path.Combine(_dir, DiagLogic.SafeFileName(nick, actor) + ".log");
                if (File.Exists(file) && new FileInfo(file).Length > MaxFileBytes)
                {
                    var old = file + ".1";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(file, old);
                }
                var head = kind == "live" ? "" : $"\n----- {kind} from {nick} (actor {actor}) received {DateTime.Now:yyyy-MM-dd HH:mm:ss} -----\n";
                File.AppendAllText(file, head + text);
                _index[actor] = $"{DateTime.Now:HH:mm:ss}  {nick,-24} actor {actor,-3} {packRev,-18} {Path.GetFileName(file)}";
                File.WriteAllText(Path.Combine(_dir, "_lobby.txt"),
                    "Friends in your lobby who sent logs (newest data at the end of each file):\n" + string.Join("\n", _index.Values) + "\n");
            }
            catch (Exception e) { _log.LogWarning("Couldn't write a friend's log: " + e.Message); }
        }
    }
}
