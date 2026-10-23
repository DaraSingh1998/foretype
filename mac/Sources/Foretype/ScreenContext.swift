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
            // The scale of the display the window is on. SCWindow.frame is in global
            // coordinates (top-left origin), so it can't be matched against NSScreen frames.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale)
                : ScreenGeometry.scale(for: window.frame, in: ScreenGeometry.displays()) ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let t0 = Date()
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                guard let image else {
                    Log.debug("screen: capture failed: \(error?.localizedDescription ?? "?")")
                    return
                }
                self.queue.async {
                    let field = target.fieldFrame.map { $0.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY) }
                    let text = ScreenContextProvider.recognize(image, windowSize: window.frame.size, field: field)
                    self.lock.lock()
                    self.texts[target.fieldKey] = text
                    if self.texts.count > 32 { self.texts.removeValue(forKey: self.texts.keys.first!) }
                    self.lock.unlock()
                    Log.debug(String(format: "screen: %d chars from %@ in %.0f ms (%dx%d px, %.0fx; window %.0f,%.0f %.0fx%.0f of %d)",
                                     text.count, window.owningApplication?.applicationName ?? "?", Date().timeIntervalSince(t0) * 1000,
                                     image.width, image.height, scale, window.frame.minX, window.frame.minY, window.frame.width,
                                     window.frame.height, candidates.count))
                    self.onUpdate?(target.fieldKey, text)
                }
            }
        }
    }

    // MARK: - Recognition

    /// OCR of a window image. `field` (window coordinates, top-left origin) is excluded,
    /// since the field's own text already reaches the prompt as `text_before`.
    static func recognize(_ image: CGImage, windowSize: CGSize, field: CGRect?) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        let lines: [(String, CGRect)] = (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
            let bb = obs.boundingBox
            let rect = CGRect(x: bb.minX * windowSize.width, y: (1 - bb.maxY) * windowSize.height,
                              width: bb.width * windowSize.width, height: bb.height * windowSize.height)
            return (candidate.string, rect)
        }
        return assemble(lines, field: field, budget: budget)
    }

    /// Groups recognized lines into rows, drops anything inside the field, keeps the rows
    /// closest to the field (rows above it first, as in chats and email threads) within the
    /// character budget, and returns them in reading order.
    static func assemble(_ lines: [(String, CGRect)], field: CGRect?, budget: Int) -> String {
        let outside = lines.filter { line in
            guard let field else { return true }
            return !field.insetBy(dx: -4, dy: -4).contains(CGPoint(x: line.1.midX, y: line.1.midY))
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
        print(ok ? "OCR self-test passed" : "OCR self-test FAILED")
        return ok
    }
}
