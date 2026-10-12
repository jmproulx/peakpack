using System.Diagnostics;
using PeakPack.App.Host;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// v0.4 "testing with friends": reload-safe own builds and their DLL check, hotfix / rollback of one build,
/// the test-lobby and diagnostics switches, the host id, and commands for the host's running game
/// (request logs, tell the lobby about a new revision).
/// </summary>
public sealed partial class HostForm
{
    CheckBox _buildReload = null!, _testLobby = null!, _diagnostics = null!, _tellLobby = null!;
    Label _buildCheck = null!;
    Button _buildHotfix = null!, _buildRollback = null!, _requestLogs = null!, _openLogs = null!;
    TextBox _hostId = null!;

    /// <summary>One-off outcome shown in the status line (hotfix, log request), cleared by the next edit or check.</summary>
    (StatusKind Kind, string Heading, string Detail)? _notice;
    string? _hotfixResult, _requestResult;
    readonly Dictionary<string, (DateTime Time, Hotfix.DllCheck Check)> _inspectCache = new(StringComparer.OrdinalIgnoreCase);
    string? _rollbackSource; // previous build of the selected own build, or null

    // ================= DLL check =================

    Hotfix.DllCheck? InspectCached(string path)
    {
        if (!File.Exists(path)) return null;
        var t = File.GetLastWriteTimeUtc(path);
        if (_inspectCache.TryGetValue(path, out var c) && c.Time == t) return c.Check;
        Hotfix.DllCheck chk;
        try { chk = Hotfix.Inspect(path); }
        catch (Exception ex) { chk = new(false, false, false, null, null, null, [ex.Message]); }
        _inspectCache[path] = (t, chk);
        return chk;
    }

    /// <summary>The DLL check in plain words (also used by the hotfix dialog).</summary>
    internal static (StatusKind, string) DescribeCheck(Hotfix.DllCheck? c, string path, bool markedReloadSafe)
    {
        if (c is null) return (StatusKind.Bad, $"File not found: {path}");
        if (!c.IsManaged) return (StatusKind.Bad, "Not a .NET plugin DLL, so it can't be reloaded live. It still ships; friends get it when they restart.");
        if (c.LiveReloadOk)
            return (StatusKind.Good, $"Ready for live updates: {c.PluginName ?? c.PluginGuid} {c.PluginVersion} has OnDestroy and an embedded PDB.".Replace("  ", " "));
        return (StatusKind.Warn, (markedReloadSafe ? "Ticked, but this build ships restart-only: " : "Restart-only: ") + string.Join(" ", c.Problems));
    }

    internal static Color ColorFor(StatusKind k) => k switch
    {
        StatusKind.Good => Theme.Good,
        StatusKind.Warn => Theme.Warn,
        StatusKind.Bad => Theme.Bad,
        _ => Theme.Muted,
    };

