import AppKit
import ApplicationServices
import Carbon
import ScreenCaptureKit
import Vision

/// Text from other apps' windows (D42): the document, slides or web page open beside the
/// field, on any display, and windows looked at in the last 10 minutes. Opt-in ("Use text
/// from other apps"), memory only, and never for a server backend.
///
/// A refresh runs on its own queue when focus moves to another window or app, and after a
/// typing pause at most every 20 s; never per keystroke. It lists the windows on screen
/// (`CGWindowListCopyWindowInfo`, every display's current Space, front to back), counts a
/// window as visible when at least a quarter of it isn't covered by windows in front, and
/// reads each allowed one through Accessibility (the document's text area, a web page
/// through text markers, else the window's static texts), at most 50 ms per app. Where
/// Accessibility gives almost nothing (and only on Macs with 12 GB or more, with Screen
/// Recording, not while saving energy) the window is captured with ScreenCaptureKit and read
/// with Vision's fast OCR; a window whose picture didn't change keeps its text. The window
/// that had focus at the previous refresh is read too, covered or not: a window the user
/// switched away from is what they are about to quote.
///
/// Windows no longer on screen stay as "recently viewed" for 10 minutes after they were last
/// seen. The pool is sent to the core (`ft_engine_set_context`) only when a window's text,
/// whether it is visible, or a recent window's time changed.
final class ContextPool {
    /// What may be read. Everything here is checked before any text is read.
    struct Gate {
        var ownPid: pid_t = ProcessInfo.processInfo.processIdentifier
        /// Bundle IDs never read (password managers by default; the user's list).
        var neverRead: Set<String> = []
        /// FORETYPE_ONLY_APPS (`AppSettings.onlyAppsAllow`).
        var onlyApps: (pid_t, String) -> Bool = { _, _ in true }
        /// Apps where suggestions are off (the user's, the compatibility database's unless
        /// switched on) or paused.
        var excluded: (String) -> Bool = { _ in false }

        func allows(pid: pid_t, bundleId: String) -> Bool {
            pid != ownPid && !bundleId.isEmpty && bundleId != Bundle.main.bundleIdentifier
                && !neverRead.contains(bundleId) && onlyApps(pid, bundleId) && !excluded(bundleId)
        }

        /// A window that forbids capture (`NSWindow.sharingType = .none`, kCGWindowSharingState
        /// 0), or a private browsing window where its title says so.
        static func allowsWindow(title: String, sharingNone: Bool) -> Bool {
            !sharingNone && !isPrivateBrowsing(title)
        }

        static func isPrivateBrowsing(_ title: String) -> Bool {
            let t = title.lowercased()
            return ["private browsing", "incognito", "inprivate", "private window"].contains { t.contains($0) }
        }
    }

