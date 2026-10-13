// PeakPack HarmonyX probe (MIT, our code). BepInEx 5 plugin for Unity Mono.
// Logs one line per check with the prefix "HARMONYPROBE" so the output can be grepped from LogOutput.log.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using BepInEx;
using BepInEx.Logging;
using HarmonyLib;
using UnityEngine;

namespace PeakPack.HarmonyProbe
{
    [BepInPlugin("com.peakpack.harmonyprobe", "PeakPack HarmonyX Probe", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        private const string HarmonyId = "com.peakpack.harmonyprobe";
        private const string Marker = "__peakprobe__";

        private static ManualLogSource _log;
        private static int _failures;
        private static Func<float, float, float, float> _lerp;
        private static Func<string, string, string> _combine;

        private void Awake()
        {
            _log = Logger;
            _failures = 0;

            Line("start os=" + RuntimeInformation.OSDescription
                + " arch=" + RuntimeInformation.ProcessArchitecture
                + " clr=" + Environment.Version
                + " unity=" + Application.unityVersion
                + " platform=" + Application.platform);

            var harmony = new Harmony(HarmonyId);
            Guard("probe", () => RunProbe(harmony));

            Guard("unpatch", () =>
            {
                harmony.UnpatchSelf();
                Line("unpatched self");
            });

            Guard("restore", RestoreChecks);

            if (_failures == 0)
            {
                Line("RESULT PASS");
            }
            else
            {
                Line("RESULT FAIL " + _failures);
            }
        }

        // ---- targets: our own methods, kept out of line so the JIT cannot inline past the patch ----

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Target1(int x)
        {
            return x;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Target2(int x)
        {
            return x + 1;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Target3()
        {
            return 7;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static float CallLerp(float a, float b, float t)
        {
            return _lerp(a, b, t);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static string CallCombine(string a, string b)
        {
            return _combine(a, b);
        }

        // ---- patch methods ----

        // (1) prefix that changes an argument
        private static void Pre1(ref int x)
        {
            x = x + 100;
        }

        // (2) postfix that changes the result
        private static void Post2(ref int __result)
        {
            __result = __result * 2;
        }

        // (3) transpiler that replaces the constant 7 with 9
        private static IEnumerable<CodeInstruction> Tr3(IEnumerable<CodeInstruction> instructions)
        {
            foreach (CodeInstruction ci in instructions)
            {
                bool isSeven = ci.opcode == OpCodes.Ldc_I4_7
                    || (ci.opcode == OpCodes.Ldc_I4 && ci.operand is int v && v == 7);
                if (isSeven)
                {
                    yield return new CodeInstruction(OpCodes.Ldc_I4, 9);
                }
                else
                {
                    yield return ci;
                }
            }
        }

        // (4) postfix on a BCL method; only the marker input is changed
        private static void Post4(string path1, string path2, ref string __result)
        {
            if (path1 == Marker)
            {
                __result = "PATCHED:" + path2;
            }
        }

        // (5) prefix on a UnityEngine managed (non-icall) method: Mathf.Lerp forces t = 1
        private static void Pre5(ref float t)
        {
            t = 1f;
        }

        // ---- probe flow ----

        private static void RunProbe(Harmony harmony)
        {
            // (1) prefix changes argument
            Guard("prefix_arg", () =>
            {
                harmony.Patch(
                    AccessTools.Method(typeof(Plugin), nameof(Target1)),
                    prefix: new HarmonyMethod(AccessTools.Method(typeof(Plugin), nameof(Pre1))));
                int got = Target1(1);
                Check("prefix_arg", got == 101, "got=" + got + " expected=101");
            });

            // (2) postfix changes result
            Guard("postfix_result", () =>
            {
                harmony.Patch(
                    AccessTools.Method(typeof(Plugin), nameof(Target2)),
                    postfix: new HarmonyMethod(AccessTools.Method(typeof(Plugin), nameof(Post2))));
                int got = Target2(3);
                Check("postfix_result", got == 8, "got=" + got + " expected=8 (unpatched would be 4)");
            });

            // (3) transpiler replaces constant
            Guard("transpiler_const", () =>
            {
                harmony.Patch(
                    AccessTools.Method(typeof(Plugin), nameof(Target3)),
                    transpiler: new HarmonyMethod(AccessTools.Method(typeof(Plugin), nameof(Tr3))));
                int got = Target3();
                Check("transpiler_const", got == 9, "got=" + got + " expected=9 (unpatched would be 7)");
            });

            // (4) postfix on System.IO.Path.Combine(string,string), called through a delegate
            Guard("bcl_postfix_path_combine", () =>
            {
                MethodInfo combine = AccessTools.Method(typeof(Path), "Combine", new[] { typeof(string), typeof(string) });
                _combine = (Func<string, string, string>)Delegate.CreateDelegate(typeof(Func<string, string, string>), combine);
                harmony.Patch(combine, postfix: new HarmonyMethod(AccessTools.Method(typeof(Plugin), nameof(Post4))));
                string got = CallCombine(Marker, "x");
                Check("bcl_postfix_path_combine", got == "PATCHED:x",
                    "got=" + got + " expected=PATCHED:x; control Combine(a,b)=" + CallCombine("a", "b"));
            });

            // (5) prefix on a UnityEngine managed (non-icall) method, Mathf.Lerp
            Guard("unity_managed_prefix_lerp", () =>
            {
                MethodInfo lerp = AccessTools.Method(typeof(Mathf), "Lerp", new[] { typeof(float), typeof(float), typeof(float) });
                _lerp = (Func<float, float, float, float>)Delegate.CreateDelegate(typeof(Func<float, float, float, float>), lerp);
                harmony.Patch(lerp, prefix: new HarmonyMethod(AccessTools.Method(typeof(Plugin), nameof(Pre5))));
                float got = CallLerp(0f, 10f, 0.5f);
                Check("unity_managed_prefix_lerp", Mathf.Abs(got - 10f) < 0.0001f,
                    "got=" + got.ToString("R") + " expected=10 (unpatched would be 5)");
            });
        }

        // After UnpatchSelf the originals must be back.
        private static void RestoreChecks()
        {
            int r1 = Target1(1);
            Check("restore_target1", r1 == 1, "got=" + r1 + " expected=1");
            int r2 = Target2(3);
            Check("restore_target2", r2 == 4, "got=" + r2 + " expected=4");
            int r3 = Target3();
            Check("restore_target3", r3 == 7, "got=" + r3 + " expected=7");
            string c = CallCombine(Marker, "x");
            Check("restore_path_combine", c != "PATCHED:x", "got=" + c);
            float l = CallLerp(0f, 10f, 0.5f);
            Check("restore_lerp", Mathf.Abs(l - 5f) < 0.0001f, "got=" + l.ToString("R") + " expected=5");
        }

        // ---- helpers ----

        private static void Guard(string name, Action body)
        {
            try
            {
                body();
            }
            catch (Exception ex)
            {
                Check(name, false, "exception: " + ex.ToString());
            }
        }

        private static void Check(string name, bool ok, string detail)
        {
            if (!ok)
            {
                _failures++;
            }
            Line("check " + name + "=" + (ok ? "ok" : "FAIL") + " (" + OneLine(detail) + ")");
        }

        private static void Line(string text)
        {
            string msg = "HARMONYPROBE " + text;
            if (_log != null)
            {
                _log.LogInfo(msg);
            }
        }

        // Keep every exception line in one log line; full text is preserved with separators.
        private static string OneLine(string s)
        {
            if (s == null)
            {
                return "null";
            }
            return s.Replace("\r\n", " | ").Replace('\r', ' ').Replace('\n', ' ');
        }
    }
}
