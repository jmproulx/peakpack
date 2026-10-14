import Foundation
import PeakModdedCore

/// Every failure a friend can see: a plain heading, the next step, buttons, and technical details
/// (behind a disclosure and in "Copy diagnostics").
struct FriendError: Error, Equatable {
    enum Action: Equatable {
        case retry, repair, openSteam, getSteam, openSoftwareUpdate, installRosetta, playWithInstalledMods,
             playNormal, openLogs, moveToApplications, checkForUpdates, cancel
    }

    var code: String
    var heading: String
    var advice: String
    var details: String = ""
    var actions: [Action] = [.retry]

    static func internalError(_ details: String) -> FriendError {
        FriendError(code: "internal", heading: "Something went wrong", advice: "Try again. If it keeps happening, click Copy Diagnostics and send it to \(hostNameForCopy).",
                    details: details, actions: [.retry])
    }

    static var hostNameForCopy = "Joshua"

    static func network(_ what: String, _ error: Error) -> FriendError {
        FriendError(code: "network", heading: "Can't reach the internet",
                    advice: "Check your Wi-Fi, then click Try Again. The download picks up where it stopped.",
                    details: "\(what): \(error)", actions: [.retry])
    }

    static func from(_ error: Error, context: String) -> FriendError {
        if let f = error as? FriendError { return f }
        if let d = error as? DownloadError {
            if d.isNetwork { return network(context, d) }
            if case .cancelled = d { return FriendError(code: "cancelled", heading: "Stopped", advice: "Click Try Again to continue.", actions: [.retry]) }
            return FriendError(code: "download", heading: "A download failed", advice: "Click Try Again. If it keeps failing, click Copy Diagnostics and send it to \(hostNameForCopy).",
                               details: "\(context): \(d)", actions: [.retry])
        }
        if let i = error as? IntegrityError {
            return FriendError(code: "integrity", heading: "A download didn't check out",
                               advice: "The file wasn't the one \(hostNameForCopy) published, so it was not used. Click Try Again to download it again.",
                               details: "\(context): \(i)", actions: [.retry])
        }
        if error is ManifestError {
            return FriendError(code: "manifest-signature", heading: "\(hostNameForCopy)'s mod list couldn't be verified",
                               advice: "Nothing was changed. Try again in a few minutes; if it keeps happening, tell \(hostNameForCopy).",
                               details: "\(context): \(error)", actions: [.retry])
        }
        if let u = error as? URLError { return network(context, u) }
        return internalError("\(context): \(error)")
    }
}
