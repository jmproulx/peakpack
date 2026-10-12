using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using BepInEx;
using BepInEx.Configuration;
using ExitGames.Client.Photon;
using Photon.Pun;
using Photon.Realtime;
using UnityEngine;
using UnityEngine.InputSystem;

namespace PeakPack.Companion
{
    /// <summary>
    /// v0.4: testing with friends.
    ///
    /// Remote diagnostics (friend consented in PeakPack, pack allows it, lobby host verified): the friend's companion
    /// sends a scrubbed snapshot when they join, then new relevant lines as they happen, to the lobby host ONLY
    /// (Photon event 172, chunked, rate-limited to ~8 KB/s). The host's companion writes them to
    /// BepInEx\PeakPack-remote-logs\&lt;friend&gt;.log. The host asks for fresh snapshots with Ctrl+F9 or a command file
    /// (event 171); friends see a notice either way.
    ///
    /// Live updates (test lobby + friend opted in): the host announces a new revision (event 173); the friend's
    /// companion starts the friend's own installed PeakPack.exe --hot-update, which verifies the signed manifest and
    /// hashes and swaps only reload-safe own builds (AutoReload then loads them). The companion never downloads or
    /// loads code itself, and the event carries nothing but a revision number.
    ///
    /// Host commands: the CLI / Host window / agents drop JSON files into BepInEx\PeakPack\commands\; the host's
    /// companion turns them into the events above.
    /// </summary>
    public partial class Plugin
    {
        const byte EvSnapshotRequest = 171, EvLogChunk = 172, EvHotUpdate = 173; // PEAK uses 1-4 and 18; Photon 200+
        const string Magic = "PPK1";                                               // ignore other mods' events on these codes
        const float HotUpdateTimeout = 120f;

        Diagnostics _diag;
        RemoteLogWriter _remote;
        readonly RateLimiter _sendLimit = new RateLimiter(DiagLogic.BytesPerSecond, DiagLogic.BytesPerSecond * 2);
        readonly LinkedList<(string Kind, string Text)> _outbox = new LinkedList<(string, string)>();
        string _packInfoPath, _commandsDir;
        DateTime _packInfoTime;
        float _nextPackInfoCheck;
        string _diagSentFor, _hostIdWritten;
        int _seq;
        float _hotWaitUntil = -1f;
        DateTime _hotResultBefore;
        int _hotRev;
        readonly Dictionary<int, float> _gotLogsNotice = new Dictionary<int, float>();
        ConfigEntry<Key> _requestKey;

        string HotResultPath => Path.Combine(Paths.BepInExRootPath, "PeakPack", "hot-update-result.json");

        void StartTesting(string packInfoPath)
        {
            _packInfoPath = packInfoPath;
            _packInfoTime = SafeTime(packInfoPath);
            _commandsDir = Path.Combine(Paths.BepInExRootPath, "PeakPack", "commands");
            _remote = new RemoteLogWriter(Logger);
            _diag = new Diagnostics { OwnModFolders = _info.ownModFolders };
            _diag.Attach();
            _requestKey = Config.Bind("Host", "RequestLogsKey", Key.F9, "Host only: Ctrl + this key asks everyone in your lobby for fresh logs.");
            Logger.LogInfo($"Diagnostics sharing: {(_info.diagnostics ? "on" : "off")}; live updates: {(_info.liveUpdates ? "on" : "off")}; host ids: {_info.hostIds.Count}");
        }

        void StopTesting()
        {
            _diag?.Dispose();
            _diag = null;
            _outbox.Clear();
            _hotProcess?.Dispose(); // never killed: a running update finishes on its own
            _hotProcess = null;
        }

        void OnJoinedRoomTesting() { _diagSentFor = null; _gotLogsNotice.Clear(); _remote?.Reset(); _lastRequestAt = -100f; }
        void OnLeftRoomTesting() { _outbox.Clear(); _diag?.ClearLive(); _remote?.Reset(); }
        float _lastRequestAt = -100f;
        int _lastHotRevStarted;
        Process _hotProcess;

        static DateTime SafeTime(string f) { try { return File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue; } catch { return DateTime.MinValue; } }

