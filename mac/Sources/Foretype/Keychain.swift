import Foundation
import Security

/// The Security calls behind `Keychain`, one generic-password item per account: the login
/// Keychain (`LoginKeychain`), or an in-memory stand-in in `--keychain-selftest`, which must
/// never touch the user's real items.
protocol KeychainBackend {
    func copy(_ account: String) -> (status: OSStatus, data: Data?)
    func update(_ account: String, _ data: Data, label: String) -> OSStatus
    func add(_ account: String, _ data: Data, label: String) -> OSStatus
    func delete(_ account: String) -> OSStatus
}

/// Generic-password items for this app in the login Keychain.
struct Keychain {
    /// A read. Only `.notFound` (errSecItemNotFound) means there is no item. Anything else
    /// (the user denied or cancelled a prompt, the keychain is locked, the app's signature
    /// changed after a rebuild) is `.failed`: the item may well exist, so nothing may
    /// replace it.
    enum Read: Equatable {
        case found(Data)
        case notFound
        case failed(OSStatus)

        var data: Data? {
            if case let .found(d) = self { return d }
            return nil
        }
    }

    let backend: KeychainBackend

    static let login = Keychain(backend: LoginKeychain())

    func get(_ account: String) -> Read {
        let (status, data) = backend.copy(account)
        switch status {
        case errSecSuccess: return data.map(Read.found) ?? .failed(errSecDecode)
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    /// Stores `data`, updating the item in place (adding it only when there is none), so a
    /// failed write leaves the old value; nil or empty deletes the item.
    @discardableResult
    func set(_ account: String, _ data: Data?, label: String) -> Bool {
        guard let data, !data.isEmpty else {
            let s = backend.delete(account)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        switch backend.update(account, data, label: label) {
        case errSecSuccess: return true
        case errSecItemNotFound: return backend.add(account, data, label: label) == errSecSuccess
        default: return false
        }
    }
}

private struct LoginKeychain: KeychainBackend {
    private static let service = "dev.foretype.Foretype"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func copy(_ account: String) -> (status: OSStatus, data: Data?) {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status, out as? Data)
    }

    func update(_ account: String, _ data: Data, label: String) -> OSStatus {
        let change: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        return SecItemUpdate(query(account) as CFDictionary, change as CFDictionary)
    }

    func add(_ account: String, _ data: Data, label: String) -> OSStatus {
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete(_ account: String) -> OSStatus {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Whether a file exists with something in it (an unreadable size counts as something).
func fileHoldsData(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
    return size.map { $0.intValue > 0 } ?? true
}

/// The personalization history's location and its encryption key, kept in the Keychain.
/// The key is only created or read when personalization is on.
enum HistoryStore {
    static var path: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foretype/history.bin").path
    }

    static let account = "history-key"

    enum Key: Equatable {
        /// The 256-bit key as 64 hex characters.
        case ready(String)
        /// A key or a history file exists but the key couldn't be read: the history stays
        /// off for this run, and neither the key nor the file is touched.
        case locked
        /// No key and no history yet, and making a key failed.
        case unavailable
    }

    /// The history's key. A new one is made only when the Keychain has none
    /// (errSecItemNotFound) and there is no history it could have opened; any other
    /// failed read, or a history file without its key, is `.locked`.
    static func key(_ keychain: Keychain = .login, file: String = path) -> Key {
        switch keychain.get(account) {
        case let .found(data) where data.count == 32:
            return .ready(hex(data))
        case .found, .failed:
            return .locked
        case .notFound:
            if fileHoldsData(file) { return .locked }
            var key = Data(count: 32)
            let ok = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) } == errSecSuccess
            guard ok, keychain.set(account, key, label: "Foretype writing history key") else { return .unavailable }
            return .ready(hex(key))
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// The API key for a server backend (llama-server or OpenAI-compatible), kept in the
/// Keychain. A read that fails is not "no key": the engine goes without one for that run,
/// the server fields say the saved key couldn't be read, and the item stays as it is until
/// the user types a new key. Nothing here ever deletes it.
enum ServerKey {
    static let account = "backend-api-key"

    /// What the server fields say about the saved key (never the key itself).
    enum State: Equatable {
        case none
        case saved
        /// Denied, cancelled, a locked keychain, or not text: the item may well exist.
        case unreadable
    }

    /// One Keychain read: the key to give the engine ("" when there is none or it can't be
    /// read) and what the server fields should say.
    static func read(_ keychain: Keychain = .login) -> (key: String, state: State) {
        switch keychain.get(account) {
        case let .found(data):
            guard let key = String(data: data, encoding: .utf8) else { return ("", .unreadable) }
            return (key, key.isEmpty ? .none : .saved)
        case .notFound:
            return ("", .none)
        case .failed:
            return ("", .unreadable)
        }
    }

    enum SaveResult: Equatable {
        /// Nothing typed: the saved key, read or not, was left alone (no Keychain call).
        case kept
        case saved
        /// The Keychain refused the write; the saved key, if any, is unchanged.
        case failed
    }

    /// Stores what the user typed in a server form. An empty (or blank) field keeps the saved
    /// key; anything else replaces it in place (`Keychain.set`), so a refused write leaves the
    /// old one.
    static func save(typed: String?, _ keychain: Keychain = .login) -> SaveResult {
        let key = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .kept }
        return keychain.set(account, Data(key.utf8), label: "Foretype server API key") ? .saved : .failed
    }
}

// MARK: - Self-test

/// `Foretype --keychain-selftest`: the key rules against an in-memory Keychain and files in
/// a temporary folder. Never reads, writes or deletes a real Keychain item or the user's
/// history and details; needs no permission.
enum KeychainSelfTest {
    /// Items in memory, a forced status for reads or writes, and every call made.
    final class Memory: KeychainBackend {
        var items: [String: Data] = [:]
        var readStatus: OSStatus?
        var writeStatus: OSStatus?
        var calls: [String] = []

        func copy(_ account: String) -> (status: OSStatus, data: Data?) {
            calls.append("copy")
            if let s = readStatus { return (s, nil) }
            return items[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }

        func update(_ account: String, _ data: Data, label: String) -> OSStatus {
            calls.append("update")
            if let s = writeStatus { return s }
            guard items[account] != nil else { return errSecItemNotFound }
            items[account] = data
            return errSecSuccess
        }

        func add(_ account: String, _ data: Data, label: String) -> OSStatus {
            calls.append("add")
            if let s = writeStatus { return s }
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }

        func delete(_ account: String) -> OSStatus {
            calls.append("delete")
            if let s = writeStatus { return s }
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }

        var writes: [String] { calls.filter { $0 != "copy" } }
    }

    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print((cond ? "ok   " : "FAIL ") + what)
            ok = ok && cond
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foretype-keychain-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent("history.bin").path
        let old = Data((0..<32).map { UInt8($0) })
        let oldHex = old.map { String(format: "%02x", $0) }.joined()
        let saved = Data("sealed history".utf8)
        func writeHistory(_ data: Data = saved) { FileManager.default.createFile(atPath: history, contents: data) }
        func historyIntact() -> Bool { FileManager.default.contents(atPath: history) == saved }
        func fresh() -> (Memory, Keychain) {
            let m = Memory()
            return (m, Keychain(backend: m))
        }
        let refusals: [(OSStatus, String)] = [
            (errSecUserCanceled, "cancelled"), (errSecAuthFailed, "denied"),
            (errSecInteractionNotAllowed, "locked keychain, no prompt allowed"), (errSecNotAvailable, "no keychain"),
            (errSecNoSuchKeychain, "missing login keychain"), (errSecMissingEntitlement, "missing entitlement"),
            (errSecDecode, "unreadable item"),
        ]

        // Reads tell "no item" from every other failure.
        var (m, k) = fresh()
        check(k.get("a") == .notFound, "missing item reads as not found")
        m.items["a"] = old
        check(k.get("a") == .found(old), "item reads back")
        for (s, what) in refusals {
            m.readStatus = s
            check(k.get("a") == .failed(s), "\(what) reads as a failure, not as no item")
        }

        // Writes update in place; a failed update never deletes or adds.
        (m, k) = fresh()
        check(k.set("a", old, label: "") && m.items["a"] == old && m.writes == ["update", "add"], "first write adds")
        m.calls = []
        check(k.set("a", Data([1]), label: "") && m.items["a"] == Data([1]) && m.writes == ["update"], "second write updates in place")
        m.calls = []
        m.writeStatus = errSecAuthFailed
        check(!k.set("a", old, label: "") && m.writes == ["update"], "denied update fails without deleting or adding")
        m.writeStatus = nil
        check(m.items["a"] == Data([1]), "denied update keeps the old value")
        check(k.set("a", nil, label: "") && m.items["a"] == nil, "nil deletes")
        check(k.set("a", nil, label: ""), "deleting a missing item succeeds")

        // History: not found and no file creates a key.
        (m, k) = fresh()
        var key = HistoryStore.key(k, file: history)
        if case let .ready(hex) = key {
            check(hex.count == 64 && m.items[HistoryStore.account]?.count == 32, "not found, no history: creates a key")
            check(HistoryStore.key(k, file: history) == .ready(hex), "the new key is found next time")
        } else {
            check(false, "not found, no history: creates a key (got \(key))")
        }
        check(!m.calls.contains("delete"), "creating a key deletes nothing")

        // An empty history file has nothing to lose.
        writeHistory(Data())
        (m, k) = fresh()
        key = HistoryStore.key(k, file: history)
        check(key != .locked && key != .unavailable && m.items[HistoryStore.account] != nil, "not found, empty history: creates a key")

        // Not found but a history exists: never a new key over it.
        writeHistory()
        (m, k) = fresh()
        check(HistoryStore.key(k, file: history) == .locked, "not found, history present: locked")
        check(m.writes.isEmpty && m.items.isEmpty && historyIntact(), "not found, history present: no key made, history kept")

        // An existing key is used as it is.
        (m, k) = fresh()
        m.items[HistoryStore.account] = old
        check(HistoryStore.key(k, file: history) == .ready(oldHex) && m.writes.isEmpty, "existing key used, nothing written")

        // Denied, cancelled or any transient error: locked, key and history kept.
        for (s, what) in refusals {
            for present in [true, false] {
                (m, k) = fresh()
                m.items[HistoryStore.account] = old
                m.readStatus = s
                if present { writeHistory() } else { try? FileManager.default.removeItem(atPath: history) }
                let where_ = present ? "history present" : "no history"
                check(HistoryStore.key(k, file: history) == .locked, "\(what), \(where_): locked")
                check(m.writes.isEmpty && m.items[HistoryStore.account] == old, "\(what), \(where_): key untouched")
                if present { check(historyIntact(), "\(what): history file kept") }
            }
        }

        // A malformed item is not replaced.
        writeHistory()
        (m, k) = fresh()
        m.items[HistoryStore.account] = Data([1, 2, 3])
        check(HistoryStore.key(k, file: history) == .locked && m.writes.isEmpty && historyIntact(), "malformed key: locked, kept")

        // No key, no history, and the Keychain refuses the new item: unavailable, nothing deleted.
        try? FileManager.default.removeItem(atPath: history)
        (m, k) = fresh()
        m.writeStatus = errSecInteractionNotAllowed
        check(HistoryStore.key(k, file: history) == .unavailable && !m.calls.contains("delete"), "key can't be stored: unavailable")

        aboutYou(dir: dir, check: check)
        serverKey(refusals: refusals, check: check)
        print(ok ? "keychain self-test passed" : "keychain self-test failed")
        return ok
    }

    /// About You: the same rules for its own key and file.
    private static func aboutYou(dir: URL, check expect: (Bool, String) -> Void) {
        let url = dir.appendingPathComponent("about-you.bin")
        var v = AboutYou()
        v[.name] = "Priya Raman"

        // Not found, no file: the first save makes the key and the file.
        var m = Memory()
        var k = Keychain(backend: m)
        expect(AboutYouStore.load(k, url: url) == AboutYou(), "about you: no file loads empty")
        expect(AboutYouStore.save(v, k, url: url) == .saved && m.items[AboutYouStore.account]?.count == 32, "about you: first save makes a key")
        expect(AboutYouStore.load(k, url: url) == v, "about you: round trip")
        let key = m.items[AboutYouStore.account]
        let file = FileManager.default.contents(atPath: url.path)

        // A later save reuses the key.
        var w = v
        w[.email] = "priya@example.com"
        m.calls = []
        expect(AboutYouStore.save(w, k, url: url) == .saved && m.items[AboutYouStore.account] == key && m.writes.isEmpty,
               "about you: later save reuses the key")
        expect(AboutYouStore.load(k, url: url) == w, "about you: later save reads back")
        let file2 = FileManager.default.contents(atPath: url.path)
        expect(file2 != nil && file2 != file, "about you: file rewritten")

        // Denied or transient: locked; load gives nothing to overwrite with, save refuses.
        for s in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable] {
            m.readStatus = s
            m.calls = []
            expect(AboutYouStore.load(k, url: url) == nil, "about you: read failure \(s) loads as locked")
            expect(AboutYouStore.save(v, k, url: url) == .locked, "about you: read failure \(s) refuses to save")
            expect(m.writes.isEmpty && m.items[AboutYouStore.account] == key, "about you: read failure \(s) keeps the key")
            expect(FileManager.default.contents(atPath: url.path) == file2, "about you: read failure \(s) keeps the file")
        }

        // Not found while the file exists: no replacement key.
        m = Memory()
        k = Keychain(backend: m)
        expect(AboutYouStore.load(k, url: url) == nil, "about you: file without key loads as locked")
        expect(AboutYouStore.save(v, k, url: url) == .locked && m.items.isEmpty && m.writes.isEmpty,
               "about you: file without key refuses to save, no key made")
        expect(FileManager.default.contents(atPath: url.path) == file2, "about you: file without key kept")

        // Deleting on purpose (Clear All) removes both.
        m.items[AboutYouStore.account] = key
        expect(AboutYouStore.delete(k, url: url) && m.items.isEmpty && !FileManager.default.fileExists(atPath: url.path),
               "about you: clear deletes the file and the key")
    }

    /// The server API key: a failed read never blanks, deletes or replaces it.
    private static func serverKey(refusals: [(OSStatus, String)], check expect: (Bool, String) -> Void) {
        let old = Data("sk-old".utf8)
        func fresh(_ item: Data? = old) -> (Memory, AppSettings) {
            let m = Memory()
            m.items[ServerKey.account] = item
            let s = AppSettings()
            s.keychain = Keychain(backend: m)
            return (m, s)
        }

        // Reads: the key, none, or unreadable (never "none" for a failure).
        var (m, s) = fresh()
        expect(ServerKey.read(s.keychain) == ("sk-old", .saved), "server key: reads back")
        (m, s) = fresh(nil)
        expect(ServerKey.read(s.keychain) == ("", .none), "server key: missing item reads as none")
        (m, s) = fresh(Data([0xff, 0xfe]))
        expect(ServerKey.read(s.keychain) == ("", .unreadable) && m.writes.isEmpty, "server key: item that isn't text is unreadable, kept")

        for (status, what) in refusals {
            // The engine gets no key for this run; the item stays.
            (m, s) = fresh()
            m.readStatus = status
            expect(s.readServerKey() == "" && s.serverKeyState == .unreadable, "server key: \(what): engine gets none, fields say unreadable")
            // Refreshing the server fields doesn't ask the Keychain again.
            let reads = m.calls.count
            _ = s.serverKeyState
            _ = s.serverKeyState
            expect(m.calls.count == reads, "server key: \(what): refreshes don't read again")
            // The form starts empty; saving it as it is (the dialog's Save, Settings' Apply)
            // makes no Keychain call at all.
            m.calls = []
            for typed in [nil, "", "  ", "\n"] as [String?] {
                expect(s.saveServerKey(typed: typed) == .kept, "server key: \(what): empty field \(typed?.debugDescription ?? "nil") keeps the key")
            }
            expect(m.calls.isEmpty && m.items[ServerKey.account] == old, "server key: \(what): nothing written, key untouched")
            // A typed key replaces it in place, even while it can't be read.
            expect(s.saveServerKey(typed: " sk-new ") == .saved && m.writes == ["update"], "server key: \(what): typed key updates in place")
            expect(m.items[ServerKey.account] == Data("sk-new".utf8) && s.serverKeyState == .saved, "server key: \(what): typed key stored, trimmed")
            // A refused write keeps the old key.
            (m, s) = fresh()
            m.readStatus = status
            m.writeStatus = status
            expect(s.saveServerKey(typed: "sk-new") == .failed && !m.calls.contains("delete") && !m.calls.contains("add"),
                   "server key: \(what): refused write neither deletes nor adds")
            expect(m.items[ServerKey.account] == old, "server key: \(what): refused write keeps the old key")
        }

        // The Settings window reads once, then uses what it read.
        (m, s) = fresh()
        expect(s.serverKeyState == .saved && s.serverKeyState == .saved && m.calls == ["copy"], "server key: fields read the Keychain once")
        // No key yet: the first typed key adds the item; an empty field adds nothing.
        (m, s) = fresh(nil)
        expect(s.saveServerKey(typed: "") == .kept && m.calls.isEmpty, "server key: no key, empty field: nothing written")
        expect(s.saveServerKey(typed: "sk-1") == .saved && m.writes == ["update", "add"] && s.readServerKey() == "sk-1",
               "server key: first typed key added")
    }
}
