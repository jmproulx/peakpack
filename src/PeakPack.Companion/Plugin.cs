using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BepInEx;
using BepInEx.Bootstrap;
using BepInEx.Configuration;
using ExitGames.Client.Photon;
using Photon.Pun;
using Photon.Realtime;
using UnityEngine;
using PhotonPlayer = Photon.Realtime.Player;

namespace PeakPack.Companion
{
    /// <summary>
    /// PeakPack's in-game companion. Shipped in every pack; does nothing unless the PeakPack profile has a
    /// pack-info.json (written by PeakPack on every sync, and by the publisher's "stamp" for the host's own game).
    ///
    /// Lobby check: each player publishes "pp.pack"/"pp.rev" as Photon player properties; the lobby host (Photon
    /// master client) also publishes them as room properties. A player whose revision differs gets a line in PEAK's
    /// own connection feed; the host gets a line per mismatched player.
    ///
    /// Live settings: BepInEx config entries whitelisted in the (signed) pack follow the lobby host's values while
    /// you're in their lobby ("pp.cfg" room property). Your own values come back when you leave; your config file
    /// is never left with the host's values.
    ///
    /// Reload-safe (Hamunii AutoReload): no Harmony patches, no static state; OnDestroy unregisters the Photon
    /// callbacks and restores any settings it changed.
    /// </summary>
    [BepInPlugin(Guid, "PeakPack Companion", "0.3.0")]
    public class Plugin : BaseUnityPlugin, IInRoomCallbacks, IMatchmakingCallbacks
    {
        public const string Guid = "peakpack.companion";
        const string KPack = "pp.pack", KRev = "pp.rev", KCfg = "pp.cfg";
        const float HostCheckDelay = 12f;    // give a joining player's companion time to publish its properties
        const float BlockLeaveDelay = 10f;

        PackInfoDto _info;
        bool _registered;
        float _nextTick;
        string _evaluatedFor;                 // room name + host rev the client check last ran for
        string _settingsNoticeFor;            // room name the "using the host's settings" line was shown for
        string _lastPushed;                   // signature of the room properties last pushed as host
        float _leaveAt = -1f;
        readonly Dictionary<int, float> _hostChecks = new Dictionary<int, float>();
        readonly HashSet<string> _hostReported = new HashSet<string>();
        readonly Dictionary<string, string> _originals = new Dictionary<string, string>();
        readonly Feed _feed = new Feed();

        void Awake()
        {
            var path = Path.Combine(Paths.BepInExRootPath, "PeakPack", "pack-info.json");
            _info = PackInfoDto.Load(path, Logger);
            if (_info == null)
            {
                Logger.LogInfo("No PeakPack pack-info.json at " + path + "; lobby check is off.");
                return;
            }
            Logger.LogInfo($"PeakPack pack '{_info.packId}' rev {_info.revision} (host {_info.hostName}); live settings: {_info.liveSettings.Count}");
            PhotonNetwork.AddCallbackTarget(this);
            _registered = true;
            if (PhotonNetwork.InRoom) OnJoinedRoom(); // loaded (or reloaded) while already in a lobby
        }

        void OnDestroy()
        {
            if (_registered) PhotonNetwork.RemoveCallbackTarget(this);
            _registered = false;
            RestoreSettings();
        }

        bool IsHost => PhotonNetwork.IsMasterClient;

        void Update()
        {
            if (_info == null || Time.unscaledTime < _nextTick) return;
            _nextTick = Time.unscaledTime + 1f;
            _feed.Flush();
            if (!PhotonNetwork.InRoom) return;

            if (IsHost)
            {
                PushRoomProperties(false);
                RunHostChecks();
            }
            else if (Character.localCharacter != null)
            {
                // Only once the player is actually in the scene (joiners are still loading at OnJoinedRoom).
                var key = PhotonNetwork.CurrentRoom.Name + "#" + RoomRev();
                if (_evaluatedFor != key) { _evaluatedFor = key; EvaluateAsClient(); }
            }

            if (_leaveAt > 0 && Time.unscaledTime >= _leaveAt)
            {
                _leaveAt = -1f;
                Logger.LogInfo("Leaving the lobby: pack revision is older than the host's (mismatchPolicy = block).");
                global::Player.LeaveCurrentGame();
                UnityEngine.SceneManagement.SceneManager.LoadScene("Title");
            }
        }

        // ---------- client side ----------

        string RoomPack() => PhotonNetwork.CurrentRoom?.CustomProperties[KPack] as string;
        int? RoomRev() => PhotonNetwork.CurrentRoom?.CustomProperties[KRev] is int r ? r : (int?)null;
        string HostNick() => LobbyCheck.SafeName(PhotonNetwork.MasterClient?.NickName);

