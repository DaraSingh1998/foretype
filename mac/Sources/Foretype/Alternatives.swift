import Foundation

/// The word alternatives card (D50, Settings ▸ Typing ▸ Show alternatives): the alternatives
/// the suggestion on screen came with, and whether the numbered card shows them. The card
/// comes by itself once typing stops for `pause` with alternatives to offer, or at once on
/// the on-demand key (Option-0), which asks the core when none came; Option-1 to Option-3
/// take an alternative's next word, Esc closes it. Pure (the caller passes the time), so
/// `--alternatives-selftest` can drive it; `Controller` keeps one on the main thread.
struct PickerState {
    /// How long typing must stop before the card shows by itself. Most typists' gaps between
    /// keys inside a phrase stay under half a second (40 words a minute is about 300 ms a
    /// key), so 0.8 s means the writer has stopped to think, and the card never flickers up
    /// while they type on. Cotypist's "after a short pause" is about as long.
    static let pause: TimeInterval = 0.8

    /// What the on-demand key does.
    enum Demand: Equatable {
        /// The card was up: it closes.
        case hide
        /// The alternatives are here: the card shows them now.
        case show
        /// None came with the suggestion: ask the core (`EngineBridge.requestAlternatives`);
        /// its answer shows the card, with or without any.
        case ask
    }

    /// The snapshot revision the suggestion and its alternatives are for.
    private(set) var revision: UInt64 = 0
    private(set) var items: [String] = []
    private(set) var visible = false
    /// The user asked for alternatives to this revision's suggestion and the answer is due.
    private(set) var asked = false
    /// Closed (Esc, or the on-demand key over the card): it doesn't come back by itself for
    /// this suggestion.
    private(set) var closed = false
    /// When the pause before the card began: the suggestion arrived, or the last other key.
    private(set) var since = Date.distantPast

    /// A continuation shows for `revision` with these alternatives; `answer` when it is the
    /// core's answer to an on-demand request. Returns true when the card should show now.
    mutating func shown(revision: UInt64, alternatives: [String], answer: Bool, now: Date) -> Bool {
        if revision != self.revision {
            self.revision = revision
            visible = false
            asked = false
            closed = false
            since = now
        }
        items = alternatives
        if answer {
            guard asked else { return false }
            asked = false
            visible = true
            return true
        }
        if items.isEmpty { visible = false }
        return false
    }

    /// The suggestion went (hidden, or a word of it taken): nothing left to pick from.
    mutating func reset() {
        items = []
        visible = false
        asked = false
    }

    /// The user pressed some other key: the card goes, and the pause starts again.
    mutating func keyPressed(now: Date) {
        visible = false
        since = now
    }

    /// Whether the card should show by itself now: there is something to pick, the user
    /// didn't close it, and typing has stopped long enough.
    func due(now: Date) -> Bool {
        !visible && !closed && !items.isEmpty && now.timeIntervalSince(since) >= Self.pause - 0.01
    }

    /// The card is on screen.
    mutating func opened() {
        visible = true
    }

    /// The on-demand key.
    mutating func demand() -> Demand {
        if visible {
            close()
            return .hide
        }
        if !items.isEmpty {
            visible = true
            return .show
        }
        asked = true
        return .ask
    }

    /// Esc over the card (or the on-demand key): it closes and stays away for this suggestion.
    mutating func close() {
        visible = false
        asked = false
        closed = true
    }

    /// Whether Option-`n` (1 to 3) picks an alternative now.
    func picks(_ n: Int) -> Bool {
        visible && n >= 1 && n <= items.count
    }

    /// How an alternative reads in the card: whole words, so the rest of a word being typed
    /// gets its start back ("Dan" and "iel," read "Daniel,"), and no leading space.
    static func display(_ alternative: String, after textBefore: String) -> String {
        if alternative.first?.isWhitespace ?? true {
            return String(alternative.drop { $0.isWhitespace })
        }
        let partial = textBefore.reversed().prefix { $0.isLetter || $0.isNumber || "'\u{2019}-_".contains($0) }
        return String(partial.reversed()) + alternative
    }

    /// The word Option-N inserts first, as the card shows it (to set it apart from the rest).
    static func firstWord(_ display: String) -> Substring {
        display.prefix { !$0.isWhitespace }
    }

