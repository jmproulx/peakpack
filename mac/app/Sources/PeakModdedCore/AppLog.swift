import Foundation
import os

/// The app's own log: ~/Library/Logs/PEAK Modded/PEAK Modded.log (rotated at 2 MB, 3 kept).
public final class AppLog {
    public static let shared = AppLog()
    private let queue = DispatchQueue(label: "peakmodded.log")
    private var url: URL?
    private let os = Logger(subsystem: "com.peakpack.modded", category: "app")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public func configure(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = directory.appendingPathComponent("PEAK Modded.log")
        queue.sync { url = u; rotateIfNeeded(u) }
    }

    public var fileURL: URL? { queue.sync { url } }

    public func info(_ message: String) { write("INFO", message) }
    public func warn(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(message)\n"
        os.log("\(level, privacy: .public) \(message, privacy: .public)")
        queue.async { [weak self] in
            guard let self, let u = self.url else { return }
            if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: u) else { return }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }

    private func rotateIfNeeded(_ u: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue, size > 2_000_000 else { return }
        for i in stride(from: 2, through: 1, by: -1) {
            let from = u.deletingPathExtension().appendingPathExtension("\(i).log")
            let to = u.deletingPathExtension().appendingPathExtension("\(i + 1).log")
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
        let one = u.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: one)
        try? fm.moveItem(at: u, to: one)
    }
}