        void EvaluateAsClient()
        {
            var v = LobbyCheck.Compare(_info.packId, _info.revision, RoomPack(), RoomRev());
            Logger.LogInfo($"Lobby check: host pack={RoomPack() ?? "none"} rev={RoomRev()?.ToString() ?? "none"}, mine={_info.packId} rev {_info.revision} -> {v}");
            bool block = v == LobbyCheck.Verdict.YouAreOlder && _info.Block;
            var msg = LobbyCheck.ClientMessage(v, HostNick(), _info.revision, RoomRev() ?? 0, _info.shortcutName, block, Feed.Name);
            if (msg != null) _feed.Post(msg, warning: true);
            if (block) _leaveAt = Time.unscaledTime + BlockLeaveDelay;
            if (v == LobbyCheck.Verdict.Match || v == LobbyCheck.Verdict.YouAreNewer || v == LobbyCheck.Verdict.YouAreOlder)
                ApplyHostSettings(PhotonNetwork.CurrentRoom.CustomProperties[KCfg] as Hashtable);
        }

        // ---------- host side ----------

        void SetPlayerProperties()
        {
            PhotonNetwork.LocalPlayer.SetCustomProperties(new Hashtable { { KPack, _info.packId }, { KRev, _info.revision } });
        }

        void PushRoomProperties(bool force)
        {
            var cfg = new Hashtable();
            foreach (var spec in _info.liveSettings)
            {
                var e = FindEntry(spec);
                if (e != null) cfg[spec] = e.GetSerializedValue();
            }
            var sig = _info.packId + "|" + _info.revision + "|" + string.Join(";", cfg.Keys.Cast<object>().Select(k => k + "=" + cfg[k]).OrderBy(s => s));
            if (!force && sig == _lastPushed) return;
            _lastPushed = sig;
            PhotonNetwork.CurrentRoom.SetCustomProperties(new Hashtable { { KPack, _info.packId }, { KRev, _info.revision }, { KCfg, cfg } });
        }

        void RunHostChecks()
        {
            if (_hostChecks.Count == 0) return;
            foreach (var actor in _hostChecks.Where(kv => Time.unscaledTime >= kv.Value).Select(kv => kv.Key).ToList())
            {
                _hostChecks.Remove(actor);
                var p = PhotonNetwork.CurrentRoom.GetPlayer(actor);
                if (p == null || p.IsLocal) continue;
                var theirPack = p.CustomProperties[KPack] as string;
                var theirRev = p.CustomProperties[KRev] is int r ? r : (int?)null;
                var msg = LobbyCheck.HostMessage(LobbyCheck.SafeName(p.NickName), theirPack, theirRev, _info.packId, _info.revision,
                    _info.modsRequiredToJoin, _info.shortcutName, Feed.Name);
                // Say each distinct thing about a player once per lobby.
                if (msg != null && _hostReported.Add(actor + "|" + theirPack + "|" + theirRev)) _feed.Post(msg, warning: true);
            }
        }

        // ---------- live settings ----------

        static ConfigEntryBase FindEntry(string spec)
        {
            var parts = spec.Split('|');
            if (parts.Length != 3 || !Chainloader.PluginInfos.TryGetValue(parts[0], out var pi) || pi.Instance == null) return null;
            IDictionary<ConfigDefinition, ConfigEntryBase> file = pi.Instance.Config;
            return file.TryGetValue(new ConfigDefinition(parts[1], parts[2]), out var e) ? e : null;
        }

        void ApplyHostSettings(Hashtable cfg)
        {
            if (cfg == null || _info.liveSettings.Count == 0 || RoomPack() == null
                || !string.Equals(RoomPack(), _info.packId, StringComparison.OrdinalIgnoreCase)) return;
            var changedPlugins = new HashSet<string>();
            foreach (var spec in _info.liveSettings) // only keys whitelisted in OUR signed pack, never whatever the room says
            {
                if (!(cfg[spec] is string value)) continue;
                var e = FindEntry(spec);
                if (e == null) continue;
                var mine = e.GetSerializedValue();
                if (!_originals.ContainsKey(spec)) _originals[spec] = mine;
                if (mine == value) continue;
                var file = e.ConfigFile;
                var save = file.SaveOnConfigSet;
                file.SaveOnConfigSet = false; // the host's value lives in memory only
                try { e.SetSerializedValue(value); } // parsed as the entry's type and clamped to its allowed range
                catch (Exception ex) { Logger.LogWarning($"Ignored host value for {spec}: {ex.Message}"); }
                finally { file.SaveOnConfigSet = save; }
                changedPlugins.Add(spec.Split('|')[0]);
            }
            var room = PhotonNetwork.CurrentRoom?.Name;
            if (changedPlugins.Count > 0 && _settingsNoticeFor != room)
            {
                _settingsNoticeFor = room;
                var names = changedPlugins.Select(g => Chainloader.PluginInfos.TryGetValue(g, out var pi) ? pi.Metadata.Name : g);
                _feed.Post("Using " + Feed.Name(HostNick()) + "'s settings for " + string.Join(", ", names) + ".", warning: false, sound: false);
            }
        }

