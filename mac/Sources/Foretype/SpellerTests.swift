import CForetypeSpell
import Foundation

/// `Foretype --speller-selftest`: a checker that raises as the spell server does must leave a
/// snapshot unchecked, never cached and without a crash, and be left alone for the back-off;
/// then the real checker through the same path. Made-up times, so nothing waits.
enum SpellerSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print("\(cond ? "ok  " : "FAIL") \(what)")
            ok = ok && cond
        }
        func annotated(_ speller: Speller, _ text: String) -> FieldSnapshot {
            var s = FieldSnapshot()
            s.textBefore = text
            speller.annotate(&s)
            return s
        }

        var t = Date(timeIntervalSinceReferenceDate: 0)
        var fake = FTRaisingSpellChecker()
        var speller = Speller(checker: fake, now: { t })
        fake.raising = ["check"]
        check(annotated(speller, "wor").spellFragment.isEmpty, "a raising check leaves the fragment unchecked")
        let calls = fake.calls
        check(calls > 0, "the raising checker was reached")
        t += Speller.firstPause - 1
        fake.raising = []
        check(annotated(speller, "wor").spellFragment.isEmpty && annotated(speller, "word").spellFragment.isEmpty,
              "not checked during the back-off")
        check(fake.calls == calls, "no call reaches the checker during the back-off")
        t += 1
        check(annotated(speller, "wor").spellFragment == "word", "asks again after the back-off; the failure wasn't cached")

        // The second failure in a row waits twice as long; a success starts over.
        fake.raising = ["check"]
        _ = annotated(speller, "fir")
        t += Speller.firstPause
        _ = annotated(speller, "sec")
        fake.raising = []
        t += Speller.firstPause * 2 - 1
        check(annotated(speller, "thi").spellFragment.isEmpty, "the pause doubles while failures repeat")
        t += 1
        check(annotated(speller, "thi").spellFragment == "word", "and ends")
        fake.raising = ["check"]
        _ = annotated(speller, "fou")
        fake.raising = []
        t += Speller.firstPause
        check(annotated(speller, "fou").spellFragment == "word", "a success resets the pause")
        fake.raising = ["language"]
        check(annotated(speller, "fif").spellFragment.isEmpty, "the checker's language is guarded too")
        fake.raising = []
        check(annotated(speller, "thi").spellFragment == "word", "verdicts already known stay usable during the back-off")
        t += Speller.firstPause

        fake.raising = ["check"]
        var reached = 0
        for _ in 0..<8 {
            let before = fake.calls
            _ = annotated(speller, "cap")
            if fake.calls > before { reached += 1 }
            t += Speller.longestPause
        }
        fake.raising = []
        check(reached == 8, "the pause stops growing at its longest (\(reached) of 8 retries)")
        t += Speller.longestPause

        // A failure partway through a verdict or a correction.
        fake = FTRaisingSpellChecker()
        speller = Speller(checker: fake, now: { t })
        fake.misspells = true
        fake.fix = "receive"
        fake.raising = ["completions"]
        check(annotated(speller, "zqxj").spellFragment.isEmpty, "raising completions leave the fragment unchecked")
        fake.raising = []
        t += Speller.firstPause
        check(annotated(speller, "zqxj").spellFragment == "typo", "and the verdict comes once it answers")
        fake.raising = ["correction"]
        let unchecked = annotated(speller, "recieve ")
        check(unchecked.spellWord.isEmpty && unchecked.spellCorrection.isEmpty, "a raising correction leaves no autocorrect")
        fake.raising = []
        t += Speller.firstPause
        check(annotated(speller, "recieve ").spellCorrection == "receive", "and the failure wasn't cached as no correction")

        // The real checker. Verdicts depend on this Mac's language, so only that there is one.
        let real = annotated(Speller(), "the")
        check(!real.spellFragment.isEmpty, "the real checker answers through the guard (\(real.spellFragment))")
        print(ok ? "speller selftest passed" : "speller selftest FAILED")
        return ok
    }
}