    /// Password managers: never read unless the user takes them off the list (D42).
    static let passwordManagers = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop", "com.dashlane.Dashlane",
        "com.lastpass.LastPass", "org.keepassxc.keepassxc", "com.keepersecurity.passwordmanager",
        "in.sinew.Enpass-Desktop", "com.markmcguill.strongbox.mac", "me.proton.pass.electron",
        "com.nordsec.nordpass", "com.hicknhacksoftware.MacPass", "com.outercorner.Secrets",
    ]

    /// One window's text.
    struct Entry: Equatable {
        /// "pid:window number".
        var key: String
        var pid: pid_t = 0
        var app: String
        var bundleId: String
        var title: String
        var urlHost = ""
        var text: String
        var visible: Bool
        var display = 0
        var lastSeen = Date()
        var ocr = false
        /// The OCR'd picture's hash: an unchanged window isn't read again.
        var imageHash: UInt64?
    }

    /// The pool itself, as plain data (`--context-selftest` checks it).
    struct Store {
        static let keep: TimeInterval = 600
        static let maxEntries = 12
        private(set) var entries: [String: Entry] = [:]

        /// One refresh: `read` were read now; every other window is no longer on screen.
        mutating func merge(_ read: [Entry], now: Date) {
            for k in entries.keys { entries[k]?.visible = false }
            for var e in read {
                e.lastSeen = now
                entries[e.key] = e
            }
            expire(now: now)
            if entries.count > Store.maxEntries {
                let keepKeys = Set(ordered.prefix(Store.maxEntries).map(\.key))
                entries = entries.filter { keepKeys.contains($0.key) }
            }
        }

        /// Drops windows last seen 10 minutes ago or more; true if any went.
        @discardableResult
        mutating func expire(now: Date) -> Bool {
            let before = entries.count
            entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) < Store.keep }
            return entries.count != before
        }

        mutating func removeAll(where shouldRemove: (Entry) -> Bool) {
            entries = entries.filter { !shouldRemove($0.value) }
        }

        mutating func clear() { entries.removeAll() }

        /// Windows on screen first, then recently viewed ones, newest first.
        var ordered: [Entry] {
            entries.values.sorted {
                if $0.visible != $1.visible { return $0.visible }
                if !$0.visible, $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.key < $1.key
            }
        }

        /// Changes when what the core gets changes: a window's text or visibility, or when a
        /// window no longer on screen was last seen (a visible one's time moves every refresh).
        var signature: Int {
            var h = Hasher()
            for e in ordered {
                h.combine(e.key)
                h.combine(e.title)
                h.combine(e.text)
                h.combine(e.visible)
                if !e.visible { h.combine(e.lastSeen.timeIntervalSince1970) }
            }
            return h.finalize()
        }

        var nextExpiry: Date? {
            entries.values.map { $0.lastSeen.addingTimeInterval(Store.keep) }.min()
        }

        /// `ft_engine_set_context`'s JSON.
        func json() -> String {
            let passages: [[String: Any]] = ordered.map {
                ["app": $0.app, "bundle_id": $0.bundleId, "window_title": $0.title, "url_host": $0.urlHost, "text": $0.text,
                 "captured_at": $0.lastSeen.timeIntervalSince1970, "visible": $0.visible, "display": $0.display]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["passages": passages])
            return String(data: data, encoding: .utf8)!
        }
    }

    /// Pool queue: the core's JSON, whenever the pool changed.
    var onChange: ((String) -> Void)?

    private let queue = DispatchQueue(label: "foretype.context", qos: .utility)
    private let lock = NSLock()
    // Under `lock`:
    private var _enabled = false
    private var _allowOCR = false
    private var _gate = Gate()
    private var focus: (pid: pid_t, title: String, frame: CGRect?)?
    private var generation = 0
    private var switchGeneration = 0
    private var lastRefresh = Date.distantPast
    private var lastJSON = #"{"passages":[]}"#
    // On `queue`:
    private var store = Store()
    private var pushed: Int?
    /// The window that had focus at the last refresh, read once focus leaves it.
    private var lastFocused: (key: String, pid: pid_t, window: AXUIElement)?
    private var expiryTimer: DispatchSourceTimer?

    private let switchDelay = 0.3
    private let pauseDelay = 2.0
    private let minInterval: TimeInterval = 20
    private static let maxChars = 6000
    private static let minVisibleChars = 1500
    private static let appBudget: CFAbsoluteTime = 0.05
    private static let maxWindows = 8

    /// Macs under 12 GB read Accessibility text only, never OCR other windows (D42).
    static var memoryAllowsOCR: Bool { ProcessInfo.processInfo.physicalMemory >= 12 << 30 }

    var enabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    /// The last JSON sent, for a new engine.
    var currentJSON: String {
        lock.lock(); defer { lock.unlock() }
        return lastJSON
    }

    /// Turns reading on or off; off forgets everything and sends an empty pool.
    func configure(enabled: Bool, allowOCR: Bool, gate: Gate) {
        lock.lock()
        let was = _enabled
        _enabled = enabled
        _allowOCR = allowOCR
        _gate = gate
        if !enabled { generation += 1; switchGeneration += 1; focus = nil }
        lock.unlock()
        if !enabled {
            if was { reset() }
            return
        }
        // Apps the gate now rejects (added to the never-read list, suggestions turned off) go.
        queue.async { [weak self] in
            guard let self else { return }
            self.store.removeAll { !gate.allows(pid: $0.pid, bundleId: $0.bundleId) }
            self.push()
        }
        if !was { refreshSoon(delay: 0.2) }
    }

    /// Paused, locked, asleep or switched off: forget every window, now.
    func reset() {
        lock.lock()
        generation += 1
        switchGeneration += 1
        focus = nil
        lastRefresh = .distantPast
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.store.clear()
            self.lastFocused = nil
            self.expiryTimer?.cancel()
            self.expiryTimer = nil
            self.push()
        }
    }

    /// Every snapshot (AX thread): another window or app → refresh soon; typing → a refresh
    /// once it pauses, at most every 20 s.
    func note(pid: pid_t, windowTitle: String, windowFrame: CGRect?) {
        lock.lock()
        guard _enabled else { lock.unlock(); return }
        let frame = windowFrame.map { $0.integral }
        let switched = focus.map { $0.pid != pid || $0.title != windowTitle || $0.frame != frame } ?? true
        focus = (pid, windowTitle, frame)
        generation += 1
        let gen = generation
        if switched { switchGeneration += 1 }
        let sgen = switchGeneration
        let due = switched || Date().timeIntervalSince(lastRefresh) > minInterval
        lock.unlock()
        guard due else { return }
        queue.asyncAfter(deadline: .now() + (switched ? switchDelay : pauseDelay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // A switch waits only for the next switch; a pause refresh for no keystroke since.
            let go = self._enabled && (switched ? sgen == self.switchGeneration : gen == self.generation)
            if go { self.lastRefresh = Date() }
            self.lock.unlock()
            if go { self.refresh() }
        }
    }

    private func refreshSoon(delay: Double) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.enabled else { return }
            self.lock.lock(); self.lastRefresh = Date(); self.lock.unlock()
            self.refresh()
        }
    }

    // MARK: - Reading (pool queue)

    private struct CGWindow {
        var number: CGWindowID
        var pid: pid_t
        var bounds: CGRect
        var sharingNone: Bool
        var visible: Bool
    }

    private func refresh() {
        lock.lock()
        let gate = _gate, allowOCR = _allowOCR, noted = focus?.pid
        lock.unlock()
        let focusPid = noted ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // A password or other secure field is focused somewhere: read nothing now.
        guard !IsSecureEventInputEnabled() else { return Log.debug("context: secure input on, not read") }
        let t0 = Date()
        let windows = ContextPool.windowsOnScreen()
        let displays = displayBounds()
        // The window being typed in is the prompt's own; it is never part of the pool. An app
        // the gate rejects isn't asked even for that (its windows are never read anyway).
        let focusBundle = NSRunningApplication(processIdentifier: focusPid)?.bundleIdentifier ?? ""
        var focusedWindow: AXUIElement?
        if focusPid > 0, gate.allows(pid: focusPid, bundleId: focusBundle) {
            let focusApp = AXUIElementCreateApplication(focusPid)
            AXUIElementSetMessagingTimeout(focusApp, 0.05)
            focusedWindow = AX.element(AX.copy(focusApp, kAXFocusedWindowAttribute))
        }
        let focusedFrame = focusedWindow.flatMap { AX.frame($0) }
        let focusedNumber = windows.first { $0.pid == focusPid && focusedFrame.map(ContextPool.same($0.bounds)) == true }?.number
        var read: [Entry] = []
        var readKeys: Set<String> = []
        var ocrCandidates: [(Entry, CGWindow)] = []
        var byPid: [pid_t: [CGWindow]] = [:]
        var pidOrder: [pid_t] = []
        for w in windows where w.visible && w.number != focusedNumber {
            if byPid[w.pid] == nil { pidOrder.append(w.pid) }
            byPid[w.pid, default: []].append(w)
        }
        for pid in pidOrder {
            guard read.count + ocrCandidates.count < ContextPool.maxWindows,
                  let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier,
                  gate.allows(pid: pid, bundleId: bundle) else { continue }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.05)
            let deadline = CFAbsoluteTimeGetCurrent() + ContextPool.appBudget
            let axWindows = ((AX.copy(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, AX.frame($0)) }
            for cg in byPid[pid] ?? [] {
                guard CFAbsoluteTimeGetCurrent() < deadline, read.count + ocrCandidates.count < ContextPool.maxWindows else { break }
                guard let ax = axWindows.first(where: { $0.1.map(ContextPool.same(cg.bounds)) == true })?.0 else { continue }
                let title = AX.string(ax, kAXTitleAttribute) ?? ""
                guard Gate.allowsWindow(title: title, sharingNone: cg.sharingNone) else { continue }
                var e = Entry(key: "\(pid):\(cg.number)", pid: pid, app: app.localizedName ?? bundle, bundleId: bundle, title: title, text: "",
                              visible: true, display: ScreenGeometry.displayIndex(for: cg.bounds, in: displays) ?? 0)
                if let t = ContextPool.windowText(ax, deadline: deadline) {
                    e.text = t.text
                    e.urlHost = t.host
                }
                if e.text.count < 200, allowOCR {
                    ocrCandidates.append((e, cg))
                } else if !e.text.isEmpty {
                    read.append(e)
                }
                readKeys.insert(e.key)
            }
        }
        // The window focus just left, covered or not. The focused one leaves the pool: its text
        // is the field's (and the screen context's) now.
        let focusedKey = focusedNumber.map { "\(focusPid):\($0)" }
        if let focusedKey { store.removeAll { $0.key == focusedKey } }
        if let last = lastFocused, last.key != focusedKey, !readKeys.contains(last.key),
           let app = NSRunningApplication(processIdentifier: last.pid), let bundle = app.bundleIdentifier,
           gate.allows(pid: last.pid, bundleId: bundle) {
            let title = AX.string(last.window, kAXTitleAttribute) ?? ""
            let cg = windows.first { "\($0.pid):\($0.number)" == last.key }
            if Gate.allowsWindow(title: title, sharingNone: cg?.sharingNone ?? false),
               let t = ContextPool.windowText(last.window, deadline: CFAbsoluteTimeGetCurrent() + ContextPool.appBudget), !t.text.isEmpty {
                let frame = cg?.bounds ?? AX.frame(last.window) ?? .zero
                read.append(Entry(key: last.key, pid: last.pid, app: app.localizedName ?? bundle, bundleId: bundle, title: title, urlHost: t.host,
                                  text: t.text, visible: cg?.visible ?? false,
                                  display: ScreenGeometry.displayIndex(for: frame, in: displays) ?? 0))
                readKeys.insert(last.key)
            }
        }
        lastFocused = focusedWindow.flatMap { w in focusedKey.map { ($0, focusPid, w) } }
        let axCount = read.count
        read += ocr(ocrCandidates)
        // Windows read before and still on screen but not read this time (an app over its
        // time budget) keep their text; merge marks every other window as no longer visible.
        store.merge(read, now: Date())
        Log.debug(String(format: "context: %d windows read (%d by Accessibility, %d by OCR) in %.0f ms; pool %d, %d on screen",
                         read.count, axCount, read.count - axCount, Date().timeIntervalSince(t0) * 1000,
                         store.entries.count, store.entries.values.filter(\.visible).count))
        push()
        scheduleExpiry()
    }

    /// OCR for windows Accessibility gave (almost) nothing for, at most 3 per refresh; an
    /// unchanged picture keeps the text read before.
    private func ocr(_ candidates: [(Entry, CGWindow)]) -> [Entry] {
        guard !candidates.isEmpty else { return [] }
        let done = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in
            content = c
            done.signal()
        }
        guard done.wait(timeout: .now() + 1) == .success, let content else { return [] }
        var out: [Entry] = []
        for (entry, cg) in candidates.prefix(3) {
            guard let window = content.windows.first(where: { $0.windowID == cg.number }),
                  let shot = WindowCapture.image(of: window, rect: window.frame, displays: content.displays) else { continue }
            var e = entry
            let hash = ContextPool.imageHash(shot.image)
            if let old = store.entries[e.key], old.imageHash == hash, old.ocr {
                e.text = old.text
            } else {
                e.text = ContextPool.recognizeFast(shot.image)
            }
            e.ocr = true
            e.imageHash = hash
            if !e.text.isEmpty { out.append(e) }
        }
        return out
    }

    private func push() {
        let sig = store.signature
        guard sig != pushed else { return }
        pushed = sig
        let json = store.json()
        lock.lock(); lastJSON = json; lock.unlock()
        onChange?(json)
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        expiryTimer = nil
        guard let next = store.nextExpiry else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(1, next.timeIntervalSinceNow + 0.5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.store.expire(now: Date()) { self.push() }
            self.scheduleExpiry()
        }
        t.resume()
        expiryTimer = t
    }

    // MARK: - Windows and their text

    /// Layer-0 windows on screen (every display's current Space), front to back, with
    /// whether a quarter of each is not covered by the windows in front of it.
    private static func windowsOnScreen() -> [CGWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [CGWindow] = []
        var inFront: [CGRect] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let number = w[kCGWindowNumber as String] as? CGWindowID, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b),
                  bounds.width > 80, bounds.height > 60 else { continue }
            let sharingNone = (w[kCGWindowSharingState as String] as? Int) == 0
            out.append(CGWindow(number: number, pid: pid, bounds: bounds, sharingNone: sharingNone,
                                visible: uncovered(bounds, by: inFront) >= 0.25))
            inFront.append(bounds)
        }
        return out
    }

    /// Share of `rect` not under any of `front`, sampled on an 8×8 grid.
    static func uncovered(_ rect: CGRect, by front: [CGRect]) -> Double {
        var free = 0
        for i in 0..<8 {
            for j in 0..<8 {
                let p = CGPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / 8, y: rect.minY + rect.height * (CGFloat(j) + 0.5) / 8)
                if !front.contains(where: { $0.contains(p) }) { free += 1 }
            }
        }
        return Double(free) / 64
    }

    private static func same(_ a: CGRect) -> (CGRect) -> Bool {
        { b in abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2 }
    }

    /// A window's text through Accessibility: a web page (through text markers, the part on
    /// screen if the browser says where), else the largest text area (its visible part and
    /// some around it), else its static texts and fields in order. Secure fields are never
    /// read. Breadth-first, at most 300 elements, until `deadline`.
    static func windowText(_ window: AXUIElement, deadline: CFAbsoluteTime) -> (text: String, host: String)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var web: AXUIElement?
        var area: (el: AXUIElement, count: Int)?
        var statics: [String] = []
        var staticChars = 0
        let skip: Set<String> = ["AXButton", "AXMenuBar", "AXMenuButton", "AXPopUpButton", "AXScrollBar", "AXSlider",
                                 "AXCheckBox", "AXRadioButton", "AXToolbar", "AXImage", "AXDisclosureTriangle", "AXIncrementor"]
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute] as CFArray
        while !queue.isEmpty, visited < 300, CFAbsoluteTimeGetCurrent() < deadline {
            let (el, depth) = queue.removeFirst()
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [Any], v.count == 3 else { continue }
            let role = v[0] as? String ?? ""
            let subrole = v[1] as? String ?? ""
            if subrole == "AXSecureTextField" || skip.contains(role) { continue }
            switch role {
            case "AXWebArea":
                if web == nil { web = el }
                continue
            case "AXTextArea":
                let n = (AX.copy(el, kAXNumberOfCharactersAttribute) as? Int) ?? 0
                if n > (area?.count ?? 0) { area = (el, n) }
                continue
            case "AXStaticText", "AXTextField":
                if staticChars < maxChars, let s = AX.copy(el, kAXValueAttribute) as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { statics.append(t); staticChars += t.count + 1 }
                }
                continue
            default:
                break
            }
            if depth < 14, let children = v[2] as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        if let web, let t = webText(web), t.count >= 40 {
            let host = (AX.copy(web, "AXURL") as? URL)?.host ?? ""
            return (t, host)
        }
        if let area, area.count >= 40, let t = areaText(area.el, count: area.count) { return (t, "") }
        let joined = statics.joined(separator: "\n")
        return joined.count >= 40 ? (String(joined.prefix(maxChars)), "") : nil
    }

    /// The visible part of a text area, widened to `minVisibleChars` around it.
    private static func areaText(_ el: AXUIElement, count: Int) -> String? {
        if let vis = AX.range(AX.copy(el, "AXVisibleCharacterRange")), vis.length > 0 {
            let extra = max(0, minVisibleChars - vis.length)
            let start = max(0, vis.location - extra / 2)
            let length = min(maxChars, count - start, vis.length + extra)
            if length > 0, let s = AX.string(el, range: start, length) { return s }
        }
        guard count <= 200_000, let v = AX.copy(el, kAXValueAttribute) as? String else { return nil }
        return String(v.prefix(maxChars))
    }

    /// A web page's text on screen (from the markers at its visible corners), else from the top.
    private static func webText(_ el: AXUIElement) -> String? {
        func text(_ a: CFTypeRef, _ b: CFTypeRef) -> String? {
            guard let r = AX.copyParam(el, "AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) else { return nil }
            return AX.copyParam(el, "AXStringForTextMarkerRange", r) as? String
        }
        if let f = AX.frame(el), f.width > 20, f.height > 20 {
            var top = CGPoint(x: f.minX + 4, y: f.minY + 4), bottom = CGPoint(x: f.maxX - 4, y: f.maxY - 4)
            if let a = AXValueCreate(.cgPoint, &top), let b = AXValueCreate(.cgPoint, &bottom),
               let ma = AX.copyParam(el, "AXTextMarkerForPosition", a), let mb = AX.copyParam(el, "AXTextMarkerForPosition", b),
               let s = text(ma, mb), s.count >= 200 {
                return String(s.prefix(maxChars))
            }
        }
        guard let all = AX.copyParam(el, "AXTextMarkerRangeForUIElement", el),
              let start = AX.copyParam(el, "AXStartTextMarkerForTextMarkerRange", all),
              let end = AX.copyParam(el, "AXEndTextMarkerForTextMarkerRange", all), let s = text(start, end) else { return nil }
        return String(s.prefix(maxChars))
    }

    /// Vision's fast level for windows in the background (D42 Phase B): lines top to bottom.
    static func recognizeFast(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { obs -> (String, CGRect)? in
            guard let c = obs.topCandidates(1).first, c.confidence > 0.3 else { return nil }
            return (c.string, obs.boundingBox)
        }
        let size = CGSize(width: image.width, height: image.height)
        let rows = ScreenContextProvider.assemble(lines.map { ($0.0, CGRect(x: $0.1.minX * size.width, y: (1 - $0.1.maxY) * size.height,
                                                                             width: $0.1.width * size.width, height: $0.1.height * size.height)) },
                                                  field: nil, budget: maxChars)
        return rows
    }

    /// FNV-1a over a 64×64 grayscale thumbnail: equal for an unchanged window (a few
    /// changed words still change some of its pixels; a false change only costs an OCR run).
    static func imageHash(_ image: CGImage) -> UInt64 {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in pixels {
            h = (h ^ UInt64(p)) &* 0x100_0000_01b3
        }
        return h
    }

    // MARK: - Self-test

    /// `Foretype --context-selftest`: the pool's rules (expiry, gates, what is sent and when)
    /// on made-up windows. Needs no permissions.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            if !cond { ok = false; print("FAILED: \(what)") }
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ key: String, _ text: String, visible: Bool = true) -> Entry {
            Entry(key: key, app: "TextEdit", bundleId: "com.apple.TextEdit", title: "notes.txt", text: text, visible: visible)
        }
        var s = Store()
        s.merge([entry("1:10", "Q3 budget"), entry("1:11", "Launch plan")], now: t0)
        let sig = s.signature
        check(s.ordered.allSatisfy(\.visible), "both on screen")
        // Read again unchanged a minute later: nothing to send.
        s.merge([entry("1:10", "Q3 budget"), entry("1:11", "Launch plan")], now: t0.addingTimeInterval(60))
        check(s.signature == sig, "an unchanged refresh changes nothing")
        // One window goes off screen: still there, not visible, with its last-seen time.
        s.merge([entry("1:10", "Q3 budget")], now: t0.addingTimeInterval(120))
        check(s.signature != sig, "a window leaving the screen is sent")
        check(s.entries["1:11"]?.visible == false && s.entries["1:11"]?.lastSeen == t0.addingTimeInterval(60), "recently viewed keeps its time")
        check(s.ordered.first?.key == "1:10", "windows on screen first")
        // Ten minutes after it was last seen it is gone; the visible one stays.
        check(!s.expire(now: t0.addingTimeInterval(60 + 599)), "kept just under 10 minutes")
        s.merge([entry("1:10", "Q3 budget")], now: t0.addingTimeInterval(60 + 600))
        check(s.entries["1:11"] == nil && s.entries["1:10"] != nil, "expired after 10 minutes")
        // At most 12 windows: the oldest recent ones go first.
        var big = Store()
        big.merge((0..<10).map { entry("2:\($0)", "old \($0)") }, now: t0)
        big.merge((0..<6).map { entry("3:\($0)", "new \($0)") }, now: t0.addingTimeInterval(30))
        check(big.entries.count == Store.maxEntries && big.entries.values.filter(\.visible).count == 6, "capped at 12")
        // The JSON the core reads.
        let json = s.json()
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let first = (obj?["passages"] as? [[String: Any]])?.first
        check(first?["bundle_id"] as? String == "com.apple.TextEdit" && first?["visible"] as? Bool == true
              && first?["text"] as? String == "Q3 budget" && first?["captured_at"] is Double, "JSON shape: \(json)")
        s.clear()
        check(s.json() == #"{"passages":[]}"#, "an empty pool clears the core's")
        // Gates.
        let gate = Gate(ownPid: 42, neverRead: Set(passwordManagers), onlyApps: { _, b in b != "com.blocked" }, excluded: { $0 == "com.off" })
        check(gate.allows(pid: 7, bundleId: "com.apple.TextEdit"), "an ordinary app")
        check(!gate.allows(pid: 42, bundleId: "com.apple.TextEdit"), "Foretype's own windows")
        check(!gate.allows(pid: 7, bundleId: "com.1password.1password"), "password managers")
        check(!gate.allows(pid: 7, bundleId: "com.blocked"), "FORETYPE_ONLY_APPS")
        check(!gate.allows(pid: 7, bundleId: "com.off"), "apps where suggestions are off")
        check(!gate.allows(pid: 7, bundleId: ""), "no bundle ID")
        check(!Gate.allowsWindow(title: "Report", sharingNone: true), "windows that forbid capture")
        check(!Gate.allowsWindow(title: "New Incognito Tab", sharingNone: false), "incognito windows")
        check(!Gate.allowsWindow(title: "Bank \u{2014} Private Browsing", sharingNone: false), "private browsing")
        check(Gate.allowsWindow(title: "Q3 Budget Review.docx", sharingNone: false), "an ordinary window")
        // Covered windows.
        let back = CGRect(x: 0, y: 0, width: 400, height: 300)
        check(uncovered(back, by: []) == 1, "nothing in front")
        check(uncovered(back, by: [CGRect(x: -10, y: -10, width: 500, height: 400)]) == 0, "fully covered")
        check(abs(uncovered(back, by: [CGRect(x: 0, y: 0, width: 200, height: 300)]) - 0.5) < 0.01, "half covered")
        // OCR of a background window (Vision's fast level) and the unchanged-window hash.
        func render(_ lines: [String]) -> CGImage? {
            let size = CGSize(width: 640, height: 200)
            let image = NSImage(size: size, flipped: true) { _ in
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
                for (i, line) in lines.enumerated() { (line as NSString).draw(at: NSPoint(x: 20, y: 30 + CGFloat(i) * 50), withAttributes: attrs) }
                return true
            }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let a = render(["The morning ferry leaves pier 9 at 07:45.", "Tickets cost 35 dollars."]),
           let b = render(["The evening ferry leaves pier 4 at 19:10.", "Tickets cost 50 dollars."]) {
            let text = recognizeFast(a)
            check(text.contains("ferry") && text.contains("07:45") && text.components(separatedBy: "\n").count == 2, "fast OCR: \(text)")
            check(imageHash(a) == imageHash(render(["The morning ferry leaves pier 9 at 07:45.", "Tickets cost 35 dollars."])!), "same picture, same hash")
            check(imageHash(a) != imageHash(b), "another picture, another hash")
        } else {
            check(false, "rendering the OCR sample")
        }
        print(ok ? "context self-test passed" : "context self-test FAILED")
        return ok
    }
}
