using PeakPack.Core;

namespace PeakPack.App;

/// <summary>Everything the GUI needs, built from the baked-in pack.config.json plus (test-only) overrides.</summary>
public sealed class AppSession
{
    public PackConfig Config { get; }
    public AppPaths Paths { get; }
    public string ManifestLocation { get; }
    public string? PublicKey { get; }
    public bool AllowLocal { get; }
    public string? GameDirOverride { get; }
    public string? ShortcutDirOverride { get; }
    public Launcher.Method LaunchMethod { get; }
    public string[] RawArgs { get; }

    public AppSession(string[] args)
    {
        RawArgs = args;
        using var s = typeof(AppSession).Assembly.GetManifestResourceStream("PeakPack.App.pack.config.json");
        Config = PackConfig.Load(s);
        Paths = new AppPaths(Get(args, "--data-dir"));
        ManifestLocation = Get(args, "--manifest") ?? Config.ManifestUrl;
        PublicKey = Get(args, "--public-key") ?? Config.PublicKey;
        AllowLocal = Has(args, "--allow-local");
        GameDirOverride = Get(args, "--game-dir");
        ShortcutDirOverride = Get(args, "--shortcut-dir");
        LaunchMethod = Get(args, "--launch-method") switch
        {
            "direct" => Launcher.Method.DirectExe,
            "dry" => Launcher.Method.DryRun,
            _ => Launcher.Method.Steam,
        };
    }

    public InstallState LoadState() => InstallState.Load(Paths);
    public bool IsInstalled => File.Exists(Paths.PreloaderPath) && LoadState().InstalledRevision > 0;

    /// <summary>Auto-detect PEAK: override > previously used > Steam library scan. Null = ask the user.</summary>
    public string? FindGameDir()
    {
        foreach (var c in new[] { GameDirOverride, LoadState().GameDir, SteamLocator.FindGameDir() })
            if (GameFolder.LooksLikePeak(c)) return c;
        return null;
    }

    public Downloader NewDownloader() => new(Paths.CacheDir) { AllowLocalFiles = AllowLocal };

    public Setup.Options SetupOptions => Setup.DefaultOptions(Config, Paths, ShortcutDirOverride) is var o && ShortcutDirOverride is null && !Paths.IsDefaultLocation
        ? o with { DesktopDir = null, StartMenuDir = null } // test data dir without a shortcut dir: don't touch the real desktop
        : o;

    /// <summary>Arguments to pass along when the app restarts itself or creates shortcuts in test mode.</summary>
    public string[] PassThroughArgs(params string[] mode)
    {
        var list = new List<string>(mode);
        foreach (var k in new[] { "--data-dir", "--manifest", "--public-key", "--game-dir", "--shortcut-dir", "--launch-method" })
            if (Get(RawArgs, k) is { } v) { list.Add(k); list.Add(v); }
        if (AllowLocal) list.Add("--allow-local");
        return list.ToArray();
    }

    public static string? Get(string[] a, string k)
    {
        var i = Array.FindIndex(a, x => x.Equals(k, StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
    }
    public static bool Has(string[] a, string k) => a.Contains(k, StringComparer.OrdinalIgnoreCase);
}
