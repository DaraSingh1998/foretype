import CForetypeCore
import CryptoKit
import Foundation

struct ModelInfo: Decodable, Equatable {
    let id: String
    let name: String
    let tier: String
    let file: String
    let url: String
    let sha256: String
    let bytes: Int64
    let min_ram_gb: Int
    let license: String
    let recommended: Bool

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Downloads models from the shared catalog (core/models), verifies them against the pinned
/// SHA-256, and resumes interrupted downloads. Files land in
/// ~/Library/Application Support/Foretype/Models; a download is only moved there after it
/// verifies.
final class ModelManager: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case verifying
        case installed
        case failed(String)
    }

    /// Main thread: a model's state changed.
    var onChange: ((ModelInfo, State) -> Void)?

    let catalog: [ModelInfo]
    private(set) var states: [String: State] = [:]
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var completions: [String: (Result<String, Error>) -> Void] = [:]

    static var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    static var dir: URL { ModelLocator.modelsDir }

    /// FORETYPE_MODEL_BASE_URL replaces the download host (tests use a local server).
    private static let baseOverride = ProcessInfo.processInfo.environment["FORETYPE_MODEL_BASE_URL"]

    override init() {
        var list: [ModelInfo] = []
        if let raw = ft_model_catalog(UInt32(ModelManager.ramGB)) {
            list = (try? JSONDecoder().decode([ModelInfo].self, from: Data(String(cString: raw).utf8))) ?? []
            ft_string_free(raw)
        }
        catalog = list
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
        for m in catalog { states[m.id] = isInstalled(m) ? .installed : .notInstalled }
    }

    var recommended: ModelInfo? { catalog.first { $0.recommended } ?? catalog.first }

    func path(_ m: ModelInfo) -> String { ModelManager.dir.appendingPathComponent(m.file).path }

    /// Present with the catalog's size (the hash was checked when it was downloaded).
    func isInstalled(_ m: ModelInfo) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path(m))
        return (attrs?[.size] as? NSNumber)?.int64Value == m.bytes
    }

    func model(forPath p: String) -> ModelInfo? { catalog.first { path($0) == p } }

    private func set(_ m: ModelInfo, _ s: State) {
        states[m.id] = s
        onChange?(m, s)
    }

    func download(_ m: ModelInfo, completion: ((Result<String, Error>) -> Void)? = nil) {
        if isInstalled(m) {
            set(m, .installed)
            completion?(.success(path(m)))
            return
        }
        guard tasks[m.id] == nil else { return }
        var urlString = m.url
        if let base = ModelManager.baseOverride { urlString = base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + m.file }
        guard let url = URL(string: urlString) else { return }
        let task = resumeData[m.id].map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.taskDescription = m.id
        tasks[m.id] = task
        if let completion { completions[m.id] = completion }
        set(m, .downloading(0))
        task.resume()
    }

    func cancel(_ m: ModelInfo) {
        tasks[m.id]?.cancel { [weak self] data in
            DispatchQueue.main.async {
                self?.resumeData[m.id] = data
                self?.tasks[m.id] = nil
                self?.set(m, .notInstalled)
            }
        }
    }

    // MARK: URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let m = catalog.first(where: { $0.id == downloadTask.taskDescription }) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : m.bytes
        set(m, .downloading(Double(totalBytesWritten) / Double(max(total, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = catalog.first(where: { $0.id == downloadTask.taskDescription }) else { return }
        // The temporary file disappears when this method returns: move it first.
        let fm = FileManager.default
        try? fm.createDirectory(at: ModelManager.dir, withIntermediateDirectories: true)
        let partial = ModelManager.dir.appendingPathComponent(m.file + ".part")
        try? fm.removeItem(at: partial)
        do {
            try fm.moveItem(at: location, to: partial)
        } catch {
            return finish(m, .failure(error))
        }
        set(m, .verifying)
        DispatchQueue.global(qos: .utility).async {
            let ok = ModelManager.sha256(of: partial) == m.sha256.lowercased()
            DispatchQueue.main.async {
                guard ok else {
                    try? fm.removeItem(at: partial)
                    return self.finish(m, .failure(NSError(domain: "Foretype", code: 1,
                                                           userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch; the download was discarded."])))
                }
                let final = URL(fileURLWithPath: self.path(m))
                try? fm.removeItem(at: final)
                do {
                    try fm.moveItem(at: partial, to: final)
                    self.finish(m, .success(final.path))
                } catch {
                    self.finish(m, .failure(error))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let m = catalog.first(where: { $0.id == task.taskDescription }) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[m.id] = data }
        finish(m, .failure(error))
    }

    private func finish(_ m: ModelInfo, _ result: Result<String, Error>) {
        tasks[m.id] = nil
        switch result {
        case .success:
            resumeData[m.id] = nil
            set(m, .installed)
        case let .failure(e):
            set(m, .failed(e.localizedDescription))
        }
        completions.removeValue(forKey: m.id)?(result)
    }

    /// `Foretype --download-selftest MODEL_ID`: downloads one catalog model (point
    /// FORETYPE_MODEL_BASE_URL at a local server and FORETYPE_MODELS_DIR at a scratch folder)
    /// and reports whether it verified and installed.
    static func selfTest(id: String) -> Bool {
        let mgr = ModelManager()
        guard let m = mgr.catalog.first(where: { $0.id == id }) else {
            print("unknown model \(id)")
            return false
        }
        var result: Result<String, Error>?
        var last = -1
        mgr.onChange = { _, state in
            if case let .downloading(p) = state, Int(p * 10) != last {
                last = Int(p * 10)
                print(String(format: "downloading %.0f%%", p * 100))
            }
            if case .verifying = state { print("verifying") }
        }
        let t0 = Date()
        mgr.download(m) { result = $0 }
        while result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        switch result! {
        case let .success(path):
            print(String(format: "installed %@ in %.1fs, installed=%@", path, Date().timeIntervalSince(t0), mgr.isInstalled(m) ? "yes" : "no"))
            return mgr.isInstalled(m)
        case let .failure(e):
            print("failed: \(e.localizedDescription); partial file left: \(FileManager.default.fileExists(atPath: mgr.path(m) + ".part"))")
            return false
        }
    }

    /// Streaming SHA-256 (models are gigabytes).
    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
