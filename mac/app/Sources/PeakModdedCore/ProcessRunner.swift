import Foundation

public struct ProcessResult: Equatable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var output: String
}

/// async wrapper around Foundation.Process.
/// Output always goes to a FILE, never a pipe: Wine leaves daemons (wineserver) and game processes
/// running that inherit stdout/stderr, and a pipe would then never reach EOF.
public enum ProcessRunner {
    public static func run(_ spec: ProcessSpec, logTo log: URL? = nil, timeout: TimeInterval? = nil,
                           captureLimit: Int = 256 * 1024) async throws -> ProcessResult {
        let fm = FileManager.default
        let out = log ?? fm.temporaryDirectory.appendingPathComponent("peakmodded-\(UUID().uuidString).out")
        try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: out.path) { fm.createFile(atPath: out.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: out)
        let start = (try? handle.seekToEnd()) ?? 0
        if log != nil {
            let shown = spec.arguments.map { $0.contains("\n") ? "<script>" : $0 }.joined(separator: " ")
            try? handle.write(contentsOf: Data("\n=== \(Date()) \(spec.executable) \(shown)\n".utf8))
        }
        let bodyStart = (try? handle.offset()) ?? start

        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        p.arguments = spec.arguments
        p.environment = spec.environment
        if let cwd = spec.currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle

        let timedOut = Flag()
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error); return }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if p.isRunning { timedOut.set(); p.terminate() }
                    }
                }
            }
        } onCancel: { if p.isRunning { p.terminate() } }

        if log != nil { try? handle.write(contentsOf: Data("=== exit \(code)\(timedOut.isSet ? " (timeout)" : "")\n".utf8)) }
        let end = (try? handle.offset()) ?? bodyStart
        try? handle.close()
        var text = ""
        if let r = try? FileHandle(forReadingFrom: out) {
            let from = end > bodyStart + UInt64(captureLimit) ? end - UInt64(captureLimit) : bodyStart
            try? r.seek(toOffset: from)
            let d = (try? r.read(upToCount: Int(end - from))) ?? Data()
            text = String(decoding: d, as: UTF8.self)
            try? r.close()
        }
        if log == nil { try? fm.removeItem(at: out) }
        return ProcessResult(exitCode: code, timedOut: timedOut.isSet, output: text)
    }

    /// Fire-and-forget (the launcher hold). The caller keeps the Process to terminate it later.
    public static func start(_ spec: ProcessSpec, logTo log: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        p.arguments = spec.arguments
        p.environment = spec.environment
        p.standardInput = FileHandle.nullDevice
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let h = try FileHandle(forWritingTo: log)
        _ = try? h.seekToEnd()
        p.standardOutput = h
        p.standardError = h
        try p.run()
        return p
    }

    /// Small helper for system tools (pgrep, launchctl, codesign…): output as text, never throws.
    public static func capture(_ exe: String, _ args: [String], timeout: TimeInterval = 20) async -> (Int32, String) {
        let spec = ProcessSpec(executable: exe, arguments: args, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        guard let r = try? await run(spec, timeout: timeout) else { return (-1, "") }
        return (r.exitCode, r.output)
    }
}

final class Flag: @unchecked Sendable {
    private var v = false
    private let lock = NSLock()
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
