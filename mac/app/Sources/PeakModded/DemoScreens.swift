import AppKit
import PeakModdedCore

/// CI-only screenshot hook: `--demo-screen <name> [--appearance light|dark] --data-dir <tmp>` shows one UI state
/// with sample data and does nothing else (no downloads, no Wine, no Steam). `mac-app.yml` captures each one.
enum DemoScreens {
    static let all = [
        "welcome", "step-rosetta", "step-runtime", "step-prefix", "step-steam-install", "step-steam-start",
        "welcome-resume", "error-verifier", "game-instructions", "game-waiting", "game-waiting-hint", "game-downloading", "game-update",
        "step-mods", "step-adopt", "done", "error-network", "error-depot", "error-macos", "error-integrity",
        "home", "home-update", "launching", "launch-sync-failed", "game-update-offer", "playing",
        "repair-confirm", "uninstall-confirm", "uninstalled",
    ]
}

extension AppModel {
    func applyDemo(_ name: String) {
        demoMode = true
        let mods = SetupStep.allCases
        func steps(doneUpTo step: SetupStep?, active: SetupStep? = nil, failed: SetupStep? = nil) {
            var reached = step == nil
            for s in mods {
                if s == active || s == failed { reached = true }
                if s == failed { stepStates[s] = .failed } else if s == active { stepStates[s] = .active }
                else { stepStates[s] = reached ? .pending : .done }
                if s == step { reached = true }
            }
        }
        let host = hostName
        screen = .setup
        switch name {
        case "welcome":
            stepStates = [.macOS: .done, .rosetta: .done]
            waiting = .welcome
        case "welcome-resume":
            steps(doneUpTo: .game); waiting = .welcome; resumable = true
        case "error-verifier":
            steps(doneUpTo: .game, failed: .mods); activeStep = .mods
            problem = FriendError(code: "peakpack-verifier", heading: "PEAK for Mac couldn't check the mod list",
                                  advice: "Your mods weren't changed. Click Repair. If it happens again, click Copy Diagnostics and send it to \(host).",
                                  details: "sync: exit 1. PeakPack: A download didn't pass the safety check. The app's own signature check of the same manifest passed.",
                                  actions: [.repair, .retry, .openLogs])
        case "step-rosetta":
            steps(doneUpTo: nil, active: .rosetta); stepStates[.macOS] = .done
            activeStep = .rosetta
            activity = Activity(title: "Rosetta is needed", detail: "")
            waiting = .rosetta
        case "step-runtime":
            steps(doneUpTo: .rosetta, active: .runtime); activeStep = .runtime
            activity = Activity(title: "Downloading the game engine", detail: "Downloading… 74 of 160 MB · 8.3 MB/s", progress: 0.46)
        case "step-prefix":
            steps(doneUpTo: .runtime, active: .prefix); activeStep = .prefix
            activity = Activity(title: "Preparing PEAK's Windows folder", detail: "This takes about a minute.")
        case "step-steam-install":
            steps(doneUpTo: .prefix, active: .steam); activeStep = .steam; waiting = .steamInstall
        case "step-steam-start":
            steps(doneUpTo: .prefix, active: .steam); activeStep = .steam; waiting = .steamStart
        case "game-instructions", "game-waiting", "game-waiting-hint", "game-downloading", "game-update":
            steps(doneUpTo: .steam, active: .game); activeStep = .game
            game = GameDownloadUI(phase: .instructions, isUpdate: name == "game-update", bytes: 0, expected: env.kit.game.expectedBytes)
            waiting = .gameCommand
            if name == "game-waiting" || name == "game-waiting-hint" { game.phase = .waiting; game.showHint = name == "game-waiting-hint" }
            if name == "game-downloading" { game.phase = .downloading; game.bytes = 1_132_000_000; waiting = nil }
        case "step-mods":
            steps(doneUpTo: .game, active: .mods); activeStep = .mods
            activity = Activity(title: "Installing \(host)'s mods", detail: "Downloading Heli Pilot…", progress: 0.62)
        case "step-adopt":
            steps(doneUpTo: .game, active: .mods); activeStep = .mods
            activity = Activity(title: "Installing \(host)'s mods", detail: "Checking PEAK's folder…")
            waiting = .adoptConfirm
        case "done":
            steps(doneUpTo: .mods); setupFinished = true
        case "error-network":
            steps(doneUpTo: .rosetta, failed: .runtime); activeStep = .runtime
            problem = FriendError.network("runtime download", DownloadError.transport("The Internet connection appears to be offline."))
        case "error-depot":
            steps(doneUpTo: .steam, failed: .game); activeStep = .game
            problem = FriendError(code: "depot-failed", heading: "Steam couldn't download PEAK",
                                  advice: "Make sure Steam is signed in with the account that owns PEAK, then click Try Again.",
                                  details: "Steam console: download_depot: failed, no license for app 3527290", actions: [.retry, .openSteam])
        case "error-macos":
            stepStates = [.macOS: .blocked]; activeStep = .macOS
            problem = FriendError(code: "macos-too-old", heading: "This Mac needs a newer macOS",
                                  advice: "PEAK for Mac needs macOS 14 or later. This Mac has 13.6. Update macOS in System Settings → General → Software Update, then open PEAK (Modded) again.",
                                  actions: [.openSoftwareUpdate])
        case "error-integrity":
            steps(doneUpTo: .rosetta, failed: .runtime); activeStep = .runtime
            problem = FriendError.from(IntegrityError.hashMismatch(file: "peakpack-runtime-pp1-cx26.3.0-x86_64.tar.xz",
                                                                   expected: String(repeating: "a", count: 64), actual: String(repeating: "b", count: 64)),
                                       context: "runtime verify")
        case "home", "home-update":
            setupFinished = true
            screen = .home
            if name == "home-update" {
                updateCandidate = AppUpdateCandidate(version: DottedVersion("0.2.0")!, tag: "mac-build-app-0.2.0", zipName: "PEAK-Modded-Mac-0.2.0.zip",
                                                     zipURL: URL(string: "https://github.com/x")!, sumsURL: URL(string: "https://github.com/y")!,
                                                     size: nil, pinnedSha256: nil)
                notice = "Repair finished. Everything checks out."
            }
        case "launching":
            screen = .launching
            activity = Activity(title: "Starting PEAK with \(host)'s mods", detail: "Downloading Jetpack Boost…", progress: 0.35)
        case "launch-sync-failed":
            screen = .launching
            problem = FriendError(code: "peakpack-failed", heading: "Can't reach Thunderstore",
                                  advice: "Check your internet connection. You can still play with the mods you already have, or play normal PEAK.",
                                  details: "launch: exit 1. HttpRequestException: timed out", actions: [.playWithInstalledMods, .playNormal, .cancel])
        case "game-update-offer":
            screen = .launching
            waiting = .gameUpdateOffer("Steam has a newer PEAK build")
        case "playing":
            screen = .playing
            activity = Activity(title: "PEAK is starting", detail: "")
        case "repair-confirm", "uninstall-confirm":
            setupFinished = true
            screen = .home
        case "uninstalled":
            message = (title: "PEAK (Modded) was moved to the Trash",
                       body: "Its game engine, PEAK's Windows files and the mods are in the Trash too. Empty the Trash to free the space. Steam and your Steam games were not touched.")
        default:
            waiting = .welcome
        }
    }
}
