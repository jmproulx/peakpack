using System;
using System.Collections;
using System.IO;
using System.Text;
using BepInEx;
using UnityEngine;

namespace PeakPackRealPcTest
{
    /// <summary>
    /// Proof that BepInEx loaded from a PeakPack-style profile OUTSIDE the game folder.
    /// Writes &lt;profile&gt;\real-pc-test-result.json next to the BepInEx folder, then quits the game
    /// after the number of seconds in autoquit-seconds.txt (next to this DLL; default 20, 0 = don't quit).
    /// </summary>
    [BepInPlugin("peakpack.realpctest", "PeakPack real-PC test", "1.0.0")]
    public class Plugin : BaseUnityPlugin
    {
        private void Awake()
        {
            Logger.LogInfo("PEAKPACK-REAL-PC-TEST loaded from " + Info.Location);
            Logger.LogInfo("PEAKPACK-REAL-PC-TEST BepInExRootPath=" + Paths.BepInExRootPath + " GameRootPath=" + Paths.GameRootPath);
            try
            {
                var args = Environment.GetCommandLineArgs();
                var sb = new StringBuilder();
                sb.Append("{\n");
                sb.Append("  \"time\": \"").Append(DateTime.Now.ToString("o")).Append("\",\n");
                sb.Append("  \"bepinexRoot\": \"").Append(Esc(Paths.BepInExRootPath)).Append("\",\n");
                sb.Append("  \"gameRoot\": \"").Append(Esc(Paths.GameRootPath)).Append("\",\n");
                sb.Append("  \"pluginPath\": \"").Append(Esc(Info.Location)).Append("\",\n");
                sb.Append("  \"commandLine\": \"").Append(Esc(Environment.CommandLine)).Append("\",\n");
                sb.Append("  \"args\": [");
                for (int i = 0; i < args.Length; i++) sb.Append(i == 0 ? "" : ", ").Append('"').Append(Esc(args[i])).Append('"');
                sb.Append("],\n");
                sb.Append("  \"steamAppIdEnv\": \"").Append(Esc(Environment.GetEnvironmentVariable("SteamAppId") ?? "")).Append("\"\n");
                sb.Append("}\n");
                var profile = Directory.GetParent(Paths.BepInExRootPath).FullName;
                File.WriteAllText(Path.Combine(profile, "real-pc-test-result.json"), sb.ToString());
            }
            catch (Exception e) { Logger.LogError("PEAKPACK-REAL-PC-TEST could not write result: " + e); }

            int seconds = 20;
            try
            {
                var f = Path.Combine(Path.GetDirectoryName(Info.Location), "autoquit-seconds.txt");
                if (File.Exists(f)) int.TryParse(File.ReadAllText(f).Trim(), out seconds);
            }
            catch { }
            if (seconds > 0) StartCoroutine(QuitAfter(seconds));
        }

        private IEnumerator QuitAfter(int seconds)
        {
            yield return new WaitForSecondsRealtime(seconds);
            Logger.LogInfo("PEAKPACK-REAL-PC-TEST quitting the test instance");
            Application.Quit();
        }

        private static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
