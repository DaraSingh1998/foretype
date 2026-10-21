import AppKit

/// Asks the system spell checker about what is being typed, for the core's typo gate and
/// autocorrect. Runs on the AX thread (NSSpellChecker answers off the main thread in well
/// under a millisecond once warm). It checks in the checker's current language (the one
/// chosen in System Settings, or its automatic pick), so British spellings pass for en_GB
/// and en_IN, and it knows the words the user taught it with Learn Spelling. Passing no
/// language instead accepts a word valid in *any* of the user's languages: with many of them
/// installed, typos such as "recie" passed as words.
final class Speller {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Verdicts by fragment and corrections by word, so a pause re-read costs nothing.
    private var fragments: [String: String] = [:]
    private var corrections: [String: String] = [:]

    init() {
        // The first query loads the dictionaries (about 10 ms); do it before typing starts.
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = misspelled("warm")
            _ = Speller.wordList
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

    private func misspelled(_ word: String) -> Bool {
        let r = checker.checkSpelling(of: word, startingAt: 0, language: checker.language(), wrap: false,
                                      inSpellDocumentWithTag: tag, wordCount: nil)
        return r.location != NSNotFound
    }

    /// Fills `spellFragment`, `spellWord` and `spellCorrection`.
    func annotate(_ s: inout FieldSnapshot) {
        let text = s.textBefore
        let fragment = String(text.reversed().prefix { Speller.isWordChar($0) }.reversed())
        if fragment.count >= 3, fragment.allSatisfy(\.isLetter) {
            s.spellFragment = verdict(fragment)
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

    private func verdict(_ fragment: String) -> String {
        if let v = fragments[fragment] { return v }
        let v: String
        if !misspelled(fragment) {
            v = "word"
        } else {
            let range = NSRange(location: 0, length: (fragment as NSString).length)
            let more = checker.completions(forPartialWordRange: range, in: fragment, language: checker.language(),
                                           inSpellDocumentWithTag: tag) ?? []
            v = more.isEmpty && !Speller.wordListHasPrefix(fragment) ? "typo" : "prefix"
        }
        if fragments.count > 2000 { fragments.removeAll() }
        fragments[fragment] = v
        return v
    }

    private func correction(_ word: String) -> String? {
        if let c = corrections[word] { return c.isEmpty ? nil : c }
        var fix = ""
        if misspelled(word) {
            let range = NSRange(location: 0, length: (word as NSString).length)
            fix = checker.correction(forWordRange: range, in: word, language: checker.language(),
                                     inSpellDocumentWithTag: tag) ?? ""
        }
        if corrections.count > 2000 { corrections.removeAll() }
        corrections[word] = fix
        return fix.isEmpty ? nil : fix
    }
}