        /// <summary>Every frame (cheap): the host's "request logs" hotkey.</summary>
        void PollHotkey()
        {
            if (_info == null || _requestKey == null || !PhotonNetwork.InRoom || !IsHost) return;
            var kb = Keyboard.current;
            if (kb == null) return;
            try
            {
                if (_requestKey.Value == Key.None) return;
                var key = kb[_requestKey.Value]; // may be null for keys missing on this layout
                if (key != null && key.wasPressedThisFrame && (kb.leftCtrlKey.isPressed || kb.rightCtrlKey.isPressed))
                    RequestSnapshots();
            }
            catch (Exception) { _requestKey = null; } // never let a bad key break Update every frame
        }

        /// <summary>Once a second.</summary>
        void TickTesting()
        {
            ReloadPackInfoIfChanged();
            _diag?.RefreshOwnSources();
            if (!PhotonNetwork.InRoom || _diag == null) return;
            RecordHostId();
            if (IsHost)
            {
                ProcessCommands();
                return;
            }
            if (CanRelay())
            {
                var room = PhotonNetwork.CurrentRoom.Name;
                if (_diagSentFor != room && Character.localCharacter != null) { _diagSentFor = room; QueueSnapshot("joined the lobby"); }
                var live = _diag.TakeLive(DiagLogic.ChunkChars);
                if (live != null) Enqueue("live", live);
                PumpOutbox();
            }
            else { _diag.ClearLive(); _outbox.Clear(); }
            CheckHotResult();
        }

        // ---------- who may receive / send ----------

        /// <summary>The lobby host runs the same pack and (if the signed pack lists host ids) is one of them.</summary>
        bool HostVerified()
        {
            var master = PhotonNetwork.MasterClient;
            if (master == null || master.IsLocal) return false;
            if (!string.Equals(RoomPack(), _info.packId, StringComparison.OrdinalIgnoreCase)) return false;
            return _info.hostIds.Count == 0 || _info.hostIds.Contains(master.UserId ?? "");
        }

        // Logs go only to a host named in the signed pack: with no host ids yet, nothing is relayed.
        bool CanRelay() => _info.diagnostics && _info.hostIds.Count > 0 && HostVerified();

        void RecordHostId()
        {
            // Lets the publisher put the host's id into the signed pack (see PublishConfig.EffectiveHostIds).
            if (!IsHost) return;
            var id = PhotonNetwork.LocalPlayer?.UserId;
            if (string.IsNullOrEmpty(id) || id == _hostIdWritten) return;
            try
            {
                File.WriteAllText(Path.Combine(Paths.BepInExRootPath, "PeakPack", "host-id.txt"), id);
                _hostIdWritten = id;
            }
            catch (Exception e) { Logger.LogWarning("Couldn't record host id: " + e.Message); }
        }

        void ReloadPackInfoIfChanged()
        {
            if (Time.unscaledTime < _nextPackInfoCheck) return;
            _nextPackInfoCheck = Time.unscaledTime + 2f;
            var t = SafeTime(_packInfoPath);
            if (t == _packInfoTime) return;
            _packInfoTime = t;
            var fresh = PackInfoDto.Load(_packInfoPath, Logger);
            if (fresh == null)
            {
                // Missing or unreadable: fail closed for anything that shares or changes things.
                _info.diagnostics = false;
                _info.liveUpdates = false;
                _outbox.Clear();
                return;
            }
            bool revChanged = fresh.revision != _info.revision;
            if (revChanged) _evaluatedFor = null; // re-run the lobby check (also cancels a pending "block" leave once we match)
            _info = fresh;
            if (_diag != null) _diag.OwnModFolders = fresh.ownModFolders;
            Logger.LogInfo($"pack-info.json changed: rev {fresh.revision}, diagnostics {(fresh.diagnostics ? "on" : "off")}, live updates {(fresh.liveUpdates ? "on" : "off")}");
            if (revChanged && PhotonNetwork.InRoom)
            {
                SetPlayerProperties();
                if (IsHost) PushRoomProperties(true);
            }
        }

        // ---------- friend: sending logs ----------

        void QueueSnapshot(string reason)
        {
            var nick = LobbyCheck.SafeName(PhotonNetwork.LocalPlayer?.NickName);
            foreach (var c in DiagLogic.Chunk(_diag.BuildSnapshot(_info, nick, reason))) Enqueue("snapshot", c);
        }

        void Enqueue(string kind, string text)
        {
            _outbox.AddLast((kind, text));
            while (_outbox.Count > 60) _outbox.RemoveFirst(); // never build an unbounded backlog
        }

