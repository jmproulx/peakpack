import Foundation

/// The app replaces itself with a verified new version, keeping the old one for rollback.
/// A small bash watchdog does the swap after the old app quits, starts the new one, and restores the
/// backup if the new version never reports a healthy start (it touches `healthMarker` once its window is up).
public enum SelfUpdateScript {
    public static let healthTimeoutSeconds = 90

    /// Args: $1 old pid, $2 installed app path, $3 staged new app path, $4 backup dir, $5 health marker, $6 result file
    public static let text = """
    #!/bin/bash
    # PEAK (Modded) self-update watchdog. Swaps the app bundle, relaunches, rolls back if the new version fails.
    set -u
    pid=$1; app=$2; new=$3; backup_dir=$4; marker=$5; result=$6
    name=$(basename "$app")
    say() { printf '%s %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$result"; }
    for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then say "old app still running; update postponed"; exit 1; fi
    mkdir -p "$backup_dir"
    rm -rf "$backup_dir/$name"
    if ! mv "$app" "$backup_dir/$name"; then say "could not move the old app aside; update cancelled"; open "$app"; exit 1; fi
    if ! mv "$new" "$app"; then say "could not put the new app in place; restoring"; mv "$backup_dir/$name" "$app"; open "$app"; exit 1; fi
    rm -f "$marker"
    say "swapped; starting the new version"
    open -n "$app" --args --after-update
    for _ in $(seq 1 \(healthTimeoutSeconds)); do
      if [ -f "$marker" ]; then say "new version started OK"; exit 0; fi
      sleep 1
    done
    say "new version did not start within \(healthTimeoutSeconds) s; rolling back"
    pkill -f "$app/Contents/MacOS/" 2>/dev/null
    sleep 2
    rm -rf "$backup_dir/failed.app"
    mv "$app" "$backup_dir/failed.app" && mv "$backup_dir/$name" "$app"
    open -n "$app" --args --after-rollback
    exit 2
    """

    public static func arguments(scriptPath: String, oldPid: Int32, installedApp: String, stagedApp: String,
                                 backupDir: String, healthMarker: String, resultFile: String) -> [String] {
        [scriptPath, String(oldPid), installedApp, stagedApp, backupDir, healthMarker, resultFile]
    }
}

public enum AppLocation {
    /// Gatekeeper runs a quarantined app opened from Downloads from a random read-only path.
    public static func isTranslocated(_ bundlePath: String) -> Bool { bundlePath.contains("/AppTranslocation/") }

    public static func isInApplications(_ bundlePath: String, home: String) -> Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }
}
