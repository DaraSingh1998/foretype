import AppKit
import ScreenCaptureKit
import Vision

/// Reads the text visible in the focused window (ScreenCaptureKit window capture plus
/// on-device Vision OCR) and keeps the lines nearest the text field, so suggestions can
/// follow the conversation or document around it. The image is discarded right after
/// recognition; only the text is kept, in memory, per field.
///
/// Refreshes happen off the typing path: once when a new field gets focus, then after a
/// typing pause at most every `minInterval`, because every change to the screen text
/// changes the prompt header and costs a full prefill.
final class ScreenContextProvider {
    struct Target {
        var fieldKey: UInt64
        var pid: pid_t
        var windowFrame: CGRect?
        var fieldFrame: CGRect?
    }

    /// Provider queue: new text for a field.
    var onUpdate: ((UInt64, String) -> Void)?
    var enabled = true

    private let queue = DispatchQueue(label: "foretype.screen", qos: .utility)
    private let lock = NSLock()
    private var texts: [UInt64: String] = [:]
    private var lastRefresh: [UInt64: Date] = [:]
    private var generation = 0
    private let pauseDelay = 1.5
    private let minInterval: TimeInterval = 15
    /// After a sent message, long enough for the chat to show it.
    private let sentDelay = 1.0
    private static let budget = 1400

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func text(for fieldKey: UInt64) -> String {
        lock.lock(); defer { lock.unlock() }
        return texts[fieldKey] ?? ""
    }

    /// Called for every field snapshot (AX thread).
    func note(_ target: Target, skip: Bool) {
        guard enabled, !skip, target.fieldKey != 0, ScreenContextProvider.hasPermission else { return }
        lock.lock()
        generation += 1
        let gen = generation
        let last = lastRefresh[target.fieldKey]
        let isNew = last == nil
        let due = isNew || Date().timeIntervalSince(last!) > minInterval
        if isNew { lastRefresh[target.fieldKey] = Date() }
        lock.unlock()
        guard due else { return }
        queue.asyncAfter(deadline: .now() + (isNew ? 0.05 : pauseDelay)) { [weak self] in
            guard let self, self.enabled else { return }
            self.lock.lock()
            // A pause refresh only runs if no keystroke arrived since it was scheduled.
            let stillPaused = isNew || gen == self.generation
            if stillPaused { self.lastRefresh[target.fieldKey] = Date() }
            self.lock.unlock()
            if stillPaused { self.capture(target) }
        }
    }

    /// The field's text was just cleared (a chat message sent): read the window again in a
    /// moment, when the message shows in the conversation, whatever the interval.
    func noteSent(_ target: Target, skip: Bool) {
        guard enabled, !skip, target.fieldKey != 0, ScreenContextProvider.hasPermission else { return }
        lock.lock()
        lastRefresh[target.fieldKey] = Date()
        lock.unlock()
        queue.asyncAfter(deadline: .now() + sentDelay) { [weak self] in
            guard let self, self.enabled else { return }
            self.capture(target)
        }
    }

    /// Paused: forget every field's text and drop refreshes not yet started.
    func reset() {
        lock.lock()
        generation += 1
        texts.removeAll()
        lastRefresh.removeAll()
        lock.unlock()
    }