        void PumpOutbox()
        {
            var master = PhotonNetwork.MasterClient;
            if (master == null) return;
            var opts = new RaiseEventOptions { TargetActors = new[] { master.ActorNumber } }; // the lobby host only
            while (_outbox.Count > 0)
            {
                var (kind, text) = _outbox.First.Value;
                if (!_sendLimit.TryTake(text.Length, Time.unscaledTime)) break;
                _outbox.RemoveFirst();
                PhotonNetwork.RaiseEvent(EvLogChunk, new object[] { Magic, kind, _seq++, text, _info.packId + " rev " + _info.revision }, opts, SendOptions.SendReliable);
            }
        }

        // ---------- host: commands, requests ----------

        void RequestSnapshots()
        {
            PhotonNetwork.RaiseEvent(EvSnapshotRequest, new object[] { Magic, DateTime.UtcNow.Ticks.ToString() },
                new RaiseEventOptions { Receivers = ReceiverGroup.Others }, SendOptions.SendReliable);
            _feed.Post("Asked everyone for their logs. They arrive in BepInEx\\PeakPack-remote-logs.", warning: false, sound: false);
        }

        void AnnounceRevision(int revision)
        {
            PhotonNetwork.RaiseEvent(EvHotUpdate, new object[] { Magic, revision },
                new RaiseEventOptions { Receivers = ReceiverGroup.Others }, SendOptions.SendReliable);
            _feed.Post("Told the lobby about mod pack rev " + revision + ".", warning: false, sound: false);
        }

        void ProcessCommands()
        {
            if (!Directory.Exists(_commandsDir)) return;
            foreach (var file in Directory.GetFiles(_commandsDir, "*.json").OrderBy(f => f, StringComparer.Ordinal))
            {
                CommandDto cmd = null;
                var written = SafeTime(file);
                try { cmd = JsonUtility.FromJson<CommandDto>(File.ReadAllText(file)); }
                catch (Exception e) { Logger.LogWarning("Bad command file " + file + ": " + e.Message); }
                try { File.Delete(file); } catch { continue; }
                if (cmd == null || DateTime.UtcNow - written > TimeSpan.FromMinutes(10)) continue; // stale: game wasn't hosting
                Logger.LogInfo("Host command: " + cmd.command + (cmd.revision > 0 ? " " + cmd.revision : ""));
                if (cmd.command == "snapshot") RequestSnapshots();
                else if (cmd.command == "hot-update" && cmd.revision > 0) AnnounceRevision(cmd.revision);
            }
        }

        // ---------- events ----------

        public void OnEvent(EventData e)
        {
            if (_info == null || (e.Code != EvSnapshotRequest && e.Code != EvLogChunk && e.Code != EvHotUpdate)) return;
            if (!(e.CustomData is object[] d) || d.Length < 2 || !(d[0] is string m) || m != Magic) return;
            try
            {
                var master = PhotonNetwork.MasterClient;
                switch (e.Code)
                {
                    case EvSnapshotRequest:
                        if (IsHost || master == null || e.Sender != master.ActorNumber || !HostVerified()) return;
                        if (Time.unscaledTime - _lastRequestAt < 20f) return; // one request per 20 s is plenty
                        _lastRequestAt = Time.unscaledTime;
                        if (_info.diagnostics && _info.hostIds.Count > 0)
                        {
                            _feed.Post(Feed.Name(HostNick()) + " asked for your PEAK logs to fix a mod. Sending them now.", warning: false);
                            QueueSnapshot("host asked");
                        }
                        else _feed.Post(Feed.Name(HostNick()) + " asked for your PEAK logs. Sharing is off in PeakPack.", warning: false, sound: false);
                        break;

                    case EvLogChunk:
                        if (!IsHost || d.Length < 5) return;
                        var p = PhotonNetwork.CurrentRoom?.GetPlayer(e.Sender);
                        // Only from players running our pack (their companion publishes pp.pack); others are ignored.
                        if (p == null || !string.Equals(p.CustomProperties[KPack] as string, _info.packId, StringComparison.OrdinalIgnoreCase)) return;
                        var nick = LobbyCheck.SafeName(p?.NickName);
                        var kind = d[1] as string ?? "live";
                        _remote.Write(e.Sender, nick, kind == "snapshot" ? "snapshot" : "live", d[3] as string ?? "", d[4] as string ?? "");
                        if (kind == "snapshot" && (!_gotLogsNotice.TryGetValue(e.Sender, out var t) || Time.unscaledTime - t > 60f))
                        {
                            _gotLogsNotice[e.Sender] = Time.unscaledTime;
                            _feed.Post("Got logs from " + Feed.Name(nick) + ".", warning: false, sound: false);
                        }
                        break;

                    case EvHotUpdate:
                        if (IsHost || master == null || e.Sender != master.ActorNumber || !HostVerified() || !(d[1] is int rev) || rev <= _info.revision) return;
                        StartHotUpdate(rev);
                        break;
                }
            }
            catch (Exception ex) { Logger.LogWarning("PeakPack event " + e.Code + " failed: " + ex.Message); }
        }