    /// `Foretype --alternatives-selftest [DIR]`: the picker's state logic, no permissions
    /// needed; DIR gets the card as PNGs (light and dark, three rows, one, and none).
    static func selfTest(dir: String? = nil) -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) {
            if !c { print("FAILED: \(what)"); ok = false }
        }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let alts = [" a call", " our team"]

        // The card comes by itself only after the pause, and only with something to offer.
        var p = PickerState()
        check(!p.shown(revision: 1, alternatives: alts, answer: false, now: t0), "never at once")
        check(!p.due(now: t0.addingTimeInterval(pause / 2)), "not before the pause")
        check(p.due(now: t0.addingTimeInterval(pause)), "after the pause")
        p.keyPressed(now: t0.addingTimeInterval(0.5))
        check(!p.due(now: t0.addingTimeInterval(pause)), "another key starts the pause again")
        check(p.due(now: t0.addingTimeInterval(0.5 + pause)), "and it runs from that key")
        p.opened()
        check(p.visible && !p.due(now: t0.addingTimeInterval(9)), "an open card is not due again")
        check(p.picks(1) && p.picks(2) && !p.picks(3) && !p.picks(0), "Option-1 and Option-2 pick, Option-3 has nothing")
        p.keyPressed(now: t0.addingTimeInterval(2))
        check(!p.visible && !p.picks(1), "typing closes it; Option-N goes to the app again")
        _ = p.shown(revision: 2, alternatives: [], answer: false, now: t0.addingTimeInterval(3))
        check(!p.due(now: t0.addingTimeInterval(9)), "a suggestion without alternatives: no card")

        // A new suggestion starts over: its own pause, and a close is forgotten.
        p = PickerState()
        _ = p.shown(revision: 1, alternatives: alts, answer: false, now: t0)
        p.opened()
        p.close()
        check(!p.visible && !p.due(now: t0.addingTimeInterval(9)), "Esc closes it for this suggestion")
        _ = p.shown(revision: 1, alternatives: alts, answer: false, now: t0.addingTimeInterval(1))
        check(!p.due(now: t0.addingTimeInterval(9)), "the same suggestion again keeps it closed")
        _ = p.shown(revision: 2, alternatives: alts, answer: false, now: t0.addingTimeInterval(10))
        check(!p.due(now: t0.addingTimeInterval(10.5)) && p.due(now: t0.addingTimeInterval(10 + pause)), "the next one has its own pause")

        // On demand: the alternatives at hand at once, else ask; the answer shows the card,
        // even with none, but only while it is awaited.
        p = PickerState()
        _ = p.shown(revision: 1, alternatives: alts, answer: false, now: t0)
        check(p.demand() == .show && p.visible, "Option-0 shows them without waiting")
        check(p.demand() == .hide && !p.visible, "Option-0 again closes the card")
        check(!p.due(now: t0.addingTimeInterval(9)), "and it stays closed")
        _ = p.shown(revision: 2, alternatives: [], answer: false, now: t0.addingTimeInterval(1))
        check(p.demand() == .ask && p.asked && !p.visible, "none at hand: ask the core")
        check(p.shown(revision: 2, alternatives: [" here"], answer: true, now: t0.addingTimeInterval(1.1)) && p.visible && p.picks(1), "the answer opens the card")
        _ = p.shown(revision: 3, alternatives: [], answer: false, now: t0.addingTimeInterval(2))
        check(p.demand() == .ask, "asked again")
        check(p.shown(revision: 3, alternatives: [], answer: true, now: t0.addingTimeInterval(2.1)) && p.visible && !p.picks(1), "an answer with none still opens it (it says so)")
        _ = p.shown(revision: 4, alternatives: [], answer: false, now: t0.addingTimeInterval(3))
        check(p.demand() == .ask, "asked for revision 4")
        _ = p.shown(revision: 5, alternatives: [], answer: false, now: t0.addingTimeInterval(3.1))
        check(!p.shown(revision: 4, alternatives: [" late"], answer: true, now: t0.addingTimeInterval(3.2)) && !p.visible, "an answer for older text never opens it")
        _ = p.shown(revision: 6, alternatives: [], answer: false, now: t0.addingTimeInterval(4))
        check(p.demand() == .ask, "asked for revision 6")
        p.close()
        check(!p.shown(revision: 6, alternatives: [" late"], answer: true, now: t0.addingTimeInterval(4.2)), "Esc before the answer: it doesn't open")
        check(!p.shown(revision: 7, alternatives: alts, answer: true, now: t0.addingTimeInterval(5)), "an answer nobody asked for doesn't open it")

        // Taking a word (or hiding the suggestion) leaves nothing to pick.
        p = PickerState()
        _ = p.shown(revision: 1, alternatives: alts, answer: false, now: t0)
        p.opened()
        p.reset()
        check(!p.visible && !p.picks(1) && !p.due(now: t0.addingTimeInterval(9)), "after an accept: no card, no picks")

        // How they read in the card.
        check(display(" a call", after: "Let's set up") == "a call", "a new word loses its space")
        check(display("iel,", after: "Hi Dan") == "Daniel,", "the rest of a word gets its start back")
        check(display("t you", after: "Nice to mee") == "meet you", "with the words after it")
        check(display("’s fine", after: "That") == "That’s fine", "an apostrophe continues the word")
        check(display(", then", after: "First") == "First, then", "punctuation after the word")
        check(display("ा", after: "क्य") == "क्या", "Hindi: a vowel sign completes the syllable")
        check(firstWord("Daniel, how are") == "Daniel,", "the word Option-N takes first")

        if let dir {
            let cards: [(String, [String])] = [
                ("three", [display(" a call this week", after: "Can we set up"), display("iel, thanks", after: "Hi Dan"),
                           display(" our team", after: "Can we set up")]),
                ("one", [display("t you", after: "Nice to mee")]),
                ("hindi", [display(" कल शाम", after: "मैं"), display(" आज", after: "मैं")]),
                ("none", []),
            ]
            for (name, items) in cards {
                for dark in [false, true] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("card-\(name)-\(dark ? "dark" : "light").png")
                    guard let png = GhostPanel.pickerPNG(items, fontSize: 13, dark: dark), (try? png.write(to: url)) != nil else {
                        check(false, "card \(name) written to \(url.path)")
                        continue
                    }
                }
            }
            print("cards written to \(dir)")
        }
        print(ok ? "alternatives self-test passed" : "alternatives self-test failed")
        return ok
    }
}
