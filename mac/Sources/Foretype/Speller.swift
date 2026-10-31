import AppKit
import CForetypeSpell

/// Asks the system spell checker about what is being typed, for the core's typo gate and
/// autocorrect. Runs on the AX thread (NSSpellChecker answers off the main thread in well
/// under a millisecond once warm). It checks in the checker's current language (the one
/// chosen in System Settings, or its automatic pick), so British spellings pass for en_GB
/// and en_IN, and it knows the words the user taught it with Learn Spelling. Passing no
/// language instead accepts a word valid in *any* of the user's languages: with many of them
/// installed, typos such as "recie" passed as words.
///
/// The checker can raise (a stalled spell server: NSXPCSpellServerTimeoutException), so every
/// call goes through `FTSpellGuard` and `ask`: a failure leaves the snapshot's verdicts empty,
/// which the core treats as "not checked", is never cached, and keeps `ask` away from the
/// checker for a while, since each timeout holds up the AX thread.
final class Speller {
    private let spell: FTSpellGuard
    private let now: () -> Date
    /// Verdicts by fragment and corrections by word, so a pause re-read costs nothing.
    private var fragments: [String: String] = [:]
    private var corrections: [String: String] = [:]
    /// No asking before `retryAt`. The pause doubles while the checker keeps failing.
    static let firstPause: TimeInterval = 30
    static let longestPause: TimeInterval = 600
    private let backoffLock = NSLock()
    private var retryAt = Date.distantPast
    private var pause = Speller.firstPause

    /// `checker` and `now` stand in for the real ones in `--speller-selftest`.
    init(checker: (any FTSpellChecking)? = nil, now: @escaping () -> Date = Date.init) {
        spell = FTSpellGuard(checker: checker)
        self.now = now
        guard checker == nil else { return }
        // The first query loads the dictionaries (about 10 ms); do it before typing starts.
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = misspelled("warm")
            _ = Speller.wordList
        }
    }

    /// One call to the checker, or nil when it failed just now or is being left alone.
    private func ask<T>(_ call: () throws -> T) -> T? {
        backoffLock.lock()
        let waiting = now() < retryAt
        backoffLock.unlock()
        if waiting { return nil }
        do {
            let answer = try call()
            backoffLock.lock()
            pause = Speller.firstPause
            backoffLock.unlock()
            return answer
        } catch {
            backoffLock.lock()
            let wait = pause
            retryAt = now().addingTimeInterval(wait)
            pause = min(pause * 2, Speller.longestPause)
            backoffLock.unlock()
            NSLog("Foretype: spell checker failed (%@); not asking for %.0f s", error.localizedDescription, wait)
            return nil
        }
    }

    /// A second opinion on "can this still become a word": the checker's completion list
    /// misses real words (en_IN had nothing for "vom…"), so a fragment is a typo only when no
    /// word in /usr/share/dict/words (235,976, lowercased and sorted, about 5 MB) starts with
    /// it either.
    private static let wordList: [String] = {
        guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Array(Set(s.split(separator: "\n").map { $0.lowercased() })).sorted()
    }()

    private static func wordListHasPrefix(_ fragment: String) -> Bool {
        let words = wordList
        let key = fragment.lowercased()
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo < words.count && words[lo].hasPrefix(key)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c == "-" || c == "_"
    }

    private func misspelled(_ word: String) -> Bool? {
        ask { try spell.isMisspelled(word).boolValue }
    }

    /// Fills `spellFragment`, `spellWord` and `spellCorrection`.
    func annotate(_ s: inout FieldSnapshot) {
        let text = s.textBefore
        let fragment = String(text.reversed().prefix { Speller.isWordChar($0) }.reversed())
        if fragment.count >= 3, fragment.allSatisfy(\.isLetter) {
            s.spellFragment = verdict(fragment) ?? ""
        } else if fragment.isEmpty, text.hasSuffix(" ") {
            let trimmed = String(text.reversed().drop { $0 == " " }.reversed())
            let word = String(trimmed.reversed().prefix { Speller.isWordChar($0) }.reversed())
            if text.count - trimmed.count <= 2, word.count >= 2, word.allSatisfy(\.isLetter),
               let fix = correction(word) {
                s.spellWord = word
                s.spellCorrection = fix
            }
        }
    }

    private func verdict(_ fragment: String) -> String? {
        if let v = fragments[fragment] { return v }
        guard let wrong = misspelled(fragment) else { return nil }
        let v: String
        if !wrong {
            v = "word"
        } else {
            guard let more = ask({ try spell.completions(of: fragment) }) else { return nil }
            v = more.isEmpty && !Speller.wordListHasPrefix(fragment) ? "typo" : "prefix"
        }
        if fragments.count > 2000 { fragments.removeAll() }
        fragments[fragment] = v
        return v
    }

    private func correction(_ word: String) -> String? {
        if let c = corrections[word] { return c.isEmpty ? nil : c }
        guard let wrong = misspelled(word) else { return nil }
        var fix = ""
        if wrong {
            guard let answer = ask({ try spell.correction(of: word) }) else { return nil }
            fix = answer
        }
        if corrections.count > 2000 { corrections.removeAll() }
        corrections[word] = fix
        return fix.isEmpty ? nil : fix
    }
}