        void RestoreSettings()
        {
            if (_originals.Count == 0) return;
            var files = new HashSet<ConfigFile>();
            foreach (var kv in _originals)
            {
                var e = FindEntry(kv.Key);
                if (e == null) continue;
                var file = e.ConfigFile;
                var save = file.SaveOnConfigSet;
                file.SaveOnConfigSet = false;
                try { e.SetSerializedValue(kv.Value); } catch { }
                finally { file.SaveOnConfigSet = save; }
                if (save) files.Add(file);
            }
            foreach (var f in files) { try { f.Save(); } catch { } } // in case anything saved while the host's values were active
            _originals.Clear();
            Logger.LogInfo("Restored your own values for live settings.");
        }

        // ---------- Photon callbacks ----------

        public void OnJoinedRoom()
        {
            _evaluatedFor = null; _settingsNoticeFor = null; _lastPushed = null; _leaveAt = -1f;
            _hostChecks.Clear(); _hostReported.Clear();
            SetPlayerProperties();
            if (IsHost) PushRoomProperties(true);
        }

        public void OnLeftRoom()
        {
            _leaveAt = -1f;
            _hostChecks.Clear();
            RestoreSettings();
        }

        public void OnMasterClientSwitched(PhotonPlayer newMasterClient)
        {
            if (newMasterClient != null && newMasterClient.IsLocal)
            {
                RestoreSettings();          // we're the host now: our own values apply
                PushRoomProperties(true);
                foreach (var p in PhotonNetwork.PlayerListOthers) _hostChecks[p.ActorNumber] = Time.unscaledTime + 2f;
            }
            else _evaluatedFor = null;
        }

        public void OnRoomPropertiesUpdate(Hashtable propertiesThatChanged)
        {
            if (IsHost || propertiesThatChanged == null) return;
            if (propertiesThatChanged.ContainsKey(KCfg) && _evaluatedFor != null) ApplyHostSettings(propertiesThatChanged[KCfg] as Hashtable);
            if (propertiesThatChanged.ContainsKey(KRev) || propertiesThatChanged.ContainsKey(KPack)) _evaluatedFor = null;
        }

        public void OnPlayerEnteredRoom(PhotonPlayer newPlayer)
        {
            if (IsHost && newPlayer != null) _hostChecks[newPlayer.ActorNumber] = Time.unscaledTime + HostCheckDelay;
        }

        public void OnPlayerPropertiesUpdate(PhotonPlayer targetPlayer, Hashtable changedProps)
        {
            if (IsHost && targetPlayer != null && !targetPlayer.IsLocal && changedProps != null && changedProps.ContainsKey(KRev)
                && _hostChecks.ContainsKey(targetPlayer.ActorNumber))
                _hostChecks[targetPlayer.ActorNumber] = Time.unscaledTime + 1f;
        }

        public void OnPlayerLeftRoom(PhotonPlayer otherPlayer) { if (otherPlayer != null) _hostChecks.Remove(otherPlayer.ActorNumber); }
        public void OnFriendListUpdate(List<FriendInfo> friendList) { }
        public void OnCreatedRoom() { }
        public void OnCreateRoomFailed(short returnCode, string message) { }
        public void OnJoinRoomFailed(short returnCode, string message) { }
        public void OnJoinRandomFailed(short returnCode, string message) { }
    }

    /// <summary>pack-info.json as written by PeakPack (camelCase JSON; parsed with Unity's JsonUtility).</summary>
    [Serializable]
    public class PackInfoDto
    {
        public int schema;
        public string packId = "";
        public string packName = "";
        public string hostName = "";
        public int revision;
        public string shortcutName = "PEAK (Modded)";
        public bool modsRequiredToJoin;
        public string mismatchPolicy = "warn";
        public List<string> liveSettings = new List<string>();

        public bool Block => string.Equals(mismatchPolicy, "block", StringComparison.OrdinalIgnoreCase);

        public static PackInfoDto Load(string path, BepInEx.Logging.ManualLogSource log)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var dto = JsonUtility.FromJson<PackInfoDto>(File.ReadAllText(path));
                if (dto == null || string.IsNullOrEmpty(dto.packId) || dto.revision <= 0) return null;
                if (dto.liveSettings == null) dto.liveSettings = new List<string>();
                return dto;
            }
            catch (Exception e) { log.LogWarning("Couldn't read " + path + ": " + e.Message); return null; }
        }
    }
}
