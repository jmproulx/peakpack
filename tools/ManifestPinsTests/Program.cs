// Unit tests for the optional signed Mac pins and gameDepot (mac/app/proposals/friendinstaller-platforms-mac.md):
// schema (Manifest.cs), validation, the publisher's resolution from GitHub (canned answers, no network), the .acf reader,
// an offline end-to-end Publisher.PublishAsync (local loader zip, throwaway test key), and live-update planning.
//
//   dotnet run --project tools/ManifestPinsTests                     # all offline tests; exit code = failures
//   dotnet run --project tools/ManifestPinsTests -- --live           # also resolve the real mac-build-runtime-pp1 prerelease (read-only)
//   dotnet run --project tools/ManifestPinsTests -- compat-fixture <manifest.json> <outDir> [--bad-schema]
//        copies a manifest, adds the three fields, signs it with a NEW throwaway key (never Joshua's), and writes
//        manifest.json, manifest.json.sig, public-key.txt into outDir (for tools/pins-compat-test.ps1).
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PeakPack.Core;

internal static class Program
{
    static int _fail, _pass;

    static void Check(bool cond, string name)
    {
        if (cond) { _pass++; Console.WriteLine("  PASS  " + name); }
        else { _fail++; Console.WriteLine("  FAIL  " + name); }
    }

    static void Throws<T>(Action a, string name, string? contains = null) where T : Exception
    {
        try { a(); Check(false, name + " (no exception)"); }
        catch (T ex) { Check(contains is null || ex.Message.Contains(contains, StringComparison.OrdinalIgnoreCase), name + (contains is null ? "" : $" [{ex.Message}]")); }
        catch (Exception ex) { Check(false, $"{name} (threw {ex.GetType().Name}: {ex.Message})"); }
    }

    static async Task ThrowsAsync<T>(Func<Task> a, string name, string? contains = null) where T : Exception
    {
        try { await a(); Check(false, name + " (no exception)"); }
        catch (T ex) { Check(contains is null || ex.Message.Contains(contains, StringComparison.OrdinalIgnoreCase), name + $" [{ex.Message}]"); }
        catch (Exception ex) { Check(false, $"{name} (threw {ex.GetType().Name}: {ex.Message})"); }
    }

    const string Sha = "a1776d399c680d70d5675c59e32c8f763b51e9fabd98dbad3215065328532bfe";
    const string Sha2 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const string Repo = "jmproulx/peakpack";
    const string RtTag = "mac-build-runtime-pp2-cx26.3.0";
    const string RtAsset = "peakpack-runtime-pp2-cx26.3.0-x86_64.tar.xz";
    const string FeTag = "mac-build-app-0.2.0";
    const string FeZip = "PEAK-Modded-Mac-0.2.0.zip";

