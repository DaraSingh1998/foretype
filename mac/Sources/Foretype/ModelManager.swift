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
/// verifies. Also lists what is in that folder, how much disk it uses, and deletes files
/// from it.
final class ModelManager: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        /// Cancelled with resume data kept (across relaunches too: see `saveForRelaunch`).
        case paused(Double)
        case verifying
        case installed
        case failed(String)
    }

    /// A file in the models folder.
    struct LocalFile: Equatable {
        let path: String
        /// Allocated size on disk.
        let bytes: Int64
        /// The catalog entry when the file is that model, complete.
        let model: ModelInfo?

        /// A `.part` file: a download that stopped while it was being verified.
        var incomplete: Bool { path.hasSuffix(".part") }
        var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
        var name: String { model?.name ?? fileName }
    }

    /// Main thread: a model's state changed.
    var onChange: ((ModelInfo, State) -> Void)?

    let catalog: [ModelInfo]
    private(set) var states: [String: State] = [:]
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    /// Last download fraction per model (shown while paused).
    private var progress: [String: Double] = [:]
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
        restorePaused()
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
        set(m, .downloading(resumeData[m.id] == nil ? 0 : progress[m.id] ?? 0))
        task.resume()
    }

    /// Stops a download. When the server allows resuming, the model is `paused` and the
    /// next `download` continues where it stopped.
    func cancel(_ m: ModelInfo) {
        tasks[m.id]?.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resumeData[m.id] = data
                self.tasks[m.id] = nil
                self.set(m, data == nil ? .notInstalled : .paused(self.progress[m.id] ?? 0))
            }
        }
    }

    /// Forgets a paused download and deletes what it had downloaded; the next download starts
    /// from zero.
    func discardPaused(_ m: ModelInfo) {
        if let data = resumeData.removeValue(forKey: m.id), let tmp = ModelManager.resumeTempFile(data) {
            try? FileManager.default.removeItem(at: tmp)
        }
        forgetSaved(m.id)
        progress[m.id] = nil
        if case .paused = states[m.id] ?? .notInstalled { set(m, .notInstalled) }
    }

    /// Paused downloads kept for the next launch: URLSession's resume data and the partial
    /// file it names, moved out of the temporary folder (which macOS empties at restart).
    static var resumeDir: URL { dir.appendingPathComponent(".resume", isDirectory: true) }

    /// At quit: pauses running downloads (waiting up to 2 s for URLSession to hand over
    /// their resume data) and keeps every paused one for the next launch.
    func saveForRelaunch() {
        var pending = tasks.count
        for (id, task) in tasks {
            task.cancel { [weak self] data in
                DispatchQueue.main.async {
                    if let data { self?.resumeData[id] = data }
                    pending -= 1
                }
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while pending > 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        tasks.removeAll()
        for (id, data) in resumeData { persist(id, data) }
        resumeData.removeAll()
    }

    private func persist(_ id: String, _ data: Data) {
        let fm = FileManager.default
        guard let tmp = ModelManager.resumeTempFile(data), fm.fileExists(atPath: tmp.path) else { return }
        try? fm.createDirectory(at: ModelManager.resumeDir, withIntermediateDirectories: true)
        let saved = ModelManager.resumeDir.appendingPathComponent(id + ".partial")
        try? fm.removeItem(at: saved)
        do {
            try fm.moveItem(at: tmp, to: saved)
            try data.write(to: ModelManager.resumeDir.appendingPathComponent(id + ".resume"))
        } catch {
            forgetSaved(id)
        }
    }

    /// At launch: downloads paused in an earlier run come back paused, ready to resume.
    private func restorePaused() {
        let fm = FileManager.default
        for m in catalog where states[m.id] == .notInstalled {
            let saved = ModelManager.resumeDir.appendingPathComponent(m.id + ".partial")
            guard let data = try? Data(contentsOf: ModelManager.resumeDir.appendingPathComponent(m.id + ".resume")) else { continue }
            guard let tmp = ModelManager.resumeTempFile(data), fm.fileExists(atPath: saved.path) else {
                forgetSaved(m.id)
                continue
            }
            try? fm.removeItem(at: tmp)
            guard (try? fm.moveItem(at: saved, to: tmp)) != nil else {
                forgetSaved(m.id)
                continue
            }
            try? fm.removeItem(at: ModelManager.resumeDir.appendingPathComponent(m.id + ".resume"))
            resumeData[m.id] = data
            let kept = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.doubleValue ?? 0
            progress[m.id] = min(kept / Double(max(m.bytes, 1)), 1)
            states[m.id] = .paused(progress[m.id] ?? 0)
        }
    }

    private func forgetSaved(_ id: String) {
        for ext in [".partial", ".resume"] {
            try? FileManager.default.removeItem(at: ModelManager.resumeDir.appendingPathComponent(id + ext))
        }
    }

    /// Bytes a paused (or failed, resumable) download has kept, when known.
    func keptBytes(_ m: ModelInfo) -> Int64? {
        guard let data = resumeData[m.id], let tmp = ModelManager.resumeTempFile(data),
              FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        return ModelManager.sizeOnDisk(tmp.path)
    }

    /// The temporary file a paused download writes into. URLSession names it inside the
    /// resume data (an undocumented keyed archive on current macOS, a plain property list
    /// on older ones); only a `CFNetworkDownload_*` name in this process's temporary folder
    /// is accepted.
    static func resumeTempFile(_ data: Data) -> URL? {
        guard var root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        if let top = (root["$top"] as? [String: Any])?.keys.first, let u = try? NSKeyedUnarchiver(forReadingFrom: data) {
            u.requiresSecureCoding = false
            root = u.decodeObject(forKey: top) as? [String: Any] ?? [:]
            u.finishDecoding()
        }
        guard let name = root["NSURLSessionResumeInfoTempFileName"] as? String,
              name.hasPrefix("CFNetworkDownload_"), !name.contains("/") else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    // MARK: Files

    /// Allocated size of one file (what deleting it frees).
    static func sizeOnDisk(_ path: String) -> Int64 {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
    }

    /// GGUF files and leftover `.part` files in the models folder: complete catalog models
    /// first (catalog order), then the rest by name. A `.part` file that is being verified
    /// right now is left out.
    func localFiles() -> [LocalFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ModelManager.dir.path)) ?? []
        var files: [LocalFile] = []
        for name in names.sorted() where name.hasSuffix(".gguf") || name.hasSuffix(".gguf.part") {
            if name.hasSuffix(".part"), let m = catalog.first(where: { $0.file + ".part" == name }),
               states[m.id] == .verifying { continue }
            let p = ModelManager.dir.appendingPathComponent(name).path
            files.append(LocalFile(path: p, bytes: ModelManager.sizeOnDisk(p), model: catalog.first { $0.file == name && isInstalled($0) }))
        }
        let rank = { (f: LocalFile) in f.model.flatMap { self.catalog.firstIndex(of: $0) } ?? self.catalog.count }
        return files.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Everything in the models folder, as allocated on disk (any file, leftovers included).
    func diskUsage() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: ModelManager.dir, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            sum += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return sum
    }

    /// Deletes a GGUF or `.part` file directly inside the models folder; anything else is
    /// refused. The caller checks that it is not the model in use.
    func delete(path p: String) throws {
        let url = URL(fileURLWithPath: p).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == ModelManager.dir.resolvingSymlinksInPath().path,
              p.hasSuffix(".gguf") || p.hasSuffix(".gguf.part") else {
            throw NSError(domain: "Foretype", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Only model files in the Models folder can be deleted here.")])
        }
        try FileManager.default.removeItem(atPath: p)
        for m in catalog where path(m) == p && states[m.id] == .installed { set(m, .notInstalled) }
    }

    // MARK: URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let m = catalog.first(where: { $0.id == downloadTask.taskDescription }) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : m.bytes
        let p = Double(totalBytesWritten) / Double(max(total, 1))
        // This fires for every chunk; tell the UI (which lists the models folder on every
        // change) only when the progress moved 0.5%.
        var downloading = false
        if case .downloading = states[m.id] ?? .notInstalled { downloading = true }
        let moved = Int((progress[m.id] ?? -1) * 200) != Int(p * 200)
        progress[m.id] = p
        if moved || !downloading { set(m, .downloading(p)) }
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
                                                           userInfo: [NSLocalizedDescriptionKey: L("Checksum mismatch; the download was discarded.")])))
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
        // Replaced, not kept: resume data that just failed would fail again on retry.
        resumeData[m.id] = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        finish(m, .failure(error))
    }

    private func finish(_ m: ModelInfo, _ result: Result<String, Error>) {
        tasks[m.id] = nil
        switch result {
        case .success:
            resumeData[m.id] = nil
            progress[m.id] = nil
            forgetSaved(m.id)
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

    /// `Foretype --resume-selftest MODEL_ID`: starts a download, pauses it past 20%, saves it
    /// as a quit would, then a fresh manager (as after a relaunch) must show it paused with
    /// the bytes kept and finish it with a verified checksum. Point FORETYPE_MODEL_BASE_URL at
    /// a local server that supports Range requests and is slow enough to pause mid-way, and
    /// FORETYPE_MODELS_DIR at a scratch folder.
    static func resumeSelfTest(id: String) -> Bool {
        let first = ModelManager()
        guard let m = first.catalog.first(where: { $0.id == id }) else {
            print("unknown model \(id)")
            return false
        }
        var paused = false
        first.onChange = { _, state in
            if case let .downloading(p) = state, p > 0.2, !paused {
                paused = true
                first.cancel(m)
            }
        }
        first.download(m)
        let deadline = Date().addingTimeInterval(120)
        while !(first.states[m.id].map { if case .paused = $0 { return true } else { return false } } ?? false), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard case let .paused(p) = first.states[m.id] ?? .notInstalled else {
            print("never paused (the server must support Range and be slower than the pause)")
            return false
        }
        print(String(format: "paused at %.0f%%", p * 100))
        first.saveForRelaunch()
        let second = ModelManager()
        guard case let .paused(q) = second.states[m.id] ?? .notInstalled, q > 0.1 else {
            print("after relaunch: not paused (\(String(describing: second.states[m.id])))")
            return false
        }
        print(String(format: "after relaunch: paused with %.0f%% kept", q * 100))
        var result: Result<String, Error>?
        second.download(m) { result = $0 }
        while result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if case let .failure(e) = result! {
            print("resume failed: \(e.localizedDescription)")
            return false
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: resumeDir.path)) ?? []
        print("resumed and verified; installed=\(second.isInstalled(m) ? "yes" : "no"); saved files left: \(leftovers.count)")
        return second.isInstalled(m) && leftovers.isEmpty
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
