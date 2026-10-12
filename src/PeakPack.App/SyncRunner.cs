using PeakPack.Core;

namespace PeakPack.App;

/// <summary>Shared "check for updates + sync" used by the main window and the one-click shortcut.</summary>
public static class SyncRunner
{
    public sealed record Outcome(SyncResult Result, PackManifest Manifest, bool RestartingForAppUpdate);

    /// <param name="askAdopt">Called (on the UI thread) if a foreign mod loader is found in the game folder. Return true to back it up and continue.</param>
    public static async Task<Outcome> RunAsync(AppSession s, string gameDir, Func<string, bool> askAdopt,
        IProgress<SyncProgress> progress, string[] restartArgs, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(s.ManifestLocation))
            throw new InvalidOperationException("This copy of PeakPack has no mod list address built in. Ask the host for a new copy.");

        using var dl = s.NewDownloader();
        var inst = new Installer(s.Paths, dl);
        progress.Report(new SyncProgress("Checking for updates..."));
        var lm = await Task.Run(() => inst.LoadManifestAsync(s.ManifestLocation, s.PublicKey, ct), ct);

        if (await SelfUpdate.TryUpdateAsync(s.Paths, dl, lm.Manifest, lm.Location, restartArgs, ct))
            return new Outcome(new SyncResult(), lm.Manifest, true);

        try
        {
            var res = await Task.Run(() => inst.SyncAsync(lm, gameDir, false, progress, ct, Options(s)), ct);
            return new Outcome(res, lm.Manifest, false);
        }
        catch (ForeignLoaderException fe)
        {
            if (!askAdopt(fe.GameDir)) throw new AdoptDeclinedException();
            var res = await Task.Run(() => inst.SyncAsync(lm, gameDir, true, progress, ct, Options(s)), ct);
            return new Outcome(res, lm.Manifest, false);
        }
    }

    static SyncOptions Options(AppSession s) => new(ShortcutName: s.Config.ShortcutName);

    /// <summary>The friend said no to moving an existing mod loader aside. (Derives from OperationCanceledException so
    /// the windows treat it as "cancelled"; headless mode tells it apart from a network timeout.)</summary>
    public sealed class AdoptDeclinedException() : OperationCanceledException("Setup was cancelled. Nothing was changed.");

    public sealed record Check(PackManifest Manifest, List<PackDiff.Change> Changes, bool IsNewRevision);

    /// <summary>Downloads and verifies the manifest only, and works out what an update would change. Changes nothing.</summary>
    public static async Task<Check> CheckAsync(AppSession s, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(s.ManifestLocation))
            throw new InvalidOperationException("This copy of PeakPack has no mod list address built in. Ask the host for a new copy.");
        using var dl = s.NewDownloader();
        var inst = new Installer(s.Paths, dl);
        var lm = await Task.Run(() => inst.LoadManifestAsync(s.ManifestLocation, s.PublicKey, ct), ct);
        var changes = inst.PendingChanges(lm.Manifest);
        return new Check(lm.Manifest, changes, lm.Manifest.Revision != s.LoadState().InstalledRevision);
    }

    /// <summary>"Something went wrong, here's what to do": a heading, plain advice, and technical details for the host.</summary>
    public sealed record Problem(string Heading, string Advice, string Details);

    public static Problem Describe(Exception ex, string host) => ex switch
    {
        FileNotFoundException or HttpRequestException { StatusCode: System.Net.HttpStatusCode.NotFound } =>
            new("The mod list isn't available", $"{host} may not have published the pack yet, or the link changed. Ask {host} for the latest PeakPack link. Normal PEAK still works.", ex.Message),
        HttpRequestException when ex.Message.Contains("(404)") =>
            new("The mod list isn't available", $"{host} may not have published the pack yet, or the link changed. Ask {host} for the latest PeakPack link. Normal PEAK still works.", ex.Message),
        HttpRequestException or TaskCanceledException { InnerException: TimeoutException } or System.Net.Sockets.SocketException =>
            new("Can't reach the internet", "PeakPack couldn't check for mod updates. Check your connection and try again. Normal PEAK still works.", ex.Message),
        Core.SecurityException =>
            new("A download didn't pass the safety check", $"Nothing was installed or changed. Tell {host}: the pack may need to be published again.", ex.Message),
        DirectoryNotFoundException =>
            new("PEAK wasn't found", "Make sure PEAK is installed in Steam, then try again. PeakPack will ask for the folder if it still can't find it.", ex.Message),
        UnauthorizedAccessException or IOException =>
            new("Couldn't write a file", "Close PEAK if it's running, then try again. If it keeps happening, restart your PC.", ex.Message),
        InvalidDataException when ex.Message.Contains("newer version of the app") =>
            new("This copy of PeakPack is too old", $"Download PeakPack again from {host}'s link and run it once.", ex.Message),
        _ => new("Something went wrong", $"Try again. If it keeps happening, click \"Copy details\" and send them to {host}.", ex.Message),
    };

    public static string Friendly(Exception ex) => ex switch
    {
        HttpRequestException or TaskCanceledException { InnerException: TimeoutException } =>
            "Couldn't reach the internet to check for mod updates.\n\n" + ex.Message,
        Core.SecurityException => "A download didn't pass the safety check, so nothing was installed.\n\n" + ex.Message,
        UnauthorizedAccessException or IOException =>
            "Couldn't write a file. If PEAK is running, close it and try again.\n\n" + ex.Message,
        _ => ex.Message,
    };
}
