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
            var res = await Task.Run(() => inst.SyncAsync(lm, gameDir, false, progress, ct), ct);
            return new Outcome(res, lm.Manifest, false);
        }
        catch (ForeignLoaderException fe)
        {
            if (!askAdopt(fe.GameDir)) throw new OperationCanceledException("Setup was cancelled. Nothing was changed.");
            var res = await Task.Run(() => inst.SyncAsync(lm, gameDir, true, progress, ct), ct);
            return new Outcome(res, lm.Manifest, false);
        }
    }

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