        // ---------- friend: live updates ----------

        void StartHotUpdate(int rev)
        {
            if (!_info.liveUpdates)
            {
                _feed.Post(LobbyCheck.UpdateMessage("restart-needed", HostNick(), null, rev, _info.shortcutName, Feed.Name), warning: true);
                return;
            }
            if (_hotWaitUntil > 0 || (_hotProcess != null && !_hotProcess.HasExited)) return; // one at a time
            if (rev <= _lastHotRevStarted) return;                                              // each revision once
            var exe = _info.appExe;
            // Only PeakPack's own installed app, sitting next to this profile (<data>\PeakPack.exe, <data>\profile\BepInEx).
            var dataDir = Directory.GetParent(Directory.GetParent(Paths.BepInExRootPath).FullName).FullName;
            if (string.IsNullOrEmpty(exe) || !File.Exists(exe) ||
                !string.Equals(Path.GetFileName(exe), "PeakPack.exe", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetDirectoryName(Path.GetFullPath(exe)), dataDir, StringComparison.OrdinalIgnoreCase))
            {
                Logger.LogWarning("Live update: PeakPack.exe not found next to the profile (" + exe + ").");
                _feed.Post(LobbyCheck.UpdateMessage("restart-needed", HostNick(), null, rev, _info.shortcutName, Feed.Name), warning: true);
                return;
            }
            _hotResultBefore = SafeTime(HotResultPath);
            var args = string.Join(" ", _info.appArgs.Concat(new[] { "--hot-update" }).Select(a => a.IndexOf(' ') >= 0 ? "\"" + a + "\"" : a));
            _hotProcess?.Dispose();
            _hotProcess = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = dataDir });
            _hotWaitUntil = Time.unscaledTime + HotUpdateTimeout;
            _hotRev = rev;
            _lastHotRevStarted = rev;
            Logger.LogInfo($"Live update to rev {rev}: started {exe} {args}");
        }

        void CheckHotResult()
        {
            if (_hotWaitUntil < 0) return;
            if (SafeTime(HotResultPath) > _hotResultBefore)
            {
                _hotWaitUntil = -1f;
                HotResultDto r = null;
                try { r = JsonUtility.FromJson<HotResultDto>(File.ReadAllText(HotResultPath)); } catch { }
                var status = r?.status ?? "failed";
                Logger.LogInfo($"Live update result: {status} {r?.message}");
                var msg = LobbyCheck.UpdateMessage(status, HostNick(), r?.mods, r?.revision ?? _hotRev, _info.shortcutName, Feed.Name);
                if (msg != null) _feed.Post(msg, warning: status != "applied");
            }
            else if (Time.unscaledTime > _hotWaitUntil && (_hotProcess == null || _hotProcess.HasExited))
            {
                // Only give up once PeakPack has really finished (a slow download just takes longer).
                _hotWaitUntil = -1f;
                _feed.Post(LobbyCheck.UpdateMessage("failed", HostNick(), null, _hotRev, _info.shortcutName, Feed.Name), warning: true);
            }
        }
    }

#pragma warning disable CS0649 // fields are filled by Unity's JsonUtility
    [Serializable]
    internal class CommandDto
    {
        public string command = "";
        public int revision;
        public string id = "";
    }

    [Serializable]
    internal class HotResultDto
    {
        public string status = "";
        public int revision;
        public List<string> mods = new List<string>();
        public string message = "";
    }
#pragma warning restore CS0649
}