    static bool IsDll(PublishConfig.CustomFile cf) => cf.Dest.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);

    /// <summary>"Live updates" column text and colour for an own build.</summary>
    (string, Color) LiveColumn(PublishConfig.CustomFile cf)
    {
        if (!IsDll(cf)) return ("-", Theme.Muted);
        if (!cf.ReloadSafe) return ("No", Theme.Muted);
        var c = InspectCached(cf.Source);
        return c?.LiveReloadOk == true ? ("Yes", Theme.Good) : ("Restart-only", Theme.Warn); // ticked, but this build fails the check
    }

    /// <summary>Selection changed on the Own builds list: reload-safe box, DLL check text, rollback availability.</summary>
    void ShowBuildCheck(PublishConfig.CustomFile? cf)
    {
        _populating = true;
        try
        {
            _buildReload.Checked = cf?.ReloadSafe == true;
            _buildReload.Enabled = cf is not null && IsDll(cf);
        }
        finally { _populating = false; }
        if (cf is null) { _buildCheck.Text = ""; _rollbackSource = null; return; }
        if (!IsDll(cf))
        {
            _buildCheck.Text = "Config files are never reloaded live; friends get changes when they restart.";
            _buildCheck.ForeColor = Theme.Muted;
        }
        else
        {
            var (kind, text) = DescribeCheck(InspectCached(cf.Source), cf.Source, cf.ReloadSafe);
            _buildCheck.Text = text;
            _buildCheck.ForeColor = ColorFor(kind);
        }
        try { _rollbackSource = IsDll(cf) ? Hotfix.PreviousBuild(_workDir, cf) : null; }
        catch (Exception ex) { _rollbackSource = null; Log("Couldn't look for earlier builds: " + ex.Message); }
    }

    void SetReloadSafe()
    {
        if (_populating || SelectedBuild() is not { } cf) return;
        cf.ReloadSafe = _buildReload.Checked;
        var (text, color) = LiveColumn(cf);
        var it = _builds.SelectedItems[0];
        it.SubItems[3].Text = text;
        it.SubItems[3].ForeColor = color;
        ShowBuildCheck(cf);
        Changed();
    }

    // ================= hotfix / rollback =================

    string BuildTitle(PublishConfig.CustomFile cf) => cf.Title ?? ThunderstoreIndex.Friendly(cf.Id.Contains('-') ? cf.Id[(cf.Id.IndexOf('-') + 1)..] : cf.Id);

    async Task HotfixAsync(bool rollback)
    {
        if (_busyDepth > 0 || SelectedBuild() is not { } cf || !IsDll(cf)) return;
        if (rollback && _rollbackSource is null) return;
        using var dlg = new HotfixDialog(_ui, cf, BuildTitle(cf), rollback ? _rollbackSource : null, SelfTest, RunHotfixAsync);
        dlg.ShowDialog(this);
        AfterHotfix(dlg);
    }

    void AfterHotfix(HotfixDialog dlg)
    {
        if (dlg.PublishedForReal)
        {
            // The runner saved publish.json (new source and version): show what's on disk now.
            LoadConfig(_configPath);
            _preparedStale = false;
            Populate();
        }
    }

    /// <summary>Runs <see cref="HotfixRunner"/> for the dialog. A test run works on a snapshot of the window's
    /// config (nothing is saved); a real run saves publish.json first, because the runner reads it from disk.</summary>
    async Task<HotfixRunner.Outcome> RunHotfixAsync(HotfixRunner.Options o, Action<string> dialogLog)
    {
        var mode = o.Publish ? (o.Rollback ? "Rolling back" : "Publishing hotfix") : (o.Rollback ? "Rollback test run" : "Hotfix test run");
        BeginBusy(mode, o.Mod);
        _notice = null;
        try
        {
            if (await EnsureIndexAsync(fresh: true) is not { } index) throw new InvalidOperationException("The Thunderstore mod list couldn't be loaded.");
            string configPath;
            if (o.Publish)
            {
                if (_dirty && !SaveConfig()) throw new InvalidOperationException("publish.json couldn't be saved.");
                configPath = _configPath;
            }
            else
            {
                Directory.CreateDirectory(_workDir);
                configPath = Path.Combine(_workDir, "hotfix-test-publish.json");
                _cfg.Save(configPath);
            }
            Log($"--- {mode}: {o.Mod}, {DateTime.Now:HH:mm:ss} ---");
            using var dl = new Downloader(CacheDir);
            var runner = new HotfixRunner(line => { dialogLog(line); Log(line); });
            var opts = o with { ConfigPath = configPath, WorkDir = _workDir, HostBepInEx = HostBepInExDir, PreviousPath = _previousOverride };
            try
            {
                var oc = await Task.Run(() => runner.RunAsync(opts, index, dl));
                Log(oc.Summary);
                _hotfixResult = $"exit {oc.ExitCode}: {oc.Summary}" + (oc.CommandFile is { } cmd ? $" (command {cmd})" : "");
                _notice = oc.ExitCode == 0
                    ? (StatusKind.Good, o.Publish ? $"{mode} done" : $"{mode} finished: nothing was uploaded", oc.Summary)
                    : (StatusKind.Bad, $"{mode} failed", oc.Summary);
                return oc;
            }
            catch (Exception ex)
            {
                _hotfixResult = "error: " + ex.Message;
                Log("ERROR: " + ex.Message);
                _notice = (StatusKind.Bad, $"{mode} stopped", ex.Message);
                throw;
            }
            finally
            {
                if (_prepared is not null) _preparedStale = true; // the runner rebuilt <work>\staging
            }
        }
        finally
        {
            EndBusy();
            RefreshChanges();
        }
    }

    // ================= Lobby: testing with friends =================

    Control BuildTestingGroup()
    {
        var box = new GroupBox { Text = "Testing with friends", Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(12, 6, 12, 10), Margin = _ui.Pad(0, 0, 0, 12), FlatStyle = FlatStyle.System };
        var g = HostKit.Grid(_ui, 1);
        g.AutoSize = true;
        g.Dock = DockStyle.Top;
        g.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Rows(g, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize);

        _testLobby = new CheckBox { Text = "&Test lobby: live updates for my mods", AutoSize = true, FlatStyle = FlatStyle.System, Margin = _ui.Pad(0, 2, 0, 0) };
        g.Controls.Add(_testLobby, 0, 0);
        var risk = HostKit.WrapText(_ui, "Uses AutoReload for your reload-safe own builds (Own builds tab). Friends who opted in get new builds of those mods while playing. Best between rounds; a mod that doesn't clean up in OnDestroy can misbehave until restart.", muted: true);
        risk.Margin = _ui.Pad(18, 0, 0, 6); // under the checkbox text
        g.Controls.Add(risk, 0, 1);

        var diagRow = HostKit.Flow(_ui);
        _diagnostics = new CheckBox { Text = "Ask friends for their &error logs while they're in my lobby", AutoSize = true, FlatStyle = FlatStyle.System, Margin = _ui.Pad(0, 2, 8, 0) };
        diagRow.Controls.Add(_diagnostics);
        diagRow.Controls.Add(new Label { AutoSize = true, ForeColor = Theme.Muted, Text = "(each friend chooses whether to share, in PeakPack)", Margin = _ui.Pad(0, 6, 0, 0) });
        g.Controls.Add(diagRow, 0, 2);

        var idRow = HostKit.Grid(_ui, 4);
        idRow.AutoSize = true;
        idRow.Margin = _ui.Pad(0, 8, 0, 0);
        idRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        idRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        idRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        idRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _hostId = HostKit.Box(_ui, readOnly: true);
        _requestLogs = HostKit.Button(_ui, "Re&quest logs from everyone now", (_, _) => RequestLogs());
        _openLogs = HostKit.Button(_ui, "&Open friends' logs", (_, _) => OpenFriendLogs());
        _requestLogs.Margin = _ui.Pad(10, 2, 0, 2);
        _openLogs.Margin = _ui.Pad(6, 2, 0, 2);
        idRow.Controls.Add(HostKit.Field(_ui, "Your host id:"), 0, 0);
        idRow.Controls.Add(_hostId, 1, 0);
        idRow.Controls.Add(_requestLogs, 2, 0);
        idRow.Controls.Add(_openLogs, 3, 0);
        g.Controls.Add(idRow, 0, 3);
        box.Controls.Add(g);

        _testLobby.CheckedChanged += (_, _) =>
        {
            if (_populating) return;
            (_cfg.Lobby ??= new LobbySettings()).TestLobby = _testLobby.Checked;
            Changed();
            RefreshBuilds();
        };
        _diagnostics.CheckedChanged += (_, _) =>
        {
            if (_populating) return;
            (_cfg.Lobby ??= new LobbySettings()).Diagnostics = _diagnostics.Checked;
            Changed();
        };
        return box;
    }

    void PopulateTesting()
    {
        _populating = true;
        try
        {
            _testLobby.Checked = _cfg.Lobby?.TestLobby == true;
            _diagnostics.Checked = _cfg.Lobby?.Diagnostics ?? true;
            _tellLobby.Checked = _tellLobbyChoice ?? true;
        }
        finally { _populating = false; }
        UpdateHostId();
    }

    bool? _tellLobbyChoice;

    void UpdateHostId()
    {
        List<string> ids;
        try { ids = _cfg.EffectiveHostIds(); } catch { ids = []; }
        _hostId.Text = ids.Count > 0 ? string.Join(", ", ids) : "Not known yet: host a lobby with the companion, then publish";
        _hostId.ForeColor = ids.Count > 0 ? Theme.Text : Theme.Muted;
    }

    void RequestLogs()
    {
        if (HostBepInExDir is not { } bep) return;
        try
        {
            var path = LobbyCommands.Write(bep, LobbyCommands.Snapshot);
            Log("Asked the lobby for logs: " + path);
            _requestResult = path;
            _error = null;
            _notice = (StatusKind.Info, "Asked everyone in your lobby for their logs",
                "Your game must be running and hosting. Logs from friends who share them arrive in BepInEx\\PeakPack-remote-logs (Open friends' logs).");
            UpdateStatus();
        }
        catch (Exception ex)
        {
            _requestResult = "error: " + ex.Message;
            ShowError("Couldn't send the request to your game", ex.Message);
        }
    }

    void OpenFriendLogs()
    {
        if (HostBepInExDir is not { } bep) return;
        try
        {
            var dir = LobbyCommands.RemoteLogsDir(bep);
            Directory.CreateDirectory(dir);
            if (!SelfTest) Process.Start("explorer.exe", $"\"{dir}\"");
        }
        catch (Exception ex) { ShowError("Couldn't open the friends' logs folder", ex.Message); }
    }

    /// <summary>After a real publish of a test-lobby pack: drop a "hot-update" command for the host's companion.</summary>
    void TellLobby(int revision)
    {
        if (_cfg.Lobby?.TestLobby != true || !_tellLobby.Checked || HostBepInExDir is not { } bep) return;
        try
        {
            var path = LobbyCommands.Write(bep, LobbyCommands.HotUpdate, revision);
            Log($"Told your lobby about revision {revision} ({path}). Your game must be running and hosting.");
        }
        catch (Exception ex) { Log("Couldn't tell your lobby: " + ex.Message); }
    }

    void UpdateTestingButtons(bool idle)
    {
        var cf = SelectedBuild();
        bool dll = cf is not null && IsDll(cf);
        _buildHotfix.Enabled = idle && dll && File.Exists(cf!.Source);
        _buildRollback.Enabled = idle && dll && _rollbackSource is not null;
        bool bep = HostBepInExDir is not null;
        _requestLogs.Enabled = idle && bep;
        _openLogs.Enabled = bep;
        bool testLobby = _cfg.Lobby?.TestLobby == true;
        _tellLobby.Visible = testLobby;
        _tellLobby.Enabled = bep && !_testRun.Checked;
    }
}