    static async Task<int> Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "compat-fixture") return CompatFixture(args);

        Console.WriteLine("== schema: manifests without the new fields (behaviour unchanged)");
        SchemaAbsent();
        Console.WriteLine("== schema: the three fields parse, round-trip and validate");
        SchemaPresent();
        Console.WriteLine("== validation: proposal rules (publisher refuses; friends' Validate() ignores)");
        Validation();
        Console.WriteLine("== SHA256SUMS parsing");
        SumsParsing();
        Console.WriteLine("== publisher: resolving tags from GitHub (canned answers)");
        await Resolution();
        Console.WriteLine("== gameDepot from appmanifest .acf");
        GameDepotReading();
        Console.WriteLine("== live-update planning ignores the front-end pins");
        HotPlan();
        Console.WriteLine("== end-to-end Publisher.PublishAsync (offline, throwaway key)");
        await EndToEnd();
        if (args.Contains("--live"))
        {
            Console.WriteLine("== live (read-only): resolve the real mac-build-runtime-pp1-cx26.3.0 prerelease");
            await Live();
        }

        Console.WriteLine(_fail == 0 ? $"ALL {_pass} PIN CHECKS PASSED" : $"{_fail} PIN CHECK(S) FAILED ({_pass} passed)");
        return _fail;
    }

    // ---------------------------------------------------------------- fixtures

    static string BaseManifestJson(string? macExtra = null, string? topExtra = null) => $$"""
        {
          "schema": 1, "packName": "Test pack", "revision": 6, "published": "2026-10-13T00:00:00+00:00", "gameAppId": 3527290,
          "loader": { "id": "BepInEx-BepInExPack_PEAK-5.4.75301", "url": "https://thunderstore.io/x.zip", "sha256": "{{Sha2}}", "size": 1 },
          "packages": [], "files": [],
          "platforms": { "mac": { "extraArgs": ["-force-d3d11"], "files": [], "minFrontEnd": "0.1.0"{{(macExtra is null ? "" : ", " + macExtra)}} } }
          {{(topExtra is null ? "" : ", " + topExtra)}}
        }
        """;

    static string RuntimeJson(string id = "pp2-cx26.3.0", string? tag = null, string? asset = null, string sha = Sha, long size = 160000000) =>
        $$"""
        "runtime": { "id": "{{id}}", "tag": "{{tag ?? "mac-build-runtime-" + id}}", "asset": "{{asset ?? $"peakpack-runtime-{id}-x86_64.tar.xz"}}", "sha256": "{{sha}}", "size": {{size}} }
        """;

    static string FrontEndJson(string v = "0.2.0", string? tag = null, string? zip = null, string sha = Sha) =>
        $$"""
        "frontEnd": { "version": "{{v}}", "tag": "{{tag ?? "mac-build-app-" + v}}", "zip": "{{zip ?? $"PEAK-Modded-Mac-{v}.zip"}}", "sha256": "{{sha}}" }
        """;

    static string DepotJson(int appId = 3527290, string manifestId = "7760699995234210393", string buildId = "25739797") =>
        $$"""
        "gameDepot": { "appId": {{appId}}, "depotId": 3527291, "manifestId": "{{manifestId}}", "buildId": "{{buildId}}" }
        """;

    static string AllFieldsJson() => BaseManifestJson(RuntimeJson() + ", " + FrontEndJson(), DepotJson());

    // ---------------------------------------------------------------- tests

    static void SchemaAbsent()
    {
        var m = PackManifest.Parse(BaseManifestJson());
        Check(m.GameDepot is null && m.Platforms?.Mac?.Runtime is null && m.Platforms?.Mac?.FrontEnd is null, "absent fields stay null");
        var json = m.ToJson();
        Check(!json.Contains("\"runtime\"") && !json.Contains("\"frontEnd\"") && !json.Contains("\"gameDepot\""), "absent fields are not written back (WhenWritingNull)");
        Check(m.PinProblems().Count == 0, "no pin problems when absent");
        m.ValidateForPublish();
        Check(true, "ValidateForPublish accepts a manifest without pins");
        Check(PackManifest.JsonOptions.UnmappedMemberHandling == System.Text.Json.Serialization.JsonUnmappedMemberHandling.Skip,
            "manifest JSON options skip unknown members (the rev-5 app used the same options)");
        var future = PackManifest.Parse(BaseManifestJson("\"someFutureField\": {\"x\": 1}", "\"anotherNewTopLevel\": [1,2]"));
        Check(future.Revision == 6, "unknown fields at top level and in platforms.mac are ignored");
    }

    static void SchemaPresent()
    {
        var m = PackManifest.Parse(AllFieldsJson());
        var rt = m.Platforms!.Mac!.Runtime!;
        Check(rt.Id == "pp2-cx26.3.0" && rt.Tag == RtTag && rt.Asset == RtAsset && rt.Sha256 == Sha && rt.Size == 160000000, "runtime parsed");
        var fe = m.Platforms.Mac.FrontEnd!;
        Check(fe.Version == "0.2.0" && fe.Tag == FeTag && fe.Zip == FeZip && fe.Sha256 == Sha, "frontEnd parsed");
        var gd = m.GameDepot!;
        Check(gd.AppId == 3527290 && gd.DepotId == 3527291 && gd.ManifestId == "7760699995234210393" && gd.BuildId == "25739797", "gameDepot parsed (top level)");
        Check(m.PinProblems().Count == 0, "valid pins have no problems");
        var again = PackManifest.Parse(m.ToJson());
        Check(JsonSerializer.Serialize(again.Platforms) == JsonSerializer.Serialize(m.Platforms) && again.GameDepot!.ManifestId == gd.ManifestId, "round-trips through ToJson");
        var node = JsonNode.Parse(m.ToJson())!;
        Check(node["platforms"]!["mac"]!["runtime"]!["sha256"]!.GetValue<string>() == Sha
              && node["platforms"]!["mac"]!["frontEnd"]!["zip"]!.GetValue<string>() == FeZip
              && node["gameDepot"]!["manifestId"]!.GetValueKind() == JsonValueKind.String
              && node["gameDepot"]!["appId"]!.GetValueKind() == JsonValueKind.Number,
            "JSON names/types match the Mac app's decoder (camelCase; manifestId/buildId strings, ids numbers)");
        var noSize = PackManifest.Parse(BaseManifestJson("\"runtime\": {\"id\":\"pp2-cx26.3.0\",\"tag\":\"" + RtTag + "\",\"asset\":\"" + RtAsset + "\",\"sha256\":\"" + Sha + "\"}"));
        Check(noSize.Platforms!.Mac!.Runtime!.Size is null && noSize.PinProblems().Count == 0, "runtime.size is optional");
        // Field placement only under platforms.mac: Windows file lists are unchanged by the pins.
        Check(m.FilesFor(Platform.Kind.Windows).Count == 0 && m.FilesFor(Platform.Kind.WineMac).Count == 0, "pins add no files on either platform");
    }

    static void Validation()
    {
        void Bad(string label, string json, string expect)
        {
            var m = PackManifest.Parse(json); // friends' apps: never rejected for a bad Mac pin / gameDepot
            Check(true, $"{label}: Parse/Validate (friend side) still accepts it");
            Throws<InvalidDataException>(() => m.ValidateForPublish(), $"{label}: publisher refuses", expect);
        }
        Bad("runtime id", BaseManifestJson(RuntimeJson(id: "pp2-wine11")), "runtime.id");
        Bad("runtime id without number", BaseManifestJson(RuntimeJson(id: "pp-cx26.3.0")), "runtime.id");
        Bad("runtime tag", BaseManifestJson(RuntimeJson(tag: "mac-build-runtime-pp1-cx26.3.0")), "runtime.tag");
        Bad("runtime asset slash", BaseManifestJson(RuntimeJson(asset: "x/peakpack-runtime.tar.xz")), "runtime.asset");
        Bad("runtime asset backslash", BaseManifestJson(RuntimeJson(asset: "x\\\\peakpack-runtime.tar.xz")), "runtime.asset");
        Bad("runtime asset ext", BaseManifestJson(RuntimeJson(asset: "peakpack-runtime-pp2-cx26.3.0-x86_64.zip")), "runtime.asset");
        Bad("runtime sha", BaseManifestJson(RuntimeJson(sha: "abc123")), "runtime.sha256");
        Bad("runtime sha non-hex", BaseManifestJson(RuntimeJson(sha: new string('g', 64))), "runtime.sha256");
        Bad("runtime size", BaseManifestJson(RuntimeJson(size: 0)), "runtime.size");
        Bad("frontEnd version", BaseManifestJson(FrontEndJson(v: "latest")), "frontEnd.version");
        Bad("frontEnd tag", BaseManifestJson(FrontEndJson(tag: "mac-build-app-0.1.0")), "frontEnd.tag");
        Bad("frontEnd zip", BaseManifestJson(FrontEndJson(zip: "../PEAK.zip")), "frontEnd.zip");
        Bad("frontEnd zip ext", BaseManifestJson(FrontEndJson(zip: "PEAK-Modded-Mac-0.2.0.dmg")), "frontEnd.zip");
        Bad("frontEnd sha", BaseManifestJson(FrontEndJson(sha: "")), "frontEnd.sha256");
        Bad("gameDepot manifestId", BaseManifestJson(null, DepotJson(manifestId: "abc")), "manifestId");
        Bad("gameDepot buildId", BaseManifestJson(null, DepotJson(buildId: "")), "buildId");
        Bad("gameDepot other game", BaseManifestJson(null, DepotJson(appId: 480)), "isn't the pack's game");
        Check(FrontEndPin.IsValidVersion("0.2.0") && FrontEndPin.IsValidVersion("1.10.3-beta.1") && !FrontEndPin.IsValidVersion("v0.2") && !FrontEndPin.IsValidVersion("0..2"),
            "front-end version shape");
        Check(RuntimePin.IsValidId("pp1-cx26.3.0") && RuntimePin.IsValidId("pp12-cx26") && !RuntimePin.IsValidId("PP1-cx26") && !RuntimePin.IsValidId("pp1-cx26.3.0/x"),
            "runtime id shape");
        // An unrelated bad entry is still refused by friends' Validate(): the friend-side checks are unchanged.
        Throws<InvalidDataException>(() => PackManifest.Parse(BaseManifestJson(RuntimeJson()).Replace("\"-force-d3d11\"", "\"--doorstop-enabled\"")),
            "existing friend-side validation unchanged (doorstop arg still refused)");
    }

    static void SumsParsing()
    {
        var text = $"{Sha}  {RtAsset}\r\n{Sha2.ToUpperInvariant()} *BUILD-STATUS.txt\n{Sha}  ./manifest.json\nnot a line\n{Sha[..60]}  short.txt\n";
        var map = MacPins.ParseSha256Sums(text);
        Check(map.GetValueOrDefault(RtAsset) == Sha, "two-space format, CRLF");
        Check(map.GetValueOrDefault("BUILD-STATUS.txt") == Sha2, "binary-mode '*' marker, upper-case hex lower-cased");
        Check(map.ContainsKey("manifest.json"), "'./' prefix stripped");
        Check(map.Count == 3, "junk and short lines ignored");
    }

    sealed class FakeGitHub
    {
        public readonly Dictionary<string, string> Answers = new();
        public int Calls;
        public Task<byte[]> Fetch(string url, CancellationToken ct)
        {
            Calls++;
            return Answers.TryGetValue(url, out var s) ? Task.FromResult(Encoding.UTF8.GetBytes(s))
                : throw new HttpRequestException($"Download failed for {url} (404)");
        }
        public void Release(string tag, bool prerelease = true, bool draft = false, string? sums = null, params (string Name, long Size)[] assets)
        {
            var list = assets.Select(a => new { name = a.Name, size = a.Size }).ToList();
            if (sums is not null) list.Add(new { name = "SHA256SUMS", size = (long)sums.Length });
            Answers[$"https://api.github.com/repos/{Repo}/releases/tags/{tag}"] =
                JsonSerializer.Serialize(new { tag_name = tag, prerelease, draft, assets = list });
            if (sums is not null) Answers[$"https://github.com/{Repo}/releases/download/{tag}/SHA256SUMS"] = sums;
        }
        public static FakeGitHub Standard()
        {
            var g = new FakeGitHub();
            g.Release(RtTag, sums: $"{Sha}  {RtAsset}\n{Sha2}  peakpack-runtime-src-pp2-cx26.3.0.tar.xz\n", assets: [(RtAsset, 160000000), ("peakpack-runtime-src-pp2-cx26.3.0.tar.xz", 9)]);
            g.Release(FeTag, sums: $"{Sha2}  {FeZip}\n", assets: [(FeZip, 4200000)]);
            return g;
        }
    }

    static async Task Resolution()
    {
        var log = new List<string>();
        var g = FakeGitHub.Standard();
        var pins = new MacPins(g.Fetch, log.Add);
        var rt = await pins.ResolveRuntimeAsync(Repo, RtTag);
        Check(rt.Id == "pp2-cx26.3.0" && rt.Tag == RtTag && rt.Asset == RtAsset && rt.Sha256 == Sha && rt.Size == 160000000, "runtime pin filled from SHA256SUMS + release asset size");
        var fe = await pins.ResolveFrontEndAsync(Repo, FeTag);
        Check(fe.Version == "0.2.0" && fe.Tag == FeTag && fe.Zip == FeZip && fe.Sha256 == Sha2, "front-end pin filled from SHA256SUMS");

        async Task Refuses(string label, Action<FakeGitHub> setup, Func<MacPins, Task> act, string expect)
        {
            var fg = new FakeGitHub(); setup(fg);
            await ThrowsAsync<InvalidDataException>(() => act(new MacPins(fg.Fetch, _ => { })), "refuses: " + label, expect);
        }
        var goodSums = $"{Sha}  {RtAsset}\n";
        await Refuses("runtime release is not a prerelease", f => f.Release(RtTag, prerelease: false, sums: goodSums, assets: [(RtAsset, 5)]), p => p.ResolveRuntimeAsync(Repo, RtTag), "prerelease");
        await Refuses("runtime release is a draft", f => f.Release(RtTag, draft: true, sums: goodSums, assets: [(RtAsset, 5)]), p => p.ResolveRuntimeAsync(Repo, RtTag), "draft");
        await Refuses("no SHA256SUMS asset", f => f.Release(RtTag, sums: null, assets: [(RtAsset, 5)]), p => p.ResolveRuntimeAsync(Repo, RtTag), "SHA256SUMS");
        await Refuses("no line for the runtime asset", f => f.Release(RtTag, sums: $"{Sha}  something-else.tar.xz\n", assets: [(RtAsset, 5)]), p => p.ResolveRuntimeAsync(Repo, RtTag), "no line");
        await Refuses("asset missing from the release", f => f.Release(RtTag, sums: goodSums, assets: []), p => p.ResolveRuntimeAsync(Repo, RtTag), "no asset");
        await Refuses("asset size 0", f => f.Release(RtTag, sums: goodSums, assets: [(RtAsset, 0)]), p => p.ResolveRuntimeAsync(Repo, RtTag), "size");
        await Refuses("wrong tag prefix", f => { }, p => p.ResolveRuntimeAsync(Repo, "mac-build-app-0.2.0"), "mac-build-runtime-");
        await Refuses("bad runtime id in tag", f => f.Release("mac-build-runtime-wine11", sums: goodSums, assets: [(RtAsset, 5)]), p => p.ResolveRuntimeAsync(Repo, "mac-build-runtime-wine11"), "pp<N>-cx");
        await Refuses("release not found (404)", f => { }, p => p.ResolveRuntimeAsync(Repo, RtTag), "Couldn't read release");
        await Refuses("GitHub returns another tag", f => { f.Release(RtTag, sums: goodSums, assets: [(RtAsset, 5)]); f.Answers[$"https://api.github.com/repos/{Repo}/releases/tags/{RtTag}"] = "{\"tag_name\":\"rev-5\",\"prerelease\":true,\"assets\":[]}"; },
            p => p.ResolveRuntimeAsync(Repo, RtTag), "returned release");
        await Refuses("garbage from the API", f => f.Answers[$"https://api.github.com/repos/{Repo}/releases/tags/{RtTag}"] = "<html>", p => p.ResolveRuntimeAsync(Repo, RtTag), "unexpected answer");
        await Refuses("front end: no zip line", f => f.Release(FeTag, sums: $"{Sha}  other.zip\n", assets: [(FeZip, 5)]), p => p.ResolveFrontEndAsync(Repo, FeTag), "no line");
        await Refuses("front end: bad version in tag", f => f.Release("mac-build-app-next", sums: $"{Sha}  {FeZip}\n", assets: [(FeZip, 5)]), p => p.ResolveFrontEndAsync(Repo, "mac-build-app-next"), "dotted version");
        await Refuses("front end: not a prerelease", f => f.Release(FeTag, prerelease: false, sums: $"{Sha}  {FeZip}\n", assets: [(FeZip, 5)]), p => p.ResolveFrontEndAsync(Repo, FeTag), "prerelease");
        Check(MacPins.CompareVersions("0.10.0", "0.9.1") > 0 && MacPins.CompareVersions("0.2", "0.2.0") == 0 && MacPins.CompareVersions("0.1.0", "0.2.0") < 0, "version comparison is numeric");
    }

    const string FakeOwner = "76561190000000042";

    static string Acf(string manifestGid = "7760699995234210393", string build = "25739797", string appId = "3527290", string stateFlags = "4", string depots = "") =>
        $$"""
        "AppState"
        {
        	"appid"		"{{appId}}"
        	"name"		"PEAK"
        	"StateFlags"		"{{stateFlags}}"
        	"installdir"		"PEAK"
        	"buildid"		"{{build}}"
        	"LastOwner"		"{{FakeOwner}}"
        	"LauncherPath"		"C:\\Program Files (x86)\\Steam\\steam.exe"
        	// a comment
        	"InstalledDepots"
        	{
        		"3527291"
        		{
        			"manifest"		"{{manifestGid}}"
        			"size"		"1930335969"
        		}
        		{{depots}}
        	}
        	"UserConfig" { "language" "english" }
        }
        """;

    static string TempDir(string name)
    {
        var d = Path.Combine(Path.GetTempPath(), "peakpack-pins-tests", name + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(d);
        return d;
    }

    static void GameDepotReading()
    {
        var dir = TempDir("acf");
        var p = Path.Combine(dir, "appmanifest_3527290.acf");
        var log = new List<string>();
        File.WriteAllText(p, Acf());
        var gd = MacPins.ReadGameDepot(p, 3527290, log.Add);
        Check(gd is { AppId: 3527290, DepotId: 3527291, ManifestId: "7760699995234210393", BuildId: "25739797" }, "reads appid, buildid, InstalledDepots/3527291/manifest");
        Check(!JsonSerializer.Serialize(gd).Contains(FakeOwner) && !string.Join("\n", log).Contains(FakeOwner), "nothing else from the .acf (LastOwner) reaches the manifest or the log");

        File.WriteAllText(p, Acf(depots: "\"3527292\" { \"manifest\" \"1\" }"));
        Check(MacPins.ReadGameDepot(p, 3527290, _ => { })?.DepotId == 3527291, "prefers depot appId+1 when several are installed");

        log.Clear();
        File.WriteAllText(p, Acf(stateFlags: "6"));
        Check(MacPins.ReadGameDepot(p, 3527290, log.Add) is not null && log.Any(l => l.Contains("StateFlags 6")), "update pending: still read, with a note");

        Check(MacPins.ReadGameDepot(Path.Combine(dir, "missing.acf"), 3527290, _ => { }) is null, "missing .acf -> omitted");
        Check(MacPins.ReadGameDepot(null, 3527290, _ => { }) is null, "no path -> omitted");
        File.WriteAllText(p, "\"AppState\" { \"appid\" \"3527290\" ");
        Check(MacPins.ReadGameDepot(p, 3527290, _ => { }) is null, "truncated .acf -> omitted");
        File.WriteAllText(p, Acf(appId: "480"));
        Check(MacPins.ReadGameDepot(p, 3527290, _ => { }) is null, "another game's .acf -> omitted");
        File.WriteAllText(p, Acf(manifestGid: "abc"));
        Check(MacPins.ReadGameDepot(p, 3527290, _ => { }) is null, "non-numeric manifest id -> omitted");
        File.WriteAllText(p, Acf(build: ""));
        Check(MacPins.ReadGameDepot(p, 3527290, _ => { }) is null, "empty buildid -> omitted");

        Check(MacPins.AcfPath("auto", @"D:\SteamLibrary\steamapps\common\PEAK", 3527290) == @"D:\SteamLibrary\steamapps\appmanifest_3527290.acf", "\"auto\" = <gameDir>\\..\\..\\appmanifest_<appid>.acf");
        Check(MacPins.AcfPath("auto", @"D:\SteamLibrary\steamapps\common\PEAK\", 3527290) == @"D:\SteamLibrary\steamapps\appmanifest_3527290.acf", "\"auto\" tolerates a trailing slash");
        Check(MacPins.AcfPath("auto", null, 3527290) is null, "\"auto\" without gameDir -> no path");
        Check(MacPins.AcfPath(@"E:\x.acf", null, 3527290) == @"E:\x.acf", "explicit .acf path");
        Directory.Delete(dir, true);
    }

    static PackManifest HotManifest(int rev, string? macExtra)
    {
        var m = PackManifest.Parse(BaseManifestJson(macExtra).Replace("\"revision\": 6", $"\"revision\": {rev}"));
        m.Lobby = new LobbySettings { TestLobby = true };
        return m;
    }

    static void HotPlan()
    {
        var state = new InstallState { AcceptLiveUpdates = true, InstalledRevision = 6 };
        var installed = HotManifest(6, null);
        var withPins = HotManifest(7, RuntimeJson() + ", " + FrontEndJson());
        var (status, _, msg) = HotUpdater.Plan(installed, withPins, state);
        Check(status == HotUpdater.Status.UpToDate, $"adding runtime/frontEnd pins doesn't force a restart ({status}: {msg})");
        var changedArgs = HotManifest(7, null);
        changedArgs.Platforms!.Mac!.ExtraArgs = ["-force-d3d12"];
        var (s2, _, m2) = HotUpdater.Plan(installed, changedArgs, state);
        Check(s2 == HotUpdater.Status.RestartNeeded && m2.Contains("Platform settings"), "changed Mac launch args still need a restart (unchanged behaviour)");
    }

    static async Task EndToEnd()
    {
        var dir = TempDir("e2e");
        // Local stand-in for the loader package, a one-package Thunderstore index, and a throwaway signing key.
        var loaderSrc = Path.Combine(dir, "loader"); Directory.CreateDirectory(Path.Combine(loaderSrc, "BepInExPack"));
        File.WriteAllText(Path.Combine(loaderSrc, "BepInExPack", "winhttp.dll"), "stand-in");
        var loaderZip = Path.Combine(dir, "BepInExPack_PEAK.zip");
        ZipFile.CreateFromDirectory(loaderSrc, loaderZip);
        var indexJson = JsonSerializer.Serialize(new[] { new {
            full_name = "BepInEx-BepInExPack_PEAK", owner = "BepInEx", is_deprecated = false, categories = Array.Empty<string>(),
            versions = new[] { new { full_name = "BepInEx-BepInExPack_PEAK-5.4.75301", version_number = "5.4.75301", download_url = loaderZip, dependencies = Array.Empty<string>(), is_active = true } } } });
        using var idxStream = new MemoryStream(Encoding.UTF8.GetBytes(indexJson));
        var index = ThunderstoreIndex.Parse(idxStream);
        var (pem, pub) = ManifestSigner.GenerateKeyPair();
        var keyPath = Path.Combine(dir, "throwaway-test-key.pem");
        File.WriteAllText(keyPath, pem);
        var gameDir = Path.Combine(dir, "steamapps", "common", "PEAK"); Directory.CreateDirectory(gameDir);
        File.WriteAllText(Path.Combine(dir, "steamapps", "appmanifest_3527290.acf"), Acf());
        using var dl = new Downloader(Path.Combine(dir, "cache")) { AllowLocalFiles = true };

        PublishConfig Cfg(bool pins) => new()
        {
            PackName = "Pins test", Loader = "BepInEx-BepInExPack_PEAK", Companion = "", SigningKey = keyPath, GithubRepo = Repo, GameDir = gameDir,
            Mac = new PublishConfig.MacSource
            {
                ExtraArgs = ["-force-d3d11"], MinFrontEnd = "0.1.0",
                Runtime = pins ? new PublishConfig.ReleaseRef { Tag = RtTag } : null,
                FrontEnd = pins ? new PublishConfig.ReleaseRef { Tag = FeTag } : null,
            },
            GameDepot = pins ? "auto" : null,
        };

        // 1. Keys absent: no pins, no GitHub calls, no gameDepot.
        var g0 = FakeGitHub.Standard();
        var out0 = Path.Combine(dir, "out-absent");
        var m0 = await new Publisher(dl, index, _ => { }) { PinFetch = g0.Fetch }.PublishAsync(Cfg(false), out0, null);
        var raw0 = File.ReadAllText(Path.Combine(out0, "manifest.json"));
        Check(g0.Calls == 0 && m0.GameDepot is null && m0.Platforms?.Mac?.Runtime is null && !raw0.Contains("runtime") && !raw0.Contains("frontEnd") && !raw0.Contains("gameDepot"),
            "keys absent: manifest has none of the new fields and GitHub isn't asked");

        // 2. Keys present: filled, signed, and the signature covers them.
        var g = FakeGitHub.Standard();
        var log = new List<string>();
        var out1 = Path.Combine(dir, "out-pins");
        var m1 = await new Publisher(dl, index, log.Add) { PinFetch = g.Fetch }.PublishAsync(Cfg(true), out1, m0);
        var bytes = File.ReadAllBytes(Path.Combine(out1, "manifest.json"));
        var sig = File.ReadAllText(Path.Combine(out1, "manifest.json.sig"));
        Check(ManifestSigner.Verify(bytes, sig, pub), "signed manifest verifies");
        var parsed = PackManifest.Parse(Encoding.UTF8.GetString(bytes));
        Check(parsed.Platforms?.Mac?.Runtime is { Id: "pp2-cx26.3.0", Sha256: Sha, Size: 160000000 }
              && parsed.Platforms.Mac.FrontEnd is { Version: "0.2.0", Sha256: Sha2 }
              && parsed.GameDepot is { ManifestId: "7760699995234210393", BuildId: "25739797", DepotId: 3527291 }, "published manifest carries runtime, frontEnd and gameDepot");
        Check(parsed.Platforms!.Mac!.ExtraArgs.SequenceEqual(["-force-d3d11"]) && parsed.Platforms.Mac.MinFrontEnd == "0.1.0", "existing platforms.mac fields unchanged");
        Check(!Encoding.UTF8.GetString(bytes).Contains(FakeOwner), "no other .acf data in the manifest");
        var tampered = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace(Sha, Sha2));
        Check(!ManifestSigner.Verify(tampered, sig, pub), "changing the pinned sha256 breaks the signature");
        Check(log.Any(l => l.Contains("mac runtime pp2-cx26.3.0")) && log.Any(l => l.Contains("gameDepot: depot 3527291")), "publisher logs what it pinned");

        // 3. Refusals: nothing signed, no manifest written.
        async Task Refuses(string label, Action<PublishConfig> tweak, Action<FakeGitHub>? gh, string expect)
        {
            var fg = FakeGitHub.Standard(); gh?.Invoke(fg);
            var cfg = Cfg(true); tweak(cfg);
            var o = Path.Combine(dir, "out-refused-" + Guid.NewGuid().ToString("N")[..6]);
            await ThrowsAsync<InvalidDataException>(() => new Publisher(dl, index, _ => { }) { PinFetch = fg.Fetch }.PublishAsync(cfg, o, m0), "publish refused: " + label, expect);
            Check(!File.Exists(Path.Combine(o, "manifest.json")) && !File.Exists(Path.Combine(o, "manifest.json.sig")), $"  ({label}: no manifest/signature written)");
        }
        await Refuses("runtime not a prerelease", _ => { }, fg => fg.Release(RtTag, prerelease: false, sums: $"{Sha}  {RtAsset}\n", assets: [(RtAsset, 5)]), "prerelease");
        await Refuses("runtime tag mistyped", c => c.Mac!.Runtime!.Tag = "mac-build-runtime-pp9-cx26.3.0", null, "Couldn't read release");
        await Refuses("front end older than minFrontEnd", c => c.Mac!.MinFrontEnd = "0.3.0", null, "older than mac.minFrontEnd");
        await Refuses("no githubRepo", c => c.GithubRepo = null, null, "githubRepo");
        await Refuses("empty runtime tag", c => c.Mac!.Runtime!.Tag = " ", null, "mac-build-runtime-");

        // 4. gameDepot unreadable: published without it (not a refusal).
        var cfgNoAcf = Cfg(false); cfgNoAcf.GameDepot = Path.Combine(dir, "nope.acf");
        var m3 = await new Publisher(dl, index, _ => { }) { PinFetch = g.Fetch }.PublishAsync(cfgNoAcf, Path.Combine(dir, "out-noacf"), m0);
        Check(m3.GameDepot is null, "unreadable .acf: published without gameDepot");

        // 5. publish.json round-trip: the new keys load and save; old configs load without them.
        var cfgPath = Path.Combine(dir, "publish.json");
        File.WriteAllText(cfgPath, """{ "packName": "x", "githubRepo": "jmproulx/peakpack", "gameDepot": "auto", "mac": { "runtime": { "tag": "mac-build-runtime-pp2-cx26.3.0" }, "frontEnd": { "tag": "mac-build-app-0.2.0" } } }""");
        var loaded = PublishConfig.Load(cfgPath);
        Check(loaded.Mac?.Runtime?.Tag == RtTag && loaded.Mac.FrontEnd?.Tag == FeTag && loaded.GameDepot == "auto" && loaded.Extra is null, "publish.json keys load as typed fields");
        loaded.Save(cfgPath);
        var reloaded = File.ReadAllText(cfgPath);
        Check(reloaded.Contains(RtTag) && reloaded.Contains(FeTag) && reloaded.Contains("\"gameDepot\": \"auto\""), "and are written back on Save");
        File.WriteAllText(cfgPath, """{ "packName": "x", "mac": { "extraArgs": ["-force-d3d11"] } }""");
        var old = PublishConfig.Load(cfgPath);
        old.Save(cfgPath);
        var oldText = File.ReadAllText(cfgPath);
        Check(old.Mac!.Runtime is null && old.GameDepot is null && !oldText.Contains("runtime") && !oldText.Contains("gameDepot") && !oldText.Contains("frontEnd"),
            "an existing publish.json gains no new keys when the Host window saves it");

        try { Directory.Delete(dir, true); } catch { }
    }

    static async Task Live()
    {
        using var dl = MacPins.CreateGitHubDownloader();
        var pins = new MacPins(MacPins.GitHubFetch(dl), Console.WriteLine);
        try
        {
            var rt = await pins.ResolveRuntimeAsync(Repo, "mac-build-runtime-pp1-cx26.3.0");
            Check(rt.Sha256 == Sha && rt.Asset == "peakpack-runtime-pp1-cx26.3.0-x86_64.tar.xz" && rt.Size > 100_000_000,
                $"real pp1 prerelease resolves (sha {rt.Sha256[..12]}…, {rt.Size:N0} bytes)");
        }
        catch (Exception ex) { Check(false, "live resolve threw " + ex.Message); }
    }

    // ---------------------------------------------------------------- compat fixture (for tools/pins-compat-test.ps1)

    static int CompatFixture(string[] args)
    {
        if (args.Length < 3) { Console.Error.WriteLine("compat-fixture <manifest.json> <outDir> [--bad-schema] [--no-fields]"); return 64; }
        var node = JsonNode.Parse(File.ReadAllText(args[1]))!.AsObject();
        if (!args.Contains("--no-fields")) // --no-fields: the unmodified manifest re-signed (baseline)
        {
            var mac = (node["platforms"] ??= new JsonObject())!.AsObject();
            var macObj = (mac["mac"] ??= new JsonObject())!.AsObject();
            macObj["runtime"] = JsonNode.Parse("{" + RuntimeJson() + "}")!["runtime"]!.DeepClone();
            macObj["frontEnd"] = JsonNode.Parse("{" + FrontEndJson() + "}")!["frontEnd"]!.DeepClone();
            node["gameDepot"] = JsonNode.Parse("{" + DepotJson() + "}")!["gameDepot"]!.DeepClone();
        }
        if (args.Contains("--bad-schema")) node["schema"] = 99; // negative control: proves the old app really parses this file
        Directory.CreateDirectory(args[2]);
        var bytes = new UTF8Encoding(false).GetBytes(node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        var (pem, pub) = ManifestSigner.GenerateKeyPair(); // throwaway; never written to disk
        File.WriteAllBytes(Path.Combine(args[2], "manifest.json"), bytes);
        File.WriteAllText(Path.Combine(args[2], "manifest.json.sig"), ManifestSigner.Sign(bytes, pem));
        File.WriteAllText(Path.Combine(args[2], "public-key.txt"), pub);
        Console.WriteLine($"wrote {args[2]} ({(args.Contains("--no-fields") ? "unmodified" : "runtime, frontEnd, gameDepot added")}{(args.Contains("--bad-schema") ? ", schema 99" : "")}; signed with a throwaway key)");
        return 0;
    }
}
