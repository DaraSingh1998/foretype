import Contacts
import CryptoKit
import Foundation

/// The user's own details (Settings ▸ About You), one set per macOS account. The core fills
/// one in exactly when the text asks for it ("My email is ", "Regards,\n") and, if allowed,
/// names the writer in the prompt. Stored encrypted (`AboutYouStore`), never in UserDefaults.
struct AboutYou: Codable, Equatable {
    enum Field: String, CaseIterable {
        case name, email, phone, company, jobTitle = "job_title", address, website

        var label: String {
            switch self {
            case .name: return L("Name:")
            case .email: return L("Email:")
            case .phone: return L("Phone:")
            case .company: return L("Company:")
            case .jobTitle: return L("Job title:")
            case .address: return L("Address:")
            case .website: return L("Website:")
            }
        }

        /// Shown next to the ghost text, so a fill reads as one of your details.
        var tag: String {
            switch self {
            case .name: return L("your name")
            case .email: return L("your email")
            case .phone: return L("your phone number")
            case .company: return L("your company")
            case .jobTitle: return L("your job title")
            case .address: return L("your address")
            case .website: return L("your website")
            }
        }
    }

    /// The master switch.
    var enabled = true
    /// Name, job title and company go into the prompt as a "written by" line (built-in or
    /// Apple model only; never sent to a server). On by default: it didn't hurt the corpus
    /// replay (docs/MEASUREMENTS.md).
    var inPrompt = true
    /// Values by `Field.rawValue`.
    var values: [String: String] = [:]
    /// Fields the user switched off (kept, not used).
    var unused: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        inPrompt = try c.decodeIfPresent(Bool.self, forKey: .inPrompt) ?? true
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        unused = try c.decodeIfPresent(Set<String>.self, forKey: .unused) ?? []
    }

    subscript(_ f: Field) -> String {
        get { values[f.rawValue] ?? "" }
        set { values[f.rawValue] = newValue.isEmpty ? nil : newValue }
    }

    func uses(_ f: Field) -> Bool { !unused.contains(f.rawValue) }

    mutating func setUses(_ f: Field, _ on: Bool) {
        if on { unused.remove(f.rawValue) } else { unused.insert(f.rawValue) }
    }

    /// FORETYPE_ABOUT_YOU (testing): a JSON object by field key ("name", "email", "job_title",
    /// …, "in_prompt"). The app then uses these instead of the stored details and neither
    /// reads nor writes the store.
    static func fromEnvironment() -> AboutYou? {
        guard let raw = ProcessInfo.processInfo.environment["FORETYPE_ABOUT_YOU"],
              let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        var v = AboutYou()
        for f in Field.allCases {
            if let s = o[f.rawValue] as? String { v[f] = s }
        }
        v.inPrompt = o["in_prompt"] as? Bool ?? true
        return v
    }

    var isEmpty: Bool {
        Field.allCases.allSatisfy { self[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// What debug logs mask (`Log.mask`): every run of 4 or more letters or digits in any
    /// value, used or not, longest first. Matches the core's own `UserDetails::redact`.
    var logMasks: [String] {
        let pieces = values.values.flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 4 }
        return Array(Set(pieces)).sorted { $0.count > $1.count }
    }

    /// For `ft_engine_set_details`: switched-off fields (or all, with the master switch off)
    /// are empty. Values are one line; the core ignores multi-line ones.
    func coreJSON() -> String {
        var d: [String: Any] = ["in_prompt": enabled && inPrompt]
        for f in Field.allCases {
            let v = self[f].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            d[f.rawValue] = enabled && uses(f) ? v : ""
        }
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// `~/Library/Application Support/Foretype/about-you.bin`: the details as JSON, sealed with
/// ChaCha20-Poly1305 under a 256-bit key kept in the Keychain (account `about-you-key`). The
/// key is created on the first save and read only when the file exists.
enum AboutYouStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foretype/about-you.bin")
    }

    private static let account = "about-you-key"

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The saved details, or empty ones (no file, no key, or a file that doesn't decrypt).
    static func load() -> AboutYou {
        guard let box = try? Data(contentsOf: url), let key = Keychain.get(account), key.count == 32,
              let plain = open(box, key: key), let v = try? JSONDecoder().decode(AboutYou.self, from: plain) else {
            return AboutYou()
        }
        return v
    }

    /// Saves `v` encrypted; with no values left it deletes the file and the key instead.
    @discardableResult
    static func save(_ v: AboutYou) -> Bool {
        if v.isEmpty { return delete() }
        var key = Keychain.get(account) ?? Data()
        if key.count != 32 {
            key = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
            guard Keychain.set(account, key, label: "Foretype About You key") else { return false }
        }
        guard let plain = try? JSONEncoder().encode(v), let box = seal(plain, key: key) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try box.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Removes the file and its key.
    @discardableResult
    static func delete() -> Bool {
        try? FileManager.default.removeItem(at: url)
        return Keychain.set(account, nil, label: "") && !exists
    }

    static func seal(_ plain: Data, key: Data) -> Data? {
        try? ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined
    }

    static func open(_ box: Data, key: Data) -> Data? {
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box) else { return nil }
        return try? ChaChaPoly.open(sealed, using: SymmetricKey(data: key))
    }

    /// `--about-selftest`: the JSON the core gets, and the sealed round trip, with a key in
    /// memory (no Keychain, no file).
    static func selfTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print((cond ? "ok   " : "FAIL ") + what)
            ok = ok && cond
        }
        var v = AboutYou()
        v[.name] = "Priya Raman"
        v[.email] = "priya@example.com"
        v[.address] = "12 Lake Road\nPune 411001"
        v.setUses(.email, false)
        let core = (try? JSONSerialization.jsonObject(with: Data(v.coreJSON().utf8))) as? [String: Any] ?? [:]
        check(core["name"] as? String == "Priya Raman", "name sent")
        check(core["email"] as? String == "", "switched-off field sent empty")
        check(core["address"] as? String == "12 Lake Road, Pune 411001", "address joined onto one line")
        check(core["in_prompt"] as? Bool == true, "writer line on by default")
        v.enabled = false
        let off = (try? JSONSerialization.jsonObject(with: Data(v.coreJSON().utf8))) as? [String: Any] ?? [:]
        check(AboutYou.Field.allCases.allSatisfy { (off[$0.rawValue] as? String) == "" }, "master switch off sends nothing")
        let key = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        let plain = (try? JSONEncoder().encode(v)) ?? Data()
        let box = seal(plain, key: key) ?? Data()
        check(!box.isEmpty && box.range(of: Data("Priya".utf8)) == nil, "sealed file holds no plain text")
        let back = open(box, key: key).flatMap { try? JSONDecoder().decode(AboutYou.self, from: $0) }
        check(back == v, "round trip")
        let other = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        check(open(box, key: other) == nil, "another key can't open it")
        let old = try? JSONDecoder().decode(AboutYou.self, from: Data(#"{"values":{"name":"A"}}"#.utf8))
        check(old?.enabled == true && old?.inPrompt == true && old?[.name] == "A", "missing keys take defaults")
        check(Set(v.logMasks) == ["Priya", "Raman", "priya", "example", "Lake", "Road", "Pune", "411001"], "log masks")
        return ok
    }
}

/// The "me" card in Contacts, read once when the user asks (Settings ▸ About You).
enum MeCard {
    /// A bare dev binary has no Info.plist with a Contacts usage string, and macOS ends a
    /// process that asks without one.
    static var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
    }

    enum Failure: Error { case denied, noCard }

    /// Asks for Contacts access (macOS prompts the first time) and reads the card. Calls back
    /// on the main thread.
    static func read(_ done: @escaping (Result<[AboutYou.Field: String], Failure>) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { return DispatchQueue.main.async { done(.failure(.denied)) } }
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
                CNContactPostalAddressesKey as CNKeyDescriptor, CNContactUrlAddressesKey as CNKeyDescriptor,
            ]
            guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else {
                return DispatchQueue.main.async { done(.failure(.noCard)) }
            }
            var out: [AboutYou.Field: String] = [:]
            out[.name] = CNContactFormatter.string(from: me, style: .fullName)
            out[.email] = me.emailAddresses.first.map { $0.value as String }
            out[.phone] = me.phoneNumbers.first?.value.stringValue
            out[.company] = me.organizationName
            out[.jobTitle] = me.jobTitle
            out[.address] = me.postalAddresses.first.map {
                CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                    .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: ", ")
            }
            out[.website] = me.urlAddresses.first.map { $0.value as String }
            let found = out.compactMapValues { v in
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            DispatchQueue.main.async { done(.success(found)) }
        }
    }
}
