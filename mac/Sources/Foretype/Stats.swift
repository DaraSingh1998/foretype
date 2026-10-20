import Foundation

/// What accepting suggestions saved, per local day (the last 30 days) and in total. Only
/// counts are kept: never the inserted text, nor which app it went to. Persisted as one
/// small JSON value in UserDefaults (`usageStats`). Main thread.
final class UsageStats {
    struct Counts: Codable, Equatable {
        /// Tab accepts (next word).
        var wordAccepts = 0
        /// Accept-all accepts (the key above Tab).
        var allAccepts = 0
        /// Runs of non-space characters with a letter or digit in them.
        var words = 0
        var characters = 0
        /// Characters inserted minus the one key press each accept took.
        var keystrokesSaved = 0

        var accepts: Int { wordAccepts + allAccepts }

        static func + (a: Counts, b: Counts) -> Counts {
            Counts(wordAccepts: a.wordAccepts + b.wordAccepts, allAccepts: a.allAccepts + b.allAccepts,
                   words: a.words + b.words, characters: a.characters + b.characters,
                   keystrokesSaved: a.keystrokesSaved + b.keystrokesSaved)
        }
    }

    private struct Stored: Codable {
        /// When counting started (first run of this version, or the last reset).
        var since: Date
        var total = Counts()
        /// Local calendar day ("yyyy-MM-dd") to that day's counts, for the last `keepDays`.
        var days: [String: Counts] = [:]
    }

    static let keepDays = 30
    static let defaultsKey = "usageStats"

    /// Where the JSON lives: UserDefaults in the app, a variable in the self-test.
    struct Storage {
        var load: () -> Data?
        var save: (Data) -> Void

        static let defaults = Storage(load: { UserDefaults.standard.data(forKey: defaultsKey) },
                                      save: { UserDefaults.standard.set($0, forKey: defaultsKey) })
    }

    /// Main thread: the counts changed (an accept or a reset).
    var onChange: (() -> Void)?

    private let storage: Storage
    private let now: () -> Date
    private let dayFormat: DateFormatter
    private var stored: Stored

    init(storage: Storage = .defaults, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        dayFormat = f
        if let data = storage.load(), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        } else {
            stored = Stored(since: now())
        }
        prune()
    }

    private func dayKey(_ date: Date) -> String { dayFormat.string(from: date) }

    /// Keys of the last `n` days, today first.
    private func recentKeys(_ n: Int) -> [String] {
        let start = Calendar.current.startOfDay(for: now())
        return (0..<n).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: start).map(dayKey) }
    }

    /// Drops daily buckets older than `keepDays` (today counts as one). The keys are
    /// fixed-width dates, so they compare as strings.
    private func prune() {
        guard let oldest = recentKeys(Self.keepDays).last else { return }
        stored.days = stored.days.filter { $0.key >= oldest }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { storage.save(data) }
        onChange?()
    }

    /// One accept. `text` is what was inserted; it is counted, not kept.
    func record(inserted text: String, all: Bool) {
        guard !text.isEmpty else { return }
        var c = Counts()
        if all { c.allAccepts = 1 } else { c.wordAccepts = 1 }
        c.words = Self.wordCount(text)
        c.characters = text.count
        c.keystrokesSaved = max(0, c.characters - 1)
        prune()
        let key = dayKey(now())
        stored.days[key] = (stored.days[key] ?? Counts()) + c
        stored.total = stored.total + c
        save()
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    var today: Counts { stored.days[dayKey(now())] ?? Counts() }
    var total: Counts { stored.total }
    var since: Date { stored.since }

    /// The last `n` days including today (at most `keepDays`).
    func lastDays(_ n: Int) -> Counts {
        recentKeys(min(n, Self.keepDays)).reduce(Counts()) { $0 + (stored.days[$1] ?? Counts()) }
    }

    func reset() {
        stored = Stored(since: now())
        save()
    }

    /// `Foretype --stats-selftest`: counting, day buckets, the 30-day window, persistence,
    /// reset, and that no inserted text reaches the stored value. Stores in memory, never in
    /// the app's defaults.
    static func selfTest() -> Bool {
        var saved: Data?
        let memory = Storage(load: { saved }, save: { saved = $0 })
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print("\(cond ? "ok  " : "FAIL") \(what)")
            ok = ok && cond
        }
        // Local noon, so a daylight-saving change never moves a step into another day.
        var t = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let s = UsageStats(storage: memory, now: { t })
        s.record(inserted: " do", all: false)
        s.record(inserted: " the first part", all: true)
        s.record(inserted: ",", all: false)
        let day1 = s.today
        check(day1.wordAccepts == 2 && day1.allAccepts == 1 && day1.accepts == 3, "accepts by kind")
        check(day1.words == 4, "words (punctuation alone is not a word)")
        check(day1.characters == 19, "characters")
        check(day1.keystrokesSaved == 16, "keystrokes saved = characters minus one key per accept")
        let json = String(data: saved ?? Data(), encoding: .utf8) ?? ""
        check(!json.isEmpty && !json.contains("first") && !json.contains(" do"), "no inserted text stored")

        t = t.addingTimeInterval(86_400)
        check(s.today == Counts(), "a new day starts at zero")
        check(s.total == day1 && s.lastDays(7) == day1, "total and last 7 days keep yesterday")
        let reloaded = UsageStats(storage: memory, now: { t })
        check(reloaded.total == day1 && reloaded.lastDays(2) == day1, "persisted across launches")

        for _ in 0..<40 {
            t = t.addingTimeInterval(86_400)
            reloaded.record(inserted: " word", all: false)
        }
        check(reloaded.stored.days.count == keepDays, "only the last \(keepDays) days kept (\(reloaded.stored.days.count))")
        check(reloaded.total.wordAccepts == 42 && reloaded.total.keystrokesSaved == 16 + 40 * 4, "total counts every day")
        check(reloaded.lastDays(7).wordAccepts == 7, "last 7 days")

        reloaded.reset()
        check(reloaded.total == Counts() && reloaded.stored.days.isEmpty && reloaded.since == t, "reset")
        check(UsageStats(storage: memory, now: { t }).total == Counts(), "reset persisted")
        print(ok ? "stats selftest passed" : "stats selftest FAILED")
        return ok
    }
}
