// PeakPack TestDrive (MIT, our code). TEST ONLY: never in the pack, never sent to friends.
// BepInEx 5 plugin for the Mac test kit's G-A2-lite --test-drive: from PEAK's main menu it starts a SOLO run,
// starts the expedition at the airport kiosk, and on the Shore walks the scout forward (with a slow look-around)
// for N seconds while PeakPack.MacPreset's frame-time log runs. It replaces held keys, which the hub's computer-use
// agent cannot do.
//
// Runtime safety (the PEAK modding rules learned 11 Oct, ScoutmasterMode DESIGN §11b):
//  - No compile-time reference to PEAK's Assembly-CSharp. Every game type/member is found by NAME through cached
//    reflection/AccessTools accessors, so our IL never references a game member and PEAK's Mono cannot throw
//    FieldAccessException/MethodAccessException when our methods are JIT-compiled.
//  - Inactive = zero work: without WalkSeconds > 0 in its config, Awake logs one line and returns (no patch).
//  - Every hook: `if (!Live) return;` then the work in a separate [NoInlining] method inside try/catch. Any
//    failure trips Guard: one log line, the Harmony patch is removed, the plugin goes inert, vanilla runs.
//  - Startup resolves every accessor first; if any is missing it stays inert ("TESTDRIVE inert ...").
// Log lines (LogOutput.log) all start with "TESTDRIVE " so the kit can grep them.
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
        public const string Version = "0.1.0";

        internal static ManualLogSource Log;
        internal static bool Live;           // master switch; false = vanilla behaviour, zero work in the hooks
        internal static bool Walking;        // the Sample postfix overrides input only while this is true
        internal static float WalkStartedAt;
        private static Harmony _harmony;
        private static bool _tripped;

        private ConfigEntry<float> _walkSeconds, _goWaitSeconds, _stageTimeout;
        private ConfigEntry<int> _ascent;
        private GameObject _host;

        private void Awake()
        {
            Log = Logger;
            _walkSeconds = Config.Bind("TestDrive", "WalkSeconds", 0f, "0 = inactive. Seconds to walk on the Shore.");
            _goWaitSeconds = Config.Bind("TestDrive", "GoWaitSeconds", 900f,
                "At the main menu, wait up to this long for the kit's go file (BepInEx/config/peakpack.testdrive.go).");
            _stageTimeout = Config.Bind("TestDrive", "StageTimeoutSeconds", 600f, "Give up when a stage takes longer.");
            _ascent = Config.Bind("TestDrive", "Ascent", 0, "Ascent passed to the kiosk (0 = the default the boarding pass uses).");
            if (_walkSeconds.Value <= 0f) { Log.LogInfo("TESTDRIVE off (WalkSeconds = 0)"); return; }
            try
            {
                if (!Game.Resolve(out string missing)) { Log.LogError("TESTDRIVE inert: game member not found: " + missing); return; }
                _harmony = new Harmony(Guid);
                _harmony.Patch(Game.SampleMethod, postfix: new HarmonyMethod(typeof(Plugin), nameof(SamplePostfix)));
                Live = true;
                _host = new GameObject("PeakPack.TestDrive");
                _host.hideFlags = HideFlags.HideAndDontSave;
                DontDestroyOnLoad(_host);
                _host.AddComponent<Driver>().Init(_walkSeconds.Value, _goWaitSeconds.Value, _stageTimeout.Value, _ascent.Value,
                    Path.Combine(Paths.ConfigPath, "peakpack.testdrive.go"));
                Log.LogInfo("TESTDRIVE active walk_seconds=" + _walkSeconds.Value + " version=" + Version);
            }
            catch (Exception e) { Trip("start", e); }
        }

        private void OnDestroy() { Unpatch(); if (_host != null) Destroy(_host); }

        internal static void Trip(string where, Exception e)
        {
            Live = false; Walking = false;
            if (_tripped) return;
            _tripped = true;
            Log?.LogError("TESTDRIVE fail stage=" + where + " reason=" + (e == null ? "?" : e.GetType().Name + ": " + e.Message));
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
            Game.SetVector2(Game.MovementInput, input, new Vector2(0f, 1f));                     // hold W
            Game.SetVector2(Game.LookInput, input, new Vector2(0.6f * Mathf.Sin(t * 0.4f), 0f)); // slow look left/right
            // a short hop every 6 s gets the scout over small rocks
            if (Game.JumpWasPressed != null && (int)(t / 6f) != (int)((t - Time.deltaTime) / 6f)) Game.JumpWasPressed.SetValue(input, true);
        }
    }

    /// <summary>Cached accessors for the game members we use, found by name (no compile-time game reference).</summary>
    internal static class Game
    {
        internal static Type MainMenuT, FirstTimeT, KioskT, CharacterT, CharacterInputT, CharacterDataT, LoadingT, GameHandlerT;
        internal static MethodInfo SampleMethod, KioskStartGame;
        internal static FieldInfo PlaySoloButton, ContinueButton, LocalCharacterF, InputF, DataF, PassedOutOnBeach,
            MovementInput, LookInput, JumpWasPressed;
        internal static MemberInfo FullyConscious, Dead, Loading, InGameplay;

        internal static bool Resolve(out string missing)
        {
            missing = null;
            MainMenuT = T("MainMenu", ref missing); FirstTimeT = T("MainMenuFirstTimeSetupPage", ref missing);
            KioskT = T("AirportCheckInKiosk", ref missing); CharacterT = T("Character", ref missing);
            CharacterInputT = T("CharacterInput", ref missing); CharacterDataT = T("CharacterData", ref missing);
            LoadingT = T("LoadingScreenHandler", ref missing); GameHandlerT = T("GameHandler", ref missing);
            if (missing != null) return false;
            SampleMethod = AccessTools.Method(CharacterInputT, "Sample", new[] { typeof(bool) });
            KioskStartGame = AccessTools.Method(KioskT, "StartGame", new[] { typeof(int) });
            PlaySoloButton = AccessTools.Field(MainMenuT, "playSoloButton");
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

        internal static object LocalCharacter()
        {
            object c = LocalCharacterF.GetValue(null);
            return c is UnityEngine.Object uo && uo == null ? null : c;   // destroyed Unity objects compare equal to null
        }

        internal static object InputOf(object character) => InputF.GetValue(character);
        internal static object DataOf(object character) => DataF.GetValue(character);
        internal static void SetVector2(FieldInfo f, object target, Vector2 v) => f.SetValue(target, v);
        internal static bool IsLoading() => Bool(Loading, null, true);
        internal static bool InGameplayScene() => Bool(InGameplay, null, false);

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

    /// <summary>The stage machine, driven from Update. Every stage has a timeout; any exception trips the guard.</summary>
    internal class Driver : MonoBehaviour
    {
        private enum Stage { Menu, WaitGo, Solo, Airport, Kiosk, Island, Walk, Done }

        private Stage _stage = Stage.Menu;
        private float _walkSeconds, _goWait, _stageTimeout, _stageStart, _nextProgress, _settleUntil;
        private int _ascent;
        private string _goFile;
        private Vector3 _startPos;
        private bool _firstTimeContinued;

        internal void Init(float walkSeconds, float goWait, float stageTimeout, int ascent, string goFile)
        {
            _walkSeconds = walkSeconds; _goWait = goWait; _stageTimeout = stageTimeout; _ascent = ascent; _goFile = goFile;
            Enter(Stage.Menu);
        }

        private void Enter(Stage s)
        {
            _stage = s; _stageStart = Time.realtimeSinceStartup; _settleUntil = 0f;
            Plugin.Log.LogInfo("TESTDRIVE stage=" + s.ToString().ToLowerInvariant() + " scene=" + SceneManager.GetActiveScene().name);
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
            if (InStage > limit) { Plugin.Trip(_stage.ToString().ToLowerInvariant() + "_timeout", new TimeoutException(InStage.ToString("F0") + " s")); return; }
            switch (_stage)
            {
                case Stage.Menu:
                    // PEAK's first-launch microphone chooser: press its Continue (selection unchanged)
                    var first = UnityEngine.Object.FindFirstObjectByType(Game.FirstTimeT);
                    if (!_firstTimeContinued && first != null && Game.ActiveInHierarchy(first) && Game.Click(Game.ContinueButton.GetValue(first)))
                    { _firstTimeContinued = true; Plugin.Log.LogInfo("TESTDRIVE first_time_continue"); return; }
                    var menu = UnityEngine.Object.FindFirstObjectByType(Game.MainMenuT);
                    if (menu != null && Game.ActiveInHierarchy(menu) && !Game.IsLoading()) Enter(Stage.WaitGo);
                    break;
                case Stage.WaitGo:
                    // the kit writes the go file after its main-menu screenshot/fps step (or the wait ends)
                    if (File.Exists(_goFile) || InStage > _goWait)
                    { Plugin.Log.LogInfo("TESTDRIVE go=" + (File.Exists(_goFile) ? "file" : "timeout")); Enter(Stage.Solo); }
                    break;
                case Stage.Solo:
                    var mm = UnityEngine.Object.FindFirstObjectByType(Game.MainMenuT);
                    if (mm != null && Game.Click(Game.PlaySoloButton.GetValue(mm)))
                    { Plugin.Log.LogInfo("TESTDRIVE solo_clicked"); Enter(Stage.Airport); }
                    break;
                case Stage.Airport:
                    if (SceneManager.GetActiveScene().name != "Airport" || Game.IsLoading() || Game.LocalCharacter() == null) break;
                    if (_settleUntil == 0f) { _settleUntil = Time.realtimeSinceStartup + 8f; break; }
                    if (Time.realtimeSinceStartup >= _settleUntil) Enter(Stage.Kiosk);
                    break;
                case Stage.Kiosk:
                    var kiosk = UnityEngine.Object.FindFirstObjectByType(Game.KioskT);
                    if (kiosk == null) break;
                    Game.KioskStartGame.Invoke(kiosk, new object[] { _ascent });
                    Plugin.Log.LogInfo("TESTDRIVE kiosk_start ascent=" + _ascent);
                    Enter(Stage.Island);
                    break;
                case Stage.Island:
                    if (!Game.InGameplayScene() || Game.IsLoading()) break;
                    object c = Game.LocalCharacter();
                    if (c == null) break;
                    object d = Game.DataOf(c);
                    bool awake = Game.Bool(Game.FullyConscious, d, false) && !Game.Bool(Game.Dead, d, false)
                                 && (Game.PassedOutOnBeach == null || (float)Game.PassedOutOnBeach.GetValue(d) <= 0f);
                    if (!awake) break;
                    if (_settleUntil == 0f) { _settleUntil = Time.realtimeSinceStartup + 5f; break; }
                    if (Time.realtimeSinceStartup < _settleUntil) break;
                    _startPos = ((Component)c).transform.position;
                    Plugin.WalkStartedAt = Time.time; Plugin.Walking = true; _nextProgress = Time.realtimeSinceStartup + 10f;
                    Plugin.Log.LogInfo("TESTDRIVE island_ready scene=" + SceneManager.GetActiveScene().name);
                    Enter(Stage.Walk);
                    Plugin.Log.LogInfo("TESTDRIVE walk_start seconds=" + _walkSeconds);
                    break;
                case Stage.Walk:
                    object wc = Game.LocalCharacter();
                    float dist = wc == null ? -1f : Vector3.Distance(_startPos, ((Component)wc).transform.position);
                    if (Time.realtimeSinceStartup >= _nextProgress)
                    { _nextProgress += 10f; Plugin.Log.LogInfo("TESTDRIVE walk_progress t=" + InStage.ToString("F0") + " dist=" + dist.ToString("F1")); }
                    if (InStage >= _walkSeconds)
                    {
                        Plugin.Walking = false;
                        Plugin.Log.LogInfo("TESTDRIVE walk_end seconds=" + InStage.ToString("F0") + " dist=" + dist.ToString("F1"));
                        Enter(Stage.Done);
                        Plugin.Live = false;
                    }
                    break;
            }
        }
    }
}
