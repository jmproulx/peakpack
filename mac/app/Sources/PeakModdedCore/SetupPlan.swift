import Foundation

/// The first-run steps, in order (MacPort DESIGN §3.5 "Friend experience").
public enum SetupStep: String, CaseIterable, Codable, Identifiable {
    case macOS, rosetta, runtime, prefix, steam, game, mods

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macOS: return "Check this Mac"
        case .rosetta: return "Install Rosetta"
        case .runtime: return "Download the game engine"
        case .prefix: return "Prepare PEAK's Windows folder"
        case .steam: return "Sign in to Steam"
        case .game: return "Get PEAK from Steam"
        case .mods: return "Install the mods"
        }
    }

    /// SF Symbols available on macOS 12 (SF Symbols 3).
    public var symbol: String {
        switch self {
        case .macOS: return "laptopcomputer"
        case .rosetta: return "cpu"
        case .runtime: return "shippingbox"
        case .prefix: return "folder.badge.gearshape"
        case .steam: return "person.crop.circle"
        case .game: return "arrow.down.circle"
        case .mods: return "puzzlepiece.extension"
        }
    }
}

/// A live look at the machine; the plan is a pure function of it (unit-tested).
public struct ProbeSnapshot: Equatable {
    public var macOS: DottedVersion
    public var minMacOS: DottedVersion
    public var appleSilicon: Bool
    public var rosettaInstalled: Bool
    /// The ACTIVE runtime (state), which may lag behind the wanted one during an update.
    public var installedRuntimeId: String?
    public var wantedRuntimeId: String
    /// The WANTED runtime's files are unpacked and usable.
    public var runtimeFilesPresent: Bool
    public var prefixRuntimeId: String?
    public var steamInstalled: Bool
    public var steamRunning: Bool
    public var steamClientPresent: Bool
    public var gameComplete: Bool
    public var peakPackInstalled: Bool
    public var modsInstalled: Bool

    public init(macOS: DottedVersion, minMacOS: DottedVersion, appleSilicon: Bool, rosettaInstalled: Bool,
                installedRuntimeId: String?, wantedRuntimeId: String, runtimeFilesPresent: Bool, prefixRuntimeId: String?,
                steamInstalled: Bool, steamRunning: Bool, steamClientPresent: Bool, gameComplete: Bool,
                peakPackInstalled: Bool, modsInstalled: Bool) {
        self.macOS = macOS; self.minMacOS = minMacOS; self.appleSilicon = appleSilicon; self.rosettaInstalled = rosettaInstalled
        self.installedRuntimeId = installedRuntimeId; self.wantedRuntimeId = wantedRuntimeId
        self.runtimeFilesPresent = runtimeFilesPresent; self.prefixRuntimeId = prefixRuntimeId
        self.steamInstalled = steamInstalled; self.steamRunning = steamRunning; self.steamClientPresent = steamClientPresent
        self.gameComplete = gameComplete; self.peakPackInstalled = peakPackInstalled; self.modsInstalled = modsInstalled
    }
}

public enum StepState: Equatable {
    case done
    case todo
    /// Cannot be done by the app at all (e.g. macOS too old); the reason is shown with a next step.
    case blocked(String)
}

public enum SetupPlan {
    public static func state(of step: SetupStep, _ p: ProbeSnapshot) -> StepState {
        switch step {
        case .macOS:
            return p.macOS >= p.minMacOS ? .done
                : .blocked("PEAK for Mac needs macOS \(p.minMacOS.parts.first.map(String.init) ?? "14") or later. This Mac has \(p.macOS).")
        case .rosetta:
            return (!p.appleSilicon || p.rosettaInstalled) ? .done : .todo
        case .runtime:
            // The wanted runtime is unpacked (it becomes the active one once the prefix accepted it).
            return p.runtimeFilesPresent ? .done : .todo
        case .prefix:
            return (p.prefixRuntimeId != nil && p.prefixRuntimeId == p.installedRuntimeId
                    && p.installedRuntimeId == p.wantedRuntimeId) ? .done : .todo
        case .steam:
            return (p.steamInstalled && p.steamRunning && p.steamClientPresent) ? .done : .todo
        case .game:
            return p.gameComplete ? .done : .todo
        case .mods:
            return (p.peakPackInstalled && p.modsInstalled) ? .done : .todo
        }
    }

    /// The first step that still needs doing, in order. nil = ready to play.
    public static func next(_ p: ProbeSnapshot) -> SetupStep? {
        SetupStep.allCases.first { state(of: $0, p) != .done }
    }

    /// Steps the friend has to see on a launch after setup (e.g. Steam closed, runtime update).
    /// Steam not running is NOT a setup problem on a daily launch: the launcher opens Steam itself.
    public static func readyToPlay(_ p: ProbeSnapshot) -> Bool {
        SetupStep.allCases.allSatisfy { step in
            if step == .steam { return p.steamInstalled }
            return state(of: step, p) == .done
        }
    }
}
