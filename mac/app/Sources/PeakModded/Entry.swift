import AppKit
import PeakModdedCore

/// PEAK (Modded) for Mac. Command-line switches first (test gates, the self-updater), then a normal
/// AppKit app whose single window hosts SwiftUI views.
@main
enum Entry {
    /// Kept alive for the whole run (NSApplication.delegate is weak).
    @MainActor static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if options.printVersion {
            print(AppInfo.version)
            exit(0)
        }
        if options.printStatus {
            // Non-GUI: probe the machine and print JSON (testkit gates; never opens a window or a prompt).
            exit(StatusCLI.run(options: options))
        }
        let app = NSApplication.shared
        let d = AppDelegate(options: options)
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }
}