    private func capture(_ target: Target) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self, let content else {
                Log.debug("screen: shareable content unavailable: \(error?.localizedDescription ?? "?")")
                return
            }
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == target.pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
            }
            // The window holding the field, as the window frame can be from before a move.
            guard let i = ScreenGeometry.windowIndex(field: target.fieldFrame, window: target.windowFrame,
                                                     in: candidates.map(\.frame)) else {
                Log.debug("screen: none of \(candidates.count) windows holds the field; not captured")
                return
            }
            let window = candidates[i]
            let displays = content.displays
            self.queue.async {
                let t0 = Date()
                // A full-screen window is captured through its display (WindowCapture), at the
                // scale of the display it is on.
                guard let shot = WindowCapture.image(of: window, rect: window.frame, displays: displays) else {
                    Log.debug("screen: capture failed")
                    return
                }
                // The shot can be clipped to its display, so measure from what it covers.
                let size = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
                let field = target.fieldFrame.map { $0.offsetBy(dx: -shot.origin.x, dy: -shot.origin.y) }
                let text = ScreenContextProvider.recognize(shot.image, windowSize: size, field: field)
                self.lock.lock()
                self.texts[target.fieldKey] = text
                if self.texts.count > 32 { self.texts.removeValue(forKey: self.texts.keys.first!) }
                self.lock.unlock()
                Log.debug(String(format: "screen: %d chars from %@ in %.0f ms (%dx%d px, %.0fx; window %.0f,%.0f %.0fx%.0f of %d)",
                                 text.count, window.owningApplication?.applicationName ?? "?", Date().timeIntervalSince(t0) * 1000,
                                 shot.image.width, shot.image.height, shot.scale, window.frame.minX, window.frame.minY,
                                 window.frame.width, window.frame.height, candidates.count))
                self.onUpdate?(target.fieldKey, text)
            }
        }
    }

    // MARK: - Recognition

    /// Set once a recognition finished: the first one on a Mac can take about 30 s while
    /// Vision compiles its models, later ones take under a second.
    private static var warmedUp = false

    /// Runs a Vision request with a deadline (60 s until one has finished, then 8 s): a
    /// request can hang on some images, and the queue it blocks would read no screen again.
    /// Past the deadline the request is cancelled and its text given up. Any queue.
    static func perform(_ request: VNRequest, on image: CGImage) -> Bool {
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.ok = (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil
            done.signal()
        }
        let timeout: TimeInterval = warmedUp ? 8 : 60
        guard done.wait(timeout: .now() + timeout) == .success else {
            request.cancel()
            Log.debug("ocr: gave up after \(Int(timeout)) s")
            return false
        }
        warmedUp = true
        return box.ok
    }

    /// OCR of a window image. `field` (window coordinates, top-left origin) is excluded,
    /// since the field's own text already reaches the prompt as `text_before`.
    static func recognize(_ image: CGImage, windowSize: CGSize, field: CGRect?) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard perform(request, on: image) else { return "" }
        let lines: [(String, CGRect)] = (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
            let bb = obs.boundingBox
            let rect = CGRect(x: bb.minX * windowSize.width, y: (1 - bb.maxY) * windowSize.height,
                              width: bb.width * windowSize.width, height: bb.height * windowSize.height)
            return (candidate.string, rect)
        }
        return assemble(lines, field: field, budget: budget)
    }

    /// Groups recognized lines into rows, drops anything inside the field and, when enough
    /// is left, anything mostly outside the field's column (a sidebar's channel and contact
    /// names would otherwise join the conversation's rows), keeps the rows closest to the
    /// field (rows above it first, as in chats and email threads) within the character budget,
    /// and returns them in reading order.
    static func assemble(_ lines: [(String, CGRect)], field: CGRect?, budget: Int) -> String {
        var outside = lines.filter { line in
            guard let field else { return true }
            return !field.insetBy(dx: -4, dy: -4).contains(CGPoint(x: line.1.midX, y: line.1.midY))
        }
        if let field {
            let column = field.insetBy(dx: -24, dy: 0)
            let inColumn = outside.filter { line in
                let overlap = max(0, min(line.1.maxX, column.maxX) - max(line.1.minX, column.minX))
                return overlap >= line.1.width / 2
            }
            if inColumn.reduce(0, { $0 + $1.0.count }) >= 40 { outside = inColumn }
        }
        var rows: [(text: String, rect: CGRect)] = []
        for line in outside.sorted(by: { $0.1.midY < $1.1.midY }) {
            if let i = rows.indices.last, abs(rows[i].rect.midY - line.1.midY) < min(rows[i].rect.height, line.1.height) * 0.5 {
                let leftFirst = line.1.minX >= rows[i].rect.minX
                rows[i].text = leftFirst ? rows[i].text + "  " + line.0 : line.0 + "  " + rows[i].text
                rows[i].rect = rows[i].rect.union(line.1)
            } else {
                rows.append((line.0, line.1))
            }
        }
        func distance(_ r: CGRect) -> CGFloat {
            guard let field else { return 0 }
            if r.maxY <= field.minY { return field.minY - r.maxY }
            if r.minY >= field.maxY { return (r.minY - field.maxY) * 2 }
            return 0
        }
        var chosen: [Int] = []
        var total = 0
        for i in rows.indices.sorted(by: { distance(rows[$0].rect) < distance(rows[$1].rect) }) {
            let n = rows[i].text.count + 1
            if total + n > budget { continue }
            total += n
            chosen.append(i)
        }
        return chosen.sorted().map { rows[$0].text }.joined(separator: "\n")
    }

    /// `Foretype --ocr-selftest`: renders a fake chat window and runs the recognition and
    /// row-assembly path on it. Needs no permissions, so it can run anywhere.
    static func selfTest() -> Bool {
        let size = CGSize(width: 720, height: 420)
        let chat = [
            "Priya: Morning! Did you get a chance to read the planning notes?",
            "Sam: Yes, twice. I think we are closer to agreement than it felt.",
            "Priya: Great. Can you send the timeline before Thursday's review?",
        ]
        let draft = "Sure, I will send the timeline by"
        let field = CGRect(x: 20, y: 340, width: 680, height: 50)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
            for (i, line) in chat.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 24, y: 40 + CGFloat(i) * 70), withAttributes: attrs)
            }
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
            (draft as NSString).draw(at: NSPoint(x: 32, y: 355), withAttributes: attrs)
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let t0 = Date()
        let text = recognize(cg, windowSize: size, field: field)
        print("recognized in \(Int(Date().timeIntervalSince(t0) * 1000)) ms:\n\(text)")
        let ok = text.contains("planning notes") && text.contains("Thursday") && !text.contains("send the timeline by")
            && text.components(separatedBy: "\n").count == 3
        // A sidebar left of the conversation: its names stay out of the rows.
        let sidebar: [(String, CGRect)] = [
            ("# general", CGRect(x: 10, y: 40, width: 120, height: 18)),
            ("Priya Raman", CGRect(x: 10, y: 110, width: 120, height: 18)),
            ("Priya: Can you send the timeline before Thursday?", CGRect(x: 220, y: 40, width: 400, height: 18)),
            ("Sam: Sure, by Wednesday evening at the latest.", CGRect(x: 220, y: 110, width: 380, height: 18)),
        ]
        let column = assemble(sidebar, field: CGRect(x: 210, y: 300, width: 500, height: 50), budget: budget)
        let columnOK = column == "Priya: Can you send the timeline before Thursday?\nSam: Sure, by Wednesday evening at the latest."
        if !columnOK { print("column FAILED:\n\(column)") }
        print(ok && columnOK ? "OCR self-test passed" : "OCR self-test FAILED")
        return ok && columnOK
    }
}
