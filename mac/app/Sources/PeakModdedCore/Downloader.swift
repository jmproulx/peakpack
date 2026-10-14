import Foundation

public struct DownloadProgress: Equatable {
    public var received: Int64
    public var total: Int64?
    public var bytesPerSecond: Double

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case hostNotAllowed(String)
    case httpStatus(Int, String)
    case cancelled
    case transport(String)

    public var description: String {
        switch self {
        case .hostNotAllowed(let h): return "refused to download from \(h) (not on the allow-list)"
        case .httpStatus(let c, let u): return "HTTP \(c) for \(u)"
        case .cancelled: return "cancelled"
        case .transport(let m): return m
        }
    }

    /// True for problems worth "check your internet connection" advice.
    public var isNetwork: Bool {
        if case .transport = self { return true }
        if case .httpStatus(let c, _) = self { return c >= 500 || c == 429 }
        return false
    }
}

/// Resumable HTTPS file download with progress. Every redirect hop is checked against the allow-list.
/// Data lands in `<dest>.part`; a later call resumes it with a Range request; on success it is renamed.
/// Files written by URLSession in a non-sandboxed app carry no quarantine attribute (no Gatekeeper prompt).
public final class FileDownloader: NSObject, URLSessionDataDelegate {
    private let isAllowed: (URL) -> Bool
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var startOffset: Int64 = 0
    private var total: Int64?
    private var progress: ((DownloadProgress) -> Void)?
    private var lastReport = Date.distantPast
    private var rateWindowStart = Date()
    private var rateWindowBytes: Int64 = 0
    private var rate: Double = 0
    private var task: URLSessionDataTask?
    private var failure: Error?
    private let lock = NSLock()

    public init(isAllowed: @escaping (URL) -> Bool) {
        self.isAllowed = isAllowed
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.httpAdditionalHeaders = ["User-Agent": "PEAK-Modded-Mac"]
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    deinit { session.invalidateAndCancel() }

    public func cancel() { task?.cancel() }

    /// Small files (manifest, SHA256SUMS, API JSON) straight into memory, same host checks.
    public func fetchData(_ url: URL, accept: String? = nil) async throws -> Data {
        guard isAllowed(url) else { throw DownloadError.hostNotAllowed(url.host ?? url.absoluteString) }
        var req = URLRequest(url: url)
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        failure = nil
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req, delegate: nil) } catch {
            if let f = failure { throw f }
            throw DownloadError.transport(error.localizedDescription)
        }
        if let finalURL = resp.url, !isAllowed(finalURL) { throw DownloadError.hostNotAllowed(finalURL.host ?? "?") }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode, url.lastPathComponent)
        }
        return data
    }

    public func download(_ url: URL, to dest: URL, expectedSize: Int64? = nil,
                         progress: @escaping (DownloadProgress) -> Void) async throws {
        guard isAllowed(url) else { throw DownloadError.hostNotAllowed(url.host ?? url.absoluteString) }
        let part = dest.appendingPathExtension("part")
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        var existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expectedSize, existing > expectedSize { try Data().write(to: part); existing = 0 }

        handle = try FileHandle(forWritingTo: part)
        try handle?.seekToEnd()
        startOffset = existing
        received = existing
        total = expectedSize
        failure = nil
        self.progress = progress
        rateWindowStart = Date(); rateWindowBytes = 0; rate = 0

        var req = URLRequest(url: url)
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                let t = session.dataTask(with: req)
                task = t
                t.resume()
            }
        } onCancel: { [weak self] in self?.task?.cancel() }
        try? handle?.close()
        handle = nil
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
    }

    private func finish(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url, isAllowed(u) { completionHandler(request); return }
        failure = DownloadError.hostNotAllowed(request.url?.host ?? "?")
        completionHandler(nil)
        task.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        switch http.statusCode {
        case 200:
            // Server ignored the Range header: start over.
            if startOffset > 0 { try? handle?.truncate(atOffset: 0); received = 0; startOffset = 0 }
            if total == nil, http.expectedContentLength > 0 { total = http.expectedContentLength }
            completionHandler(.allow)
        case 206:
            if total == nil, http.expectedContentLength > 0 { total = startOffset + http.expectedContentLength }
            completionHandler(.allow)
        case 416:
            // Range not satisfiable: the .part is already complete (or bogus); let the hash check decide.
            completionHandler(.cancel)
            failure = nil
            finish(nil)
        default:
            failure = DownloadError.httpStatus(http.statusCode, response.url?.lastPathComponent ?? "")
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch {
            failure = DownloadError.transport("could not write the download: \(error.localizedDescription)")
            dataTask.cancel(); return
        }
        received += Int64(data.count)
        rateWindowBytes += Int64(data.count)
        let now = Date()
        let window = now.timeIntervalSince(rateWindowStart)
        if window >= 1 { rate = Double(rateWindowBytes) / window; rateWindowStart = now; rateWindowBytes = 0 }
        if now.timeIntervalSince(lastReport) >= 0.2 {
            lastReport = now
            progress?(DownloadProgress(received: received, total: total, bytesPerSecond: rate))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let pending = continuation != nil; lock.unlock()
        guard pending else { return }
        if let failure { finish(failure); return }
        if let e = error as? URLError {
            finish(e.code == .cancelled ? DownloadError.cancelled : DownloadError.transport(e.localizedDescription))
            return
        }
        if let error { finish(DownloadError.transport(error.localizedDescription)); return }
        progress?(DownloadProgress(received: received, total: total ?? received, bytesPerSecond: rate))
        finish(nil)
    }
}
