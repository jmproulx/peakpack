// PeakPack TestDrive (MIT, our code). TEST ONLY: never in the pack, never sent to friends.
// BepInEx 5 plugin for the Mac test kit's G-A2-lite --test-drive: from PEAK's main menu it starts a SOLO run (or
// hosts, StartMode = Host), starts the expedition at the airport kiosk, and on the island walks the scout forward
// (with a slow look-around) for N seconds while PeakPack.MacPreset's frame-time log runs. It replaces held keys,
// which the hub's computer-use agent cannot do.
//
// Runtime safety (the PEAK modding rules learned 11 Oct, ScoutmasterMode DESIGN §11b):
//  - No compile-time reference to PEAK's Assembly-CSharp or Photon. Every game type/member is found by NAME through
//    cached reflection/AccessTools accessors, so our IL never references a game member and PEAK's Mono cannot throw
//    FieldAccessException/MethodAccessException when our methods are JIT-compiled.
//  - Inactive = zero work: without WalkSeconds > 0 in its config, Awake logs one line and returns (no patch).
//  - Every hook: `if (!Live) return;` then the work in a separate [NoInlining] method inside try/catch. Any
//    failure trips Guard: one log line, the Harmony patch is removed, the plugin goes inert, vanilla runs.
//  - Startup resolves every required accessor first; if any is missing it stays inert ("TESTDRIVE inert ...").
// Log: every line goes to BepInEx/PeakPack/testdrive.log (flushed at once: BepInEx's LogOutput.log is buffered and
// lagged behind in 0.1.0) and to the BepInEx log. All lines start with "TESTDRIVE ".
using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using HarmonyLib;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace PeakPack.TestDrive
{
    [BepInPlugin(Guid, "PeakPack TestDrive (test only)", Version)]
    public class Plugin : BaseUnityPlugin
    {
        public const string Guid = "com.peakpack.testdrive";
        public const string Version = "0.2.0";

        internal static ManualLogSource Log;
        internal static bool Live;           // master switch; false = vanilla behaviour, zero work in the hooks
        internal static bool Walking;        // the Sample postfix overrides input only while this is true
        internal static float WalkStartedAt;
        private static Harmony _harmony;
        private static bool _tripped;
        private static StreamWriter _file;

        private ConfigEntry<float> _walkSeconds, _goWaitSeconds, _stageTimeout;
        private ConfigEntry<int> _ascent;
        private ConfigEntry<string> _startMode;
        private GameObject _host;

        internal static void Note(string msg, bool error = false)
        {
            string line = "TESTDRIVE " + msg;
            try { _file?.WriteLine(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + " " + line); } catch { }
            if (error) Log?.LogError(line); else Log?.LogInfo(line);
        }

        private void Awake()
        {
            Log = Logger;
            _walkSeconds = Config.Bind("TestDrive", "WalkSeconds", 0f, "0 = inactive. Seconds to walk on the island.");
            _goWaitSeconds = Config.Bind("TestDrive", "GoWaitSeconds", 900f,
                "At the main menu, wait up to this long for the kit's go file (BepInEx/config/peakpack.testdrive.go).");
            _stageTimeout = Config.Bind("TestDrive", "StageTimeoutSeconds", 600f, "Give up when a stage takes longer.");
            _ascent = Config.Bind("TestDrive", "Ascent", 0, "Ascent passed to the kiosk (0 = the default the boarding pass uses).");
            _startMode = Config.Bind("TestDrive", "StartMode", "Solo", "Solo = main menu Play Solo (offline); Host = main menu Host.");
            if (_walkSeconds.Value <= 0f) { Log.LogInfo("TESTDRIVE off (WalkSeconds = 0)"); return; }
            try
            {
                string dir = Path.Combine(Paths.BepInExRootPath, "PeakPack");
                Directory.CreateDirectory(dir);
                _file = new StreamWriter(new FileStream(Path.Combine(dir, "testdrive.log"), FileMode.Create, FileAccess.Write, FileShare.ReadWrite)) { AutoFlush = true };
            }
            catch (Exception e) { Log.LogWarning("TESTDRIVE no status file: " + e.Message); }
            try
            {
                if (!Game.Resolve(out string missing)) { Note("inert: game member not found: " + missing, true); return; }
                _harmony = new Harmony(Guid);
                _harmony.Patch(Game.SampleMethod, postfix: new HarmonyMethod(typeof(Plugin), nameof(SamplePostfix)));
                Live = true;
                _host = new GameObject("PeakPack.TestDrive");
                _host.hideFlags = HideFlags.HideAndDontSave;
                DontDestroyOnLoad(_host);
                bool host = string.Equals(_startMode.Value, "Host", StringComparison.OrdinalIgnoreCase);
                _host.AddComponent<Driver>().Init(_walkSeconds.Value, _goWaitSeconds.Value, _stageTimeout.Value, _ascent.Value, host,
                    Path.Combine(Paths.ConfigPath, "peakpack.testdrive.go"));
                SceneManager.activeSceneChanged += OnSceneChanged;
                Note("active walk_seconds=" + _walkSeconds.Value + " start=" + (host ? "host" : "solo") + " version=" + Version
                     + " photon=" + Game.PhotonAvailable);
            }
            catch (Exception e) { Trip("start", e); }
        }

        private static void OnSceneChanged(Scene from, Scene to)
        {
            if (!Live) return;
            try { Note("scene_loaded name=" + to.name + " " + Game.NetState()); } catch (Exception e) { Trip("scene_event", e); }
        }

        private void OnDestroy()
        {
            SceneManager.activeSceneChanged -= OnSceneChanged;
            Unpatch();
            if (_host != null) Destroy(_host);
            try { _file?.Dispose(); } catch { }
            _file = null;
        }

        internal static void Trip(string where, Exception e)
        {
            Live = false; Walking = false;
            if (_tripped) return;
            _tripped = true;
            Note("fail stage=" + where + " reason=" + (e == null ? "?" : e.GetType().Name + ": " + e.Message), true);
            Unpatch();
        }

        private static void Unpatch()
        {
            try { _harmony?.UnpatchSelf(); } catch (Exception e) { Log?.LogWarning("TESTDRIVE unpatch: " + e.Message); }
            _harmony = null;
        }

        // Harmony postfix on CharacterInput.Sample (internal; patched by MethodInfo, never called from our IL).
        public static void SamplePostfix(object __instance)
        {
            if (!Live || !Walking) return;
            try { OverrideInput(__instance); } catch (Exception e) { Trip("sample_postfix", e); }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void OverrideInput(object input)
        {
            object local = Game.LocalCharacter();
            if (local == null || !ReferenceEquals(Game.InputOf(local), input)) return;
            float t = Time.time - WalkStartedAt;
            Game.MovementInput.SetValue(input, new Vector2(0f, 1f));                      // hold W
            Game.LookInput.SetValue(input, new Vector2(0.6f * Mathf.Sin(t * 0.4f), 0f));  // slow look left/right
            // a short hop every 6 s gets the scout over small rocks
            if (Game.JumpWasPressed != null && (int)(t / 6f) != (int)((t - Time.deltaTime) / 6f)) Game.JumpWasPressed.SetValue(input, true);
        }
    }

    /// <summary>Cached accessors for the game members we use, found by name (no compile-time game reference).</summary>
    internal static class Game
    {
        internal static Type MainMenuT, FirstTimeT, KioskT, CharacterT, CharacterInputT, CharacterDataT, LoadingT, GameHandlerT,
            RunSettingsT, PhotonT;
        internal static MethodInfo SampleMethod, KioskStartGame, KioskLoadIslandMaster, SerializedRunSettings;
        internal static FieldInfo PlaySoloButton, HostButton, ContinueButton, LocalCharacterF, InputF, DataF, PassedOutOnBeach,
            MovementInput, LookInput, JumpWasPressed;
        internal static MemberInfo FullyConscious, Dead, Loading, InGameplay, InRoom, OfflineMode, IsMaster;
        internal static bool PhotonAvailable => PhotonT != null;

        internal static bool Resolve(out string missing)
        {
            missing = null;
            MainMenuT = T("MainMenu", ref missing); FirstTimeT = T("MainMenuFirstTimeSetupPage", ref missing);
            KioskT = T("AirportCheckInKiosk", ref missing); CharacterT = T("Character", ref missing);
            CharacterInputT = T("CharacterInput", ref missing); CharacterDataT = T("CharacterData", ref missing);
            LoadingT = T("LoadingScreenHandler", ref missing); GameHandlerT = T("GameHandler", ref missing);
            if (missing != null) return false;
            RunSettingsT = AccessTools.TypeByName("RunSettings");                         // optional (direct island load)
            PhotonT = AccessTools.TypeByName("Photon.Pun.PhotonNetwork");                  // optional (diagnostics)
            SampleMethod = AccessTools.Method(CharacterInputT, "Sample", new[] { typeof(bool) });
            KioskStartGame = AccessTools.Method(KioskT, "StartGame", new[] { typeof(int) });
            KioskLoadIslandMaster = AccessTools.Method(KioskT, "LoadIslandMaster", new[] { typeof(int), typeof(byte[]) });
            SerializedRunSettings = RunSettingsT == null ? null : AccessTools.Method(RunSettingsT, "GetSerializedRunSettings", Type.EmptyTypes);
            PlaySoloButton = AccessTools.Field(MainMenuT, "playSoloButton");
            HostButton = AccessTools.Field(MainMenuT, "hostButton");
            ContinueButton = AccessTools.Field(FirstTimeT, "ContinueButton");
            LocalCharacterF = AccessTools.Field(CharacterT, "localCharacter");
            InputF = AccessTools.Field(CharacterT, "input");
            DataF = AccessTools.Field(CharacterT, "data");
            PassedOutOnBeach = AccessTools.Field(CharacterDataT, "passedOutOnTheBeach");
            MovementInput = AccessTools.Field(CharacterInputT, "movementInput");
            LookInput = AccessTools.Field(CharacterInputT, "lookInput");
            JumpWasPressed = AccessTools.Field(CharacterInputT, "jumpWasPressed");   // optional
            FullyConscious = FieldOrProperty(CharacterDataT, "fullyConscious");
            Dead = FieldOrProperty(CharacterDataT, "dead");
            Loading = FieldOrProperty(LoadingT, "loading") ?? FieldOrProperty(LoadingT, "_loading");
            InGameplay = FieldOrProperty(GameHandlerT, "IsInGameplayScene");
            if (PhotonT != null)
            {
                InRoom = FieldOrProperty(PhotonT, "InRoom");
                OfflineMode = FieldOrProperty(PhotonT, "OfflineMode");
                IsMaster = FieldOrProperty(PhotonT, "IsMasterClient");
            }
            foreach (var (name, m) in new (string, object)[] {
                ("CharacterInput.Sample", SampleMethod), ("AirportCheckInKiosk.StartGame", KioskStartGame),
                ("MainMenu.playSoloButton", PlaySoloButton), ("MainMenuFirstTimeSetupPage.ContinueButton", ContinueButton),
                ("Character.localCharacter", LocalCharacterF), ("Character.input", InputF), ("Character.data", DataF),
                ("CharacterData.passedOutOnTheBeach", PassedOutOnBeach), ("CharacterInput.movementInput", MovementInput),
                ("CharacterInput.lookInput", LookInput), ("CharacterData.fullyConscious", FullyConscious),
                ("LoadingScreenHandler.loading", Loading) })
                if (m == null) { missing = name; return false; }
            return true;
        }

        private static Type T(string name, ref string missing)
        {
            var t = AccessTools.TypeByName(name);
            if (t == null && missing == null) missing = name;
            return t;
        }

        private static MemberInfo FieldOrProperty(Type t, string name) =>
            (MemberInfo)AccessTools.Field(t, name) ?? AccessTools.Property(t, name);

        internal static object Get(MemberInfo m, object target)
        {
            if (m is FieldInfo f) return f.GetValue(target);
            if (m is PropertyInfo p) return p.GetValue(target, null);
            return null;
        }

        internal static bool Bool(MemberInfo m, object target, bool fallback)
        {
            if (m == null) return fallback;
            object v = Get(m, target);
            return v is bool b ? b : fallback;
        }

        internal static string Tri(MemberInfo m) => m == null ? "?" : Bool(m, null, false) ? "1" : "0";

        internal static object LocalCharacter()
        {
            object c = LocalCharacterF.GetValue(null);
            return c is UnityEngine.Object uo && uo == null ? null : c;   // destroyed Unity objects compare equal to null
        }

        internal static object InputOf(object character) => InputF.GetValue(character);
        internal static object DataOf(object character) => DataF.GetValue(character);
        internal static bool IsLoading() => Bool(Loading, null, true);
        internal static bool InGameplayScene() => Bool(InGameplay, null, false);

        internal static string NetState() =>
            "loading=" + (IsLoading() ? 1 : 0) + " local=" + (LocalCharacter() != null ? 1 : 0)
            + " in_room=" + Tri(InRoom) + " offline=" + Tri(OfflineMode) + " master=" + Tri(IsMaster);

        /// <summary>Invokes a UnityEngine.UI.Button's onClick (by reflection: no UI assembly reference).</summary>
        internal static bool Click(object button)
        {
            if (button == null || (button is UnityEngine.Object uo && uo == null)) return false;
            object onClick = AccessTools.Property(button.GetType(), "onClick")?.GetValue(button, null);
            MethodInfo invoke = onClick == null ? null : AccessTools.Method(onClick.GetType(), "Invoke", Type.EmptyTypes);
            if (invoke == null) return false;
            invoke.Invoke(onClick, null);
            return true;
        }

        internal static bool ActiveInHierarchy(object component) =>
            component is Component c && c != null && c.gameObject.activeInHierarchy;
    }

    /// <summary>The stage machine, driven from Update. Every stage has a timeout; any exception trips the guard.
    /// A stage that waits for a scene advances only when that scene is the active one (confirmed scene change).</summary>
    internal class Driver : MonoBehaviour
    {
        private enum Stage { Menu, WaitGo, Start, Airport, Kiosk, LevelLoad, Island, Walk, Done }

        private Stage _stage = Stage.Menu;
        private float _walkSeconds, _goWait, _stageTimeout, _stageStart, _nextProgress, _settleUntil, _nextBeat, _loadTry;
        private int _ascent, _loadAttempt;
        private bool _host, _firstTimeContinued;
        private string _goFile, _sceneAtLoad;
        private Vector3 _startPos;
        private object _kiosk;

        internal void Init(float walkSeconds, float goWait, float stageTimeout, int ascent, bool host, string goFile)
        {
            _walkSeconds = walkSeconds; _goWait = goWait; _stageTimeout = stageTimeout; _ascent = ascent; _host = host; _goFile = goFile;
            Enter(Stage.Menu);
        }

        private static string Scene => SceneManager.GetActiveScene().name;

        private void Enter(Stage s)
        {
            _stage = s; _stageStart = Time.realtimeSinceStartup; _settleUntil = 0f; _nextBeat = _stageStart + 15f;
            Plugin.Note("stage=" + s.ToString().ToLowerInvariant() + " scene=" + Scene + " " + Game.NetState());
        }

        private float InStage => Time.realtimeSinceStartup - _stageStart;

        private void Update()
        {
            if (!Plugin.Live || _stage == Stage.Done) return;
            try { Step(); } catch (Exception e) { Plugin.Trip(_stage.ToString().ToLowerInvariant(), e); }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private void Step()
        {
            float limit = _stage == Stage.WaitGo ? _goWait + 30f : _stage == Stage.Walk ? _walkSeconds + 60f : _stageTimeout;
            if (InStage > limit) { Plugin.Trip(_stage.ToString().ToLowerInvariant() + "_timeout", new TimeoutException(InStage.ToString("F0") + " s in scene " + Scene + " " + Game.NetState())); return; }
            if (_stage != Stage.Walk && _stage != Stage.WaitGo && Time.realtimeSinceStartup >= _nextBeat)
            {   // heartbeat: what the current stage is waiting for
                _nextBeat += 15f;
                Plugin.Note("wait stage=" + _stage.ToString().ToLowerInvariant() + " t=" + InStage.ToString("F0") + " scene=" + Scene + " " + Game.NetState());
            }
            switch (_stage)
            {
                case Stage.Menu:
                    // PEAK's first-launch microphone chooser: press its Continue (selection unchanged)
                    var first = UnityEngine.Object.FindFirstObjectByType(Game.FirstTimeT);
                    if (!_firstTimeContinued && first != null && Game.ActiveInHierarchy(first) && Game.Click(Game.ContinueButton.GetValue(first)))
                    { _firstTimeContinued = true; Plugin.Note("first_time_continue"); return; }
                    var menu = UnityEngine.Object.FindFirstObjectByType(Game.MainMenuT);
                    if (menu != null && Game.ActiveInHierarchy(menu) && !Game.IsLoading()) Enter(Stage.WaitGo);
                    break;
                case Stage.WaitGo:
                    // the kit writes the go file after its main-menu screenshot/fps step (or the wait ends)
                    if (File.Exists(_goFile) || InStage > _goWait)
                    { Plugin.Note("go=" + (File.Exists(_goFile) ? "file" : "timeout")); Enter(Stage.Start); }
                    break;
                case Stage.Start:
                    var mm = UnityEngine.Object.FindFirstObjectByType(Game.MainMenuT);
                    if (mm == null) break;
                    FieldInfo bf = _host && Game.HostButton != null ? Game.HostButton : Game.PlaySoloButton;
                    object button = bf.GetValue(mm);
                    Plugin.Note("button_found name=" + bf.Name + " active=" + (Game.ActiveInHierarchy(button) ? 1 : 0));
                    if (Game.Click(button)) { Plugin.Note("button_clicked name=" + bf.Name + "; waiting for scene Airport"); Enter(Stage.Airport); }
                    else Plugin.Trip("start", new InvalidOperationException("could not click " + bf.Name));
                    break;
                case Stage.Airport:
                    // advance only on the confirmed scene change, then loading done and our scout spawned
                    if (Scene != "Airport" || Game.IsLoading() || Game.LocalCharacter() == null) break;
                    if (_settleUntil == 0f) { _settleUntil = Time.realtimeSinceStartup + 8f; Plugin.Note("airport_ready " + Game.NetState()); break; }
                    if (Time.realtimeSinceStartup >= _settleUntil) Enter(Stage.Kiosk);
                    break;
                case Stage.Kiosk:
                    _kiosk = UnityEngine.Object.FindFirstObjectByType(Game.KioskT);
                    if (_kiosk == null) break;
                    Plugin.Note("kiosk_found " + Game.NetState());
                    _sceneAtLoad = Scene; _loadAttempt = 0;
                    Enter(Stage.LevelLoad);
                    TryLoad();
                    break;
                case Stage.LevelLoad:
                    if (Game.IsLoading() || Scene != _sceneAtLoad)
                    {
                        Plugin.Note("level_load_requested attempt=" + _loadAttempt + " scene=" + Scene + " " + Game.NetState());
                        Enter(Stage.Island);
                        break;
                    }
                    if (Time.realtimeSinceStartup - _loadTry > 30f)
                    {
                        if (_loadAttempt >= 2) { Plugin.Trip("level_load", new InvalidOperationException("no island load after StartGame and LoadIslandMaster; " + Game.NetState())); break; }
                        TryLoad();
                    }
                    break;
                case Stage.Island:
                    if (!Game.InGameplayScene() || Game.IsLoading()) break;
                    object c = Game.LocalCharacter();
                    if (c == null) break;
                    object d = Game.DataOf(c);
                    bool awake = Game.Bool(Game.FullyConscious, d, false) && !Game.Bool(Game.Dead, d, false)
                                 && (float)Game.PassedOutOnBeach.GetValue(d) <= 0f;
                    if (!awake) break;
                    if (_settleUntil == 0f) { _settleUntil = Time.realtimeSinceStartup + 5f; Plugin.Note("island_awake scene=" + Scene); break; }
                    if (Time.realtimeSinceStartup < _settleUntil) break;
                    _startPos = ((Component)c).transform.position;
                    Plugin.WalkStartedAt = Time.time; Plugin.Walking = true; _nextProgress = Time.realtimeSinceStartup + 10f;
                    Plugin.Note("island_ready scene=" + Scene);
                    Enter(Stage.Walk);
                    Plugin.Note("walk_start seconds=" + _walkSeconds);
                    break;
                case Stage.Walk:
                    object wc = Game.LocalCharacter();
                    float dist = wc == null ? -1f : Vector3.Distance(_startPos, ((Component)wc).transform.position);
                    if (Time.realtimeSinceStartup >= _nextProgress)
                    { _nextProgress += 10f; Plugin.Note("walk_progress t=" + InStage.ToString("F0") + " dist=" + dist.ToString("F1")); }
                    if (InStage >= _walkSeconds)
                    {
                        Plugin.Walking = false;
                        Plugin.Note("walk_end seconds=" + InStage.ToString("F0") + " dist=" + dist.ToString("F1"));
                        Enter(Stage.Done);
                        Plugin.Live = false;
                    }
                    break;
            }
        }

        // attempt 1: the kiosk's own StartGame(ascent) (what the boarding pass's Start button calls; RPC to the master
        // client). attempt 2: LoadIslandMaster(ascent, run settings) called directly (skips the RPC; still needs host).
        private void TryLoad()
        {
            _loadAttempt++; _loadTry = Time.realtimeSinceStartup;
            if (_loadAttempt == 1)
            {
                Game.KioskStartGame.Invoke(_kiosk, new object[] { _ascent });
                Plugin.Note("kiosk_start_called ascent=" + _ascent + " " + Game.NetState());
            }
            else if (Game.KioskLoadIslandMaster != null && Game.SerializedRunSettings != null)
            {
                object rs = Game.SerializedRunSettings.Invoke(null, null);
                Game.KioskLoadIslandMaster.Invoke(_kiosk, new object[] { _ascent, rs });
                Plugin.Note("load_island_master_called ascent=" + _ascent + " " + Game.NetState());
            }
            else Plugin.Note("load_island_master_unavailable");
        }
    }
}
