import Foundation

/// A process to start: executable, arguments, environment.
public struct ProcessSpec: Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// Builds every Wine-side command the way the runtime contract requires (INTERFACES §4):
/// bash sources the runtime's own pp-env.sh, calls pp_env, then execs wine from that same bash,
/// so DYLD_FALLBACK_LIBRARY_PATH survives (SIP strips DYLD_* across protected binaries).
/// WINEDLLOVERRIDES may only ever name winhttp (§3.1 rule); the type makes anything else impossible.
public struct WineCommand {
    public enum Mode: String { case normal, logs }

    public let runtime: URL
    public let prefix: URL
    public let logDir: URL

    public init(runtime: URL, prefix: URL, logDir: URL) {
        self.runtime = runtime; self.prefix = prefix; self.logDir = logDir
    }

    static let wrapper = """
    rt=$1; pfx=$2; mode=$3; shift 3
    . "$rt/share/peakpack/prefix/pp-env.sh" || exit 97
    pp_env "$rt" "$pfx" "$mode" >/dev/null || exit 97
    if [ "${PP_FRONTEND_WINHTTP:-0}" = 1 ]; then export WINEDLLOVERRIDES="winhttp=n,b"; fi
    exec "$rt/bin/wine" "$@"
    """

    /// Knobs passed to pp-env.sh (TUNING.md): Metal HUD, sync mode, extra DXMT config, debug channels.
    public struct Knobs: Equatable {
        public var hud = false
        public var sync: String?
        public var wineDebug: String?
        public init(hud: Bool = false, sync: String? = nil, wineDebug: String? = nil) {
            self.hud = hud; self.sync = sync; self.wineDebug = wineDebug
        }
    }

    public func wine(_ args: [String], mode: Mode = .normal, winhttpOverride: Bool = false, knobs: Knobs = Knobs(),
                     base: [String: String] = ProcessInfo.processInfo.environment) -> ProcessSpec {
        var env = WineCommand.cleanEnvironment(base)
        env["PP_LOG_DIR"] = logDir.path
        env["PP_HUD"] = knobs.hud ? "1" : "0"
        if let s = knobs.sync { env["PP_SYNC"] = s }
        if let d = knobs.wineDebug { env["PP_WINEDEBUG"] = d }
        if winhttpOverride { env["PP_FRONTEND_WINHTTP"] = "1" }
        return ProcessSpec(executable: "/bin/bash",
                           arguments: ["-c", WineCommand.wrapper, "pp-wine", runtime.path, prefix.path, mode.rawValue] + args,
                           environment: env)
    }

    /// `pp-create-prefix.sh <runtime> <prefix> dxmt` (idempotent; wineboot --update on a runtime change).
    public func createPrefix(backend: String = "dxmt", base: [String: String] = ProcessInfo.processInfo.environment) -> ProcessSpec {
        var env = WineCommand.cleanEnvironment(base)
        env["PP_LOG_DIR"] = logDir.path
        return ProcessSpec(executable: "/bin/bash",
                           arguments: [runtime.appendingPathComponent("share/peakpack/prefix/pp-create-prefix.sh").path,
                                       runtime.path, prefix.path, backend],
                           environment: env)
    }

    /// `pp-backend.sh` lives next to the prefix scripts; it takes the backend name (dxmt|dxvk|wined3d).
    public func setBackend(_ backend: String, base: [String: String] = ProcessInfo.processInfo.environment) -> ProcessSpec {
        var env = WineCommand.cleanEnvironment(base)
        env["PP_LOG_DIR"] = logDir.path
        return ProcessSpec(executable: "/bin/bash",
                           arguments: ["-c", """
                           . "$1/share/peakpack/prefix/pp-env.sh" && pp_env "$1" "$2" >/dev/null && exec /bin/bash "$1/share/peakpack/prefix/pp-backend.sh" "$3"
                           """, "pp-backend", runtime.path, prefix.path, backend],
                           environment: env)
    }

    /// Stops every Wine process of OUR prefix only.
    public func killServer(base: [String: String] = ProcessInfo.processInfo.environment) -> ProcessSpec {
        var env = WineCommand.cleanEnvironment(base)
        env["WINEPREFIX"] = prefix.path
        return ProcessSpec(executable: runtime.appendingPathComponent("bin/wineserver").path, arguments: ["-k"], environment: env)
    }

    /// Inherit the user's basics, never stray Wine/DYLD settings.
    public static func cleanEnvironment(_ base: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (k, v) in base {
            if k.hasPrefix("DYLD_") || k.hasPrefix("WINE") || k.hasPrefix("PP_") || k.hasPrefix("DXMT_") || k == "MTL_HUD_ENABLED" { continue }
            if ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL", "__CF_USER_TEXT_ENCODING",
                "STEAM_COMPAT_CLIENT_INSTALL_PATH"].contains(k) {
                env[k] = v
            }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

/// Launch arguments for the Steam bridge launcher (INTERFACES §4.1).
public enum SteamLauncherArgs {
    public static func hold(helperWinDir: String, logWinPath: String, holdUntilExit: Bool, maxHoldMs: Int = 86_400_000) -> [String] {
        var a = [helperWinDir + #"\peakpack_steam_launcher.exe"#,
                 "--forwarder-src", helperWinDir + #"\steamclient64.dll"#,
                 "--log", logWinPath, "--no-launch"]
        // With --hold-until-exit, --hold-ms is only the wait for PEAK to APPEAR. PeakPack may first download mod
        // updates, so allow 30 min; the front end ends the hold itself if the launch fails.
        if holdUntilExit { a += ["--hold-until-exit", "PEAK.exe", "--hold-ms", "1800000"] } else { a += ["--hold-ms", String(maxHoldMs)] }
        return a
    }
}
