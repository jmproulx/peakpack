using System.Diagnostics;
using System.Text;
using PeakPack.App.Host;
using PeakPack.Core;

namespace PeakPack.App;

public sealed partial class HostForm
{
    static readonly TimeSpan IndexMaxAge = TimeSpan.FromHours(6);
    string? _lastDllDir;

    async Task OnShownAsync()
    {
        // Load the cached Thunderstore index for names and descriptions (downloads it only if there's none yet).
        await EnsureIndexAsync(fresh: false, quiet: true);
        if (_selfTestDir is not null)
        {
            await RunSelfTestAsync(_selfTestDir);
            Close();
        }
    }

    // ================= Thunderstore index =================

    async Task<ThunderstoreIndex?> EnsureIndexAsync(bool fresh, bool quiet = false)
    {
        var file = IndexFile;
        bool download = !File.Exists(file) || (fresh && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) > IndexMaxAge);
        if (_index is not null && !download) return _index;

        BeginBusy(download ? "Downloading the Thunderstore mod list" : "Loading the Thunderstore mod list",
            download ? "About 9 MB. It's kept for a few hours, so this is only slow now and then." : "");
        using var poll = new System.Windows.Forms.Timer { Interval = 300 };
        poll.Tick += (_, _) =>
        {
            try { if (File.Exists(file + ".part")) BusyDetail($"{new FileInfo(file + ".part").Length / 1048576.0:0.0} MB of about 9 MB downloaded..."); }
            catch (IOException) { }
        };
        if (download) poll.Start();
        try
        {
            var maxAge = fresh ? IndexMaxAge : TimeSpan.MaxValue;
            _index = await Task.Run(() => ThunderstoreIndex.LoadAsync(file, maxAge));
            Log($"Thunderstore: {_index.All.Count} PEAK packages ({(download ? "downloaded" : "cached")} {file})");
            RefreshMods();
            return _index;
        }
        catch (Exception ex)
        {
            if (quiet) Log("Couldn't load the Thunderstore mod list: " + ex.Message);
            else ShowError("Couldn't load the Thunderstore mod list", Friendly(ex));
            return null;
        }
        finally
        {
            poll.Stop();
            EndBusy();
        }
    }

    // ================= Mods =================

    IEnumerable<string> AllModKeys() => _cfg.Mods.Concat(_cfg.HostOnly).Select(e => new ModRow(e, false).Key);

    void SelectMod(string key)
    {
        foreach (ListViewItem it in _mods.Items)
            if (((ModRow)it.Tag!).Key.Equals(key, StringComparison.OrdinalIgnoreCase))
            {
                _mods.SelectedItems.Clear();
                it.Selected = true; it.Focused = true; it.EnsureVisible();
                return;
            }
    }

    async Task AddFromThunderstoreAsync()
    {
        if (await EnsureIndexAsync(fresh: false) is not { } index) return;
        using var dlg = new AddModDialog(_ui, index, AllModKeys());
        if (dlg.ShowDialog(this) != DialogResult.OK || dlg.Selected.Count == 0) return;
        foreach (var p in dlg.Selected) (p.IsHostOnly ? _cfg.HostOnly : _cfg.Mods).Add(p.FullName);
        RefreshMods();
        SelectMod(dlg.Selected[0].FullName);
        Changed();
    }

    async Task ImportFromGameAsync()
    {
        var game = _cfg.GameDir;
        if (!GameFolder.LooksLikePeak(game)) { ShowError("Set your PEAK folder first", "Pick your PEAK folder on the Settings tab, then try again."); return; }
        var plugins = Path.Combine(game!, "BepInEx", "plugins");
        if (!Directory.Exists(plugins)) { ShowError("No mods found in your game", $"There's no BepInEx\\plugins folder in {game}."); return; }
        if (await EnsureIndexAsync(fresh: false) is not { } index) return;
        using var dlg = new ImportDialog(_ui, index, plugins, CacheDir, AllModKeys(), _cfg.CustomFiles.Select(c => c.Source));
        dlg.ScanOnShown();
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        foreach (var m in dlg.Mods) (m.HostOnly ? _cfg.HostOnly : _cfg.Mods).Add(m.Entry);
        foreach (var dll in dlg.Dlls) AddCustomDll(dll);
        RefreshMods();
        RefreshBuilds();
        if (dlg.Mods.Count > 0) SelectMod(new ModRow(dlg.Mods[0].Entry, false).Key);
        if (dlg.Mods.Count + dlg.Dlls.Count > 0)
        {
            Log($"Imported {dlg.Mods.Count} mod(s) and {dlg.Dlls.Count} own build(s) from {plugins}");
            Changed();
        }
    }

    void RemoveMod()
    {
        if (_busyDepth > 0 || SelectedMod() is not { } row) return;
        int index = _mods.SelectedIndices[0];
        (row.HostOnly ? _cfg.HostOnly : _cfg.Mods).Remove(row.Entry);
        RefreshMods();
        if (_mods.Items.Count > 0) { var it = _mods.Items[Math.Min(index, _mods.Items.Count - 1)]; it.Selected = true; it.Focused = true; }
        Changed();
    }

    void ToggleWho()
    {
        if (SelectedMod() is not { } row) return;
        (row.HostOnly ? _cfg.HostOnly : _cfg.Mods).Remove(row.Entry);
        (row.HostOnly ? _cfg.Mods : _cfg.HostOnly).Add(row.Entry);
        RefreshMods();
        SelectMod(row.Key);
        Changed();
    }

    async Task PinVersionAsync()
    {
        if (SelectedMod() is not { Id: { } id } row) return;
        if (await EnsureIndexAsync(fresh: false) is not { } index) return;
        if (index.Find(id.FullName) is not { } pkg) { ShowError("Not on Thunderstore", $"{id.FullName} isn't in the PEAK mod list, so there are no versions to pick from."); return; }
        using var dlg = new PinVersionDialog(_ui, pkg, id.Version);
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        var entry = dlg.Chosen is null ? id.FullName : new PackageId(id.Namespace, id.Name, dlg.Chosen).ToString();
        if (entry == row.Entry) return;
        var list = row.HostOnly ? _cfg.HostOnly : _cfg.Mods;
        var i = list.IndexOf(row.Entry);
        if (i >= 0) list[i] = entry;
        RefreshMods();
        SelectMod(id.FullName);
        Changed();
    }

    // ================= Own builds =================

    static string? DllVersion(string path)
    {
        try
        {
            var fv = FileVersionInfo.GetVersionInfo(path).FileVersion;
            return Version.TryParse(fv, out var v) && v.Build >= 0 ? v.ToString(3) : NullIfEmpty(fv);
        }
        catch { return null; }
    }

    PublishConfig.CustomFile AddCustomDll(string path)
    {
        var stem = Path.GetFileNameWithoutExtension(path);
        var name = string.Join("_", new string(stem.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').ToArray()).Split('_', StringSplitOptions.RemoveEmptyEntries));
        if (name.Length == 0) name = "Mod";
        var ns = new string(_cfg.HostName.Where(char.IsAsciiLetterOrDigit).ToArray());
        if (ns.Length == 0) ns = "Joshua";
        var id = $"{ns}-{name}";
        var dest = $"plugins/{id}/{Path.GetFileName(path)}";
        if (_cfg.CustomFiles.FirstOrDefault(c => c.Dest.Equals(dest, StringComparison.OrdinalIgnoreCase)) is { } existing)
        {
            existing.Source = path; // same mod, new place: just point at the new build
            return existing;
        }
        var cf = new PublishConfig.CustomFile
        {
            Id = id, Source = path, Dest = dest, Version = DllVersion(path) ?? "1.0.0",
            Title = ThunderstoreIndex.Friendly(stem.Split('.').Last()),
        };
        _cfg.CustomFiles.Add(cf);
        return cf;
    }

    void SelectBuild(PublishConfig.CustomFile cf)
    {
        foreach (ListViewItem it in _builds.Items)
            if (it.Tag is BuildRow { File: { } f } && ReferenceEquals(f, cf)) { _builds.SelectedItems.Clear(); it.Selected = true; it.Focused = true; it.EnsureVisible(); }
    }

    void AddDll()
    {
        using var dlg = new OpenFileDialog
        {
            Title = "Add your own build", Filter = "Plugin DLL (*.dll)|*.dll|All files|*.*", Multiselect = true, CheckFileExists = true,
            InitialDirectory = _lastDllDir ?? (Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PeakMods"))
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PeakMods") : ""),
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        _lastDllDir = Path.GetDirectoryName(dlg.FileNames[0]);
        PublishConfig.CustomFile? last = null;
        foreach (var f in dlg.FileNames) last = AddCustomDll(f);
        RefreshBuilds();
        if (last is not null) SelectBuild(last);
        Changed();
    }

    void ChangeSource()
    {
        if (SelectedBuild() is not { } cf) return;
        using var dlg = new OpenFileDialog { Title = $"New source for {cf.Id}", Filter = "Plugin DLL (*.dll)|*.dll|All files|*.*", CheckFileExists = true };
        if (Directory.Exists(Path.GetDirectoryName(cf.Source))) dlg.InitialDirectory = Path.GetDirectoryName(cf.Source);
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        var oldName = Path.GetFileName(cf.Source);
        cf.Source = dlg.FileName;
        var newName = Path.GetFileName(dlg.FileName);
        if (!oldName.Equals(newName, StringComparison.OrdinalIgnoreCase) && cf.Dest.EndsWith("/" + oldName, StringComparison.OrdinalIgnoreCase))
            cf.Dest = cf.Dest[..^oldName.Length] + newName;
        RefreshBuilds();
        SelectBuild(cf);
        Changed();
    }

    void RemoveBuild()
    {
        if (_busyDepth > 0 || SelectedBuild() is not { } cf) return;
        _cfg.CustomFiles.Remove(cf);
        RefreshBuilds();
        Changed();
    }

    // ================= Check what friends will get =================

    async Task CheckAsync()
    {
        if (_busyDepth > 0) return;
        _prepareWarnings.Clear();
        _released = null;
        _notice = null;
        BeginBusy("Checking what friends will get", "Loading the Thunderstore mod list...");
        try
        {
            if (await EnsureIndexAsync(fresh: true) is not { } index) return;
            var cfg = CloneConfig();
            Log($"--- Check, {DateTime.Now:HH:mm:ss} ---");
            using var dl = new Downloader(CacheDir);
            var pipe = new PublishPipeline(Log);
            BusyDetail("Finding the revision friends have now...");
            var prev = await Task.Run(() => pipe.LoadPreviousAsync(cfg, _workDir, dl, _previousOverride));
            BusyDetail("Building the next revision (new mods are downloaded once to fingerprint them)...");
            var p = await Task.Run(() => pipe.PrepareAsync(cfg, _workDir, index, dl, prev));
            _prepared = p;
            _preparedStale = false;
            Log($"Revision {p.Manifest.Revision} staged in {p.StagingDir}: {(p.Previous is null ? "first publish" : PackDiff.Summary(p.Changes))}");
            foreach (var c in p.Changes) Log("  " + c);
            foreach (var pr in p.Problems) Log("NOT READY: " + pr);
        }
        catch (Exception ex)
        {
            _prepared = null;
            _preparedStale = false;
            ShowError("Couldn't check what friends will get", Friendly(ex));
        }
        finally
        {
            EndBusy();
            RefreshChanges();
        }
    }

    static string VersionText(PackDiff.Change c) => c.Kind switch
    {
        PackDiff.Kind.Added => c.To ?? "",
        PackDiff.Kind.Removed => c.From ?? "",
        _ => c.IsOwnBuild && c.From == c.To ? "new build" : $"{c.From} â†’ {c.To}",
    };

    void RefreshChanges()
    {
        if (_changes is null || _changes.IsDisposed) return;
        _changes.BeginUpdate();
        _changes.Items.Clear();
        var p = _prepared;
        if (p is null)
        {
            _changesCaption.Text = "What friends will get";
            var it = HostKit.Row("Not checked yet. Press \"Check what friends will get\" above.", "");
            it.ForeColor = Theme.Muted;
            _changes.Items.Add(it);
        }
        else
        {
            int n = p.Manifest.Revision;
            _changesCaption.Text = (p.Previous is null
                ? $"What friends will get in revision {n} (first publish)"
                : $"What friends will get in revision {n} (they have {p.Previous.Revision}): {PackDiff.Summary(p.Changes)}")
                + (_preparedStale ? "  - out of date, check again" : "");
            foreach (var c in p.Changes.Where(c => !c.IsHelper))
            {
                var it = HostKit.Row(c.Friendly + (c.IsOwnBuild ? "  (your build)" : ""), VersionText(c));
                it.SubItems[1].ForeColor = Theme.Muted;
                if (c.Kind == PackDiff.Kind.Removed) it.SubItems[0].ForeColor = Theme.Muted;
                _changes.Items.Add(it);
            }
            var helpers = p.Changes.Where(c => c.IsHelper).ToList();
            if (helpers.Count > 0)
            {
                var it = HostKit.Row(p.Previous is null ? $"Helper libraries ({helpers.Count})" : $"Helper libraries updated ({helpers.Count})",
                    string.Join(", ", helpers.Select(h => h.Title)));
                it.ForeColor = Theme.Muted;
                it.SubItems[1].ForeColor = Theme.Muted;
                it.ToolTipText = string.Join("\n", helpers.Select(h => h.ToString()));
                _changes.Items.Add(it);
            }
            if (p.Changes.Count == 0)
            {
                var it = HostKit.Row($"No mod changes since revision {p.Previous?.Revision}. Publishing would only update the notes.", "");
                it.ForeColor = Theme.Muted;
                _changes.Items.Add(it);
            }
        }
        _changes.EndUpdate();

        if (p is not null && p.Problems.Count > 0)
        {
            _problems.Set(StatusKind.Bad, "Not ready to publish", string.Join("\n", p.Problems));
            _problems.Visible = true;
        }
        else if (p is not null && _prepareWarnings.Count > 0)
        {
            _problems.Set(StatusKind.Warn, "Worth a look before publishing", string.Join("\n", _prepareWarnings.Distinct()));
            _problems.Visible = true;
        }
        else _problems.Visible = false;
        FitWrapping();
        UpdateStatus();
    }

    // ================= Publish =================

    async Task PublishAsync()
    {
        if (_busyDepth > 0 || _prepared is not { } p || _preparedStale || _cfg.GithubRepo is not { } repo) return;
        bool dry = SelfTest || _testRun.Checked;
        int n = p.Manifest.Revision;
        var cmd = (PublishPipeline.FindGh() ?? "gh") + " " + string.Join(' ', PublishPipeline.ReleaseArgs(p, repo).Select(PublishPipeline.Quote));
        if (!ConfirmPublish(p, repo, cmd, dry)) return;
        if (!dry && _dirty && !SaveConfig()) return;

        BeginBusy(dry ? $"Test run for revision {n}" : $"Publishing revision {n}", dry ? "Nothing is uploaded." : $"Uploading to {repo} with the GitHub CLI...");
        try
        {
            Log($"--- {(dry ? "Test run" : "Publish")} revision {n}, {DateTime.Now:HH:mm:ss} ---");
            var pipe = new PublishPipeline(Log);
            var rc = await Task.Run(() => pipe.ReleaseAsync(p, repo, _workDir, dry));
            if (rc == 3) { ShowError("GitHub CLI not found", "Install it from cli.github.com, run \"gh auth login\" once, then publish again."); return; }
            if (rc != 0) { ShowError($"Revision {n} wasn't published", $"gh stopped with exit code {rc}. The log on the Publish tab says why. Nothing changed for friends."); return; }
            _released = (dry, n, cmd);
            if (!dry)
            {
                if (_stamp.Checked && HostBepInExDir is { } bep)
                {
                    try { pipe.StampHost(p.Manifest, p.StagingDir, bep); }
                    catch (Exception ex) { Log("Couldn't update your own game's lobby check: " + ex.Message); }
                }
                TellLobby(n);
                // The note belongs to this revision (it's in its changelog now); start the next one empty.
                _cfg.Notes = null;
                _populating = true;
                try { _notes.Text = ""; } finally { _populating = false; }
                SaveConfig();
            }
        }
        catch (Exception ex) { ShowError($"Revision {n} wasn't published", Friendly(ex)); }
        finally { EndBusy(); }
    }

    bool ConfirmPublish(PublishPipeline.Prepared p, string repo, string cmd, bool dry)
    {
        int n = p.Manifest.Revision;
        var lines = p.Changes.Where(c => !c.IsHelper).Select(c => "â€¢ " + c.Friendly).ToList();
        if (p.Changes.Any(c => c.IsHelper)) lines.Add("â€¢ Helper libraries updated");
        if (lines.Count == 0) lines.Add("â€¢ No mod changes");
        var heading = dry ? $"Test run for revision {n}?" : $"Publish revision {n} to your friends?";
        var text = $"Friends will get:\n{string.Join("\n", lines)}\n\nRepository: {repo} (release rev-{n}, marked as latest)"
                   + (NullIfEmpty(p.Manifest.Notes) is { } notes ? $"\nWhat's new: {notes}" : "")
                   + (dry ? "\n\nThis is a test run: nothing is uploaded, and the log shows the exact command."
                          : "\n\nFriends get it the next time they start PEAK (Modded).");
        _confirmText = heading + "\n" + text + "\n\nCommand:\n" + cmd;
        if (SelfTest) { Log("(self-test: confirmation accepted automatically)"); return true; }

        var go = new TaskDialogButton(dry ? "Run test" : $"Publish revision {n}");
        var page = new TaskDialogPage
        {
            Caption = "PeakPack Host", Heading = heading, Text = text, Icon = TaskDialogIcon.Information,
            Buttons = { go, TaskDialogButton.Cancel }, DefaultButton = go, AllowCancel = true,
            Expander = new TaskDialogExpander
            {
                Text = cmd, CollapsedButtonText = "Show the exact command", ExpandedButtonText = "Hide the command",
                Position = TaskDialogExpanderPosition.AfterFootnote,
            },
        };
        return TaskDialog.ShowDialog(this, page) == go;
    }

    // ================= Play as a friend =================

    string FriendViewDir => SelfTest ? Path.Combine(_workDir, "friend-view") : Path.Combine(LocalAppData, "PeakPack-host", "friend-view");

    /// <summary>
    /// Installs exactly what friends get into a separate profile (never his own BepInEx folder, never the game
    /// folder), then starts PEAK through Steam pointed at that profile. Works because Doorstop's command line
    /// (--doorstop-target-assembly) overrides the ini of the Doorstop already in his game folder.
    /// </summary>
    async Task PlayAsFriendAsync()
    {
        if (_busyDepth > 0) return;
        var (ok, why) = FriendViewAvailability();
        if (!ok) { ShowError("Can't play as a friend yet", why); return; }
        var game = _cfg.GameDir!;
        if (GameFolder.IsGameRunning(game)) { ShowError("PEAK is already running", "Close PEAK first, then press Play as a friend again."); return; }

        var fresh = _prepared is not null && !_preparedStale;
        var manifestDir = fresh ? _prepared!.StagingDir : Path.Combine(_workDir, "current");
        BeginBusy("Setting up the friend view", "Installing exactly what friends get into a separate copy...");
        try
        {
            var paths = new AppPaths(FriendViewDir);
            using var dl = new Downloader(CacheDir) { AllowLocalFiles = true };
            var inst = new Installer(paths, dl);
            var lm = await Task.Run(() => inst.LoadManifestAsync(Path.Combine(manifestDir, "manifest.json"), null));
            // Own builds of an unpublished revision aren't on GitHub yet: seed the content-addressed cache from the staged copies.
            foreach (var f in lm.Manifest.Files)
            {
                var src = Path.Combine(manifestDir, f.Url.Split('/')[^1]);
                var dst = dl.CachePathFor(f.Sha256);
                if (File.Exists(src) && !File.Exists(dst)) File.Copy(src, dst);
            }
            var progress = new Progress<SyncProgress>(sp => BusyDetail(sp.Message));
            var res = await Task.Run(() => inst.SyncAsync(lm, game, false, progress, default, new SyncOptions(Strict: true, ManageGameFolder: false)));
            Log($"Friend view: revision {res.Revision} in {paths.DataDir} ({res.Installed.Count} installed, {res.Removed.Count} removed)");
            foreach (var w in res.Warnings) Log("  ! " + w);

            if (GameFolder.IsGameRunning(game)) { ShowError("PEAK is already running", "Close PEAK first, then press Play as a friend again."); return; }
            var method = SelfTest ? Launcher.Method.DryRun : Launcher.Method.Steam;
            var cmd = Launcher.Launch(LaunchMode.Modded, paths, InstallState.Load(paths), game, method);
            Log((method == Launcher.Method.DryRun ? "Would run: " : "Started: ") + cmd);
            _friendResult = $"Revision {res.Revision} synced into {paths.DataDir} ({res.Installed.Count} installed, {res.Removed.Count} removed). "
                            + (method == Launcher.Method.DryRun ? "Would run: " : "Started: ") + cmd;
        }
        catch (Exception ex) { ShowError("Couldn't start the friend view", Friendly(ex)); }
        finally { EndBusy(); }
    }

    // ================= self-test =================

    static async Task Settle()
    {
        for (int i = 0; i < 4; i++) { Application.DoEvents(); await Task.Delay(40); }
    }

    /// <summary>--host-selftest DIR: screenshots of every tab and dialog, then Check, a forced test-run Publish and a
    /// dry "Play as a friend"; writes DIR\status.txt. Never uploads, never launches, never shows a blocking dialog.</summary>
    async Task RunSelfTestAsync(string dir)
    {
        dir = Path.GetFullPath(dir);
        Directory.CreateDirectory(dir);
        var report = new StringBuilder();
        try
        {
            if (_mods.Items.Count > 0) _mods.Items[0].Selected = true;
            if (_builds.Items.Count > 0) _builds.Items[0].Selected = true;
            string[] names = ["1-mods", "2-own-builds", "3-lobby", "4-publish", "5-settings"];
            for (int i = 0; i < names.Length; i++)
            {
                _tabs.SelectedIndex = i;
                await Settle();
                HostKit.Capture(this, Path.Combine(dir, names[i] + ".png"));
            }
            _tabs.SelectedIndex = 0;

            if (_index is not null)
            {
                using (var d = new AddModDialog(_ui, _index, AllModKeys()))
                    d.CaptureOffscreen(Path.Combine(dir, "d1-add-from-thunderstore.png"), () => d.SetQuery("jetpack"));
                var firstMod = _cfg.Mods.Select(e => new ModRow(e, false)).FirstOrDefault(r => r.Id?.Version is not null) ?? _cfg.Mods.Select(e => new ModRow(e, false)).FirstOrDefault();
                if (firstMod?.Id is { } fid && _index.Find(fid.FullName) is { } pkg)
                    using (var d = new PinVersionDialog(_ui, pkg, fid.Version))
                        d.CaptureOffscreen(Path.Combine(dir, "d2-pin-version.png"));
                var matched = _cfg.Mods.Concat(_cfg.HostOnly).Select(e => new ModRow(e, false)).Where(r => r.Id is not null)
                    .Select(r => _index.Find(r.Id!.Value.FullName) is { } pk ? (r.Id!.Value.Version is { } v ? r.Entry : pk.Latest.FullName) : null)
                    .OfType<string>().Take(3).ToList();
                if (_index.Find("Sapphire009-InfiniteGlider") is { } glider) matched.Add(glider.Latest.FullName);
                var unknown = _cfg.CustomFiles.Select(c => c.Source).Where(s => s.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && File.Exists(s)).ToList();
                using (var d = new ImportDialog(_ui, _index, Path.Combine(_cfg.GameDir ?? dir, "BepInEx", "plugins"), CacheDir, AllModKeys().Skip(1), []))
                    d.CaptureOffscreen(Path.Combine(dir, "d3-import-from-game.png"), () => d.ShowResults(matched, unknown));
            }

            // Round-trip: what Save writes (must keep every field, including ones this window doesn't show).
            _cfg.Save(Path.Combine(dir, "saved-publish.json"));

            await CheckAsync();
            _tabs.SelectedIndex = 3;
            await Settle();
            HostKit.Capture(this, Path.Combine(dir, "6-checked.png"));

            await PublishAsync(); // test run forced on in self-test
            await Settle();
            HostKit.Capture(this, Path.Combine(dir, "7-test-run.png"));

            await PlayAsFriendAsync(); // dry: syncs the friend view, never launches
            await Settle();
            HostKit.Capture(this, Path.Combine(dir, "8-play-as-friend.png"));

            // v0.4: hotfix TEST RUN for the first own DLL (the sandbox one isn't a real plugin: the error must show plainly).
            if (_cfg.CustomFiles.FirstOrDefault(IsDll) is { } hf)
            {
                _tabs.SelectedIndex = 1;
                using (var d = new HotfixDialog(_ui, hf, BuildTitle(hf), null, forceTestRun: true, RunHotfixAsync))
                {
                    d.ShowOffscreen();
                    await d.RunAsync();
                    await Settle();
                    HostKit.Capture(d, Path.Combine(dir, "d4-hotfix-test-run.png"));
                    report.AppendLine("Hotfix test run: " + (_hotfixResult ?? "(no result)") + (d.Error is { } he ? $"  [shown as error: {he}]" : ""));
                    d.Close();
                }
                await Settle();
                HostKit.Capture(this, Path.Combine(dir, "9-after-hotfix.png"));
            }

            // v0.4: "Request logs from everyone now" into the (sandbox) host BepInEx folder.
            _tabs.SelectedIndex = 2;
            if (HostBepInExDir is not null)
            {
                RequestLogs();
                report.AppendLine("Request logs: " + (_requestResult ?? "(no result)"));
                if (_requestResult is { } cmdFile && File.Exists(cmdFile)) report.AppendLine("  " + File.ReadAllText(cmdFile).ReplaceLineEndings(" "));
            }
            else report.AppendLine("Request logs: no host BepInEx folder (buttons disabled)");
            await Settle();
            HostKit.Capture(this, Path.Combine(dir, "10-lobby-after-request.png"));
        }
        catch (Exception ex) { report.AppendLine("SELF-TEST EXCEPTION: " + ex); }
        finally
        {
            var (kind, heading, detail) = ComputeStatus();
            report.AppendLine($"Status: [{kind}] {heading}");
            report.AppendLine($"        {detail}");
            report.AppendLine($"Scale: {_ui.Scale}  Config: {_configPath}  Work: {_workDir}");
            if (_prepared is { } p)
            {
                report.AppendLine($"Revision {p.Manifest.Revision} (previous: {p.Previous?.Revision.ToString() ?? "none, first publish"}); {PackDiff.Summary(p.Changes)}");
                report.AppendLine("Changes:");
                foreach (var c in p.Changes) report.AppendLine($"  {c.Friendly}{(c.IsHelper ? " (helper)" : "")}  [{c}]");
                foreach (var pr in p.Problems) report.AppendLine("Problem: " + pr);
            }
            foreach (var w in _prepareWarnings.Distinct()) report.AppendLine("Warning: " + w);
            report.AppendLine("Dry-run gh command:");
            report.AppendLine("  " + (_released?.Command ?? "(none)"));
            report.AppendLine("Confirmation dialog text:");
            report.AppendLine(_confirmText ?? "(none)");
            report.AppendLine("Play as a friend:");
            report.AppendLine("  " + (_friendResult ?? "(not run)"));
            report.AppendLine("Log:");
            report.Append(_logText);
            File.WriteAllText(Path.Combine(dir, "status.txt"), report.ToString(), new UTF8Encoding(true));
        }
    }
}
