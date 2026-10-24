import Foundation

/// What Esc does while a suggestion shows (Settings ▸ Typing, Cotypist's three choices). With
/// no suggestion showing, Esc always goes to the app: the key tap that could take it is off.
enum EscBehavior: String, CaseIterable {
    /// Hide the suggestion and keep this field quiet for `EscState.fieldPause` (the default).
    case pauseField
    /// Hide it and switch suggestions off in this app until another app comes to the front.
    case offInApp
    /// Never take Esc: it goes to the app and the suggestion stays until the user types on.
    case passThrough

    var title: String {
        switch self {
        case .pauseField: return L("Dismiss and pause in this field briefly")
        case .offInApp: return L("Turn suggestions off in this app until I switch apps")
        case .passThrough: return L("Leave Esc alone")
        }
    }
}

/// What a dismissing Esc leaves behind: a field kept quiet for a few seconds, or an app kept
/// quiet until the user switches apps. Pure (the caller passes the time), so the self-test can
/// drive it; `Controller` keeps one under its lock.
struct EscState {
    /// How long a dismissed field stays quiet. Five seconds is about three words at an average
    /// 40 words a minute (five at 70): enough to type the phrase Foretype guessed wrong without
    /// a new guess after every key, short enough that suggestions are back for the next
    /// sentence, so the pause never looks like Foretype stopped. Before this, the next key
    /// brought a suggestion straight back. It still doesn't come back on its own: the core
    /// shows none for the dismissed text until it changes.
    static let fieldPause: TimeInterval = 5

    enum Quiet: Equatable {
        /// The paused field: the core still sees its text, but answers with nothing.
        case field
        /// The app switched off: nothing is read or suggested in it.
        case app
    }

    private(set) var pausedField: UInt64 = 0
    private(set) var pausedUntil = Date.distantPast
    /// The app Esc switched off (`offInApp`), until another app comes to the front.
    private(set) var offApp: String?

    /// Whether the key tap takes Esc: only while a suggestion shows, and never when the user
    /// chose to leave it alone.
    static func consumes(_ behavior: EscBehavior, suggestionVisible: Bool) -> Bool {
        suggestionVisible && behavior != .passThrough
    }

    /// Esc dismissed the suggestion in field `fieldKey` of app `bundleId`.
    mutating func dismissed(_ behavior: EscBehavior, fieldKey: UInt64, bundleId: String, now: Date) {
        switch behavior {
        case .pauseField:
            pausedField = fieldKey
            pausedUntil = now.addingTimeInterval(Self.fieldPause)
        case .offInApp:
            offApp = bundleId.isEmpty ? nil : bundleId
        case .passThrough:
            break
        }
    }

    /// An app came to the front (not Foretype itself): the app Esc switched off is on again
    /// once it is another one.
    mutating func appActivated(_ bundleId: String?) {
        if bundleId != offApp { offApp = nil }
    }

    /// Whether, and how, suggestions stay away from this field now. An ended pause is
    /// forgotten.
    mutating func quiet(fieldKey: UInt64, bundleId: String, now: Date) -> Quiet? {
        if let offApp, offApp == bundleId { return .app }
        guard pausedField != 0 else { return nil }
        if now >= pausedUntil {
            pausedField = 0
            return nil
        }
        return fieldKey == pausedField ? .field : nil
    }

    /// The user asked for suggestions here (Ctrl + the key above Tab), resumed the app from
    /// the menu, paused everywhere or chose another Esc behaviour: nothing stays quiet.
    mutating func reset() {
        pausedField = 0
        pausedUntil = .distantPast
        offApp = nil
    }

    /// `Foretype --esc-selftest`: the state logic, no permissions needed.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) {
            if !c { print("FAILED: \(what)"); ok = false }
        }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let mail = "com.apple.mail", notes = "com.apple.Notes"

        // The key tap: only with a suggestion showing; never when Esc is left alone.
        for b in EscBehavior.allCases {
            check(!consumes(b, suggestionVisible: false), "\(b): Esc passes through with no suggestion showing")
            check(consumes(b, suggestionVisible: true) == (b != .passThrough), "\(b): takes Esc over a suggestion")
        }

        // Dismiss and pause in this field briefly.
        var s = EscState()
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0) == nil, "nothing quiet at first")
        s.dismissed(.pauseField, fieldKey: 7, bundleId: mail, now: t0)
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(1)) == .field, "the field is quiet after Esc")
        check(s.quiet(fieldKey: 8, bundleId: mail, now: t0.addingTimeInterval(1)) == nil, "another field in the same app is not")
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(fieldPause - 0.1)) == .field, "still quiet just before the end")
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(fieldPause)) == nil, "the pause ends after \(fieldPause) s")
        check(s.pausedField == 0, "an ended pause is forgotten")
        s.dismissed(.pauseField, fieldKey: 7, bundleId: mail, now: t0)
        s.dismissed(.pauseField, fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(4))
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(8)) == .field, "a second Esc starts the pause again")
        s.dismissed(.pauseField, fieldKey: 9, bundleId: notes, now: t0.addingTimeInterval(8))
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(8.5)) == nil, "only the last field dismissed is paused")
        s.appActivated(notes)
        check(s.quiet(fieldKey: 9, bundleId: notes, now: t0.addingTimeInterval(9)) == .field, "switching apps keeps a field pause")
        s.reset()
        check(s.quiet(fieldKey: 9, bundleId: notes, now: t0.addingTimeInterval(9)) == nil, "reset ends a field pause")

        // Turn suggestions off in this app until I switch apps.
        s = EscState()
        s.dismissed(.offInApp, fieldKey: 7, bundleId: mail, now: t0)
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0.addingTimeInterval(3600)) == .app, "the app stays off, however long")
        check(s.quiet(fieldKey: 8, bundleId: mail, now: t0) == .app, "in every field of it")
        check(s.quiet(fieldKey: 9, bundleId: notes, now: t0) == nil, "other apps are not off")
        s.appActivated(mail)
        check(s.offApp == mail, "the same app coming to the front again keeps it off")
        s.appActivated(notes)
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0) == nil, "switching to another app turns it back on")
        s.dismissed(.offInApp, fieldKey: 7, bundleId: mail, now: t0)
        s.appActivated(nil)
        check(s.offApp == nil, "an app without a bundle ID in front counts as a switch")
        s.dismissed(.offInApp, fieldKey: 7, bundleId: "", now: t0)
        check(s.offApp == nil && s.quiet(fieldKey: 7, bundleId: "", now: t0) == nil, "no bundle ID: nothing to switch off")
        s.dismissed(.offInApp, fieldKey: 7, bundleId: mail, now: t0)
        s.reset()
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0) == nil, "reset turns the app back on")

        // Leave Esc alone: an Esc that reaches the app changes nothing.
        s = EscState()
        s.dismissed(.passThrough, fieldKey: 7, bundleId: mail, now: t0)
        check(s.quiet(fieldKey: 7, bundleId: mail, now: t0) == nil && s.offApp == nil, "leave Esc alone: nothing quiet")

        print(ok ? "esc self-test passed" : "esc self-test failed")
        return ok
    }
}
