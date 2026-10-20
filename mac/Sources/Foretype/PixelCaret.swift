import AppKit
import ScreenCaptureKit

// Pixel caret locator: finds the text caret on screen from pixels, for apps whose
// Accessibility API gives no usable caret geometry (Teams, LibreOffice; see D24).
//
// Two detectors share one bar finder:
// - blink: several captures of the same region over up to ~1.3 s; only the caret toggles,
//   so the pixels whose colour changed form a thin, isolated vertical bar. Run when the
//   user pauses; it also learns how the caret looks (colour, width, height).
// - static: one capture near a predicted position; finds a bar of the learned colour and
//   height there. Run after a short typing pause, when the caret is solid (every toolkit
//   restarts the blink on input), to correct the estimate.
// Between captures the estimate is advanced by the rendered width of the text typed on
// the same line, so nothing is captured per keystroke. Images are converted to bytes,
// searched and dropped; nothing is kept or logged except the found rectangle.

/// A captured region as RGBX bytes, row 0 at the top.
struct PixelFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    /// Global (AX, top-left origin) position of pixel (0, 0) in points.
    let origin: CGPoint
    /// Pixels per point.
    let scale: CGFloat

    init(width: Int, height: Int, bytes: [UInt8], origin: CGPoint, scale: CGFloat) {
        self.width = width
        self.height = height
        self.bytes = bytes
        self.origin = origin
        self.scale = scale
    }

    init?(image: CGImage, origin: CGPoint, scale: CGFloat) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, bytes: buf, origin: origin, scale: scale)
    }

    func rgb(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    /// Pixel coordinates of a global point.
    func pixel(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * scale, y: (p.y - origin.y) * scale)
    }

    /// Global rectangle of a pixel box (inclusive bounds).
    func global(x0: CGFloat, x1: CGFloat, y0: Int, y1: Int) -> CGRect {
        CGRect(x: origin.x + x0 / scale, y: origin.y + CGFloat(y0) / scale,
               width: (x1 - x0) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }
}

struct RGB: Equatable {
    var r: Int, g: Int, b: Int
    /// Largest channel difference.
    func distance(_ o: RGB) -> Int { max(abs(r - o.r), abs(g - o.g), abs(b - o.b)) }
}

/// How the caret of one field looks, learned from a blink detection. Sizes in points.
struct CaretLook: Equatable {
    var color: RGB
    var background: RGB
    var width: CGFloat
    var height: CGFloat
}

/// A thin vertical bar in a frame, in pixels (inclusive bounds).
struct CaretBar {
    var x0: Int, x1: Int, y0: Int, y1: Int
    /// Intensity-weighted centre column (sub-pixel).
    var centerX: CGFloat = 0
    var width: Int { x1 - x0 + 1 }
    var height: Int { y1 - y0 + 1 }
}

/// A located caret: `rect` is zero-width at the insertion point (the bar's centre), in
/// global AX coordinates, like `CaretResolver`'s rectangles.
struct PixelCaretHit {
    var rect: CGRect
    var look: CaretLook
    var frames: Int
    var ms: Double
}

enum PixelCaret {
    // MARK: - Bar finder

    /// Thin vertical bars of set pixels: column runs (gaps of 1 px bridged) of `minH...maxH`
    /// rows, merged across adjacent columns that overlap, at most `maxW` columns wide.
    static func bars(mask: [UInt8], width w: Int, height h: Int, minH: Int, maxH: Int, maxW: Int) -> [CaretBar] {
        var open: [CaretBar] = []
        var done: [CaretBar] = []
        mask.withUnsafeBufferPointer { m in
            for x in 0..<w {
                var runs: [(Int, Int)] = []
                var y = 0
                while y < h {
                    guard m[y * w + x] != 0 else { y += 1; continue }
                    var y1 = y, yy = y + 1, gap = 0
                    while yy < h {
                        if m[yy * w + x] != 0 { y1 = yy; gap = 0 } else { gap += 1; if gap > 1 { break } }
                        yy += 1
                    }
                    let len = y1 - y + 1
                    if len >= minH { runs.append((y, y1)) }
                    y = y1 + 1
                }
                var next: [CaretBar] = []
                var used = [Bool](repeating: false, count: runs.count)
                for var bar in open {
                    let i = bar.x1 == x - 1 ? runs.indices.first { i in
                        !used[i] && min(bar.y1, runs[i].1) - max(bar.y0, runs[i].0) + 1
                            >= Int(Double(min(bar.height, runs[i].1 - runs[i].0 + 1)) * 0.6)
                    } : nil
                    if let i {
                        used[i] = true
                        bar.x1 = x
                        bar.y0 = min(bar.y0, runs[i].0)
                        bar.y1 = max(bar.y1, runs[i].1)
                        next.append(bar)
                    } else {
                        done.append(bar)
                    }
                }
                for i in runs.indices where !used[i] {
                    next.append(CaretBar(x0: x, x1: x, y0: runs[i].0, y1: runs[i].1))
                }
                open = next
            }
        }
        done += open
        return done.filter { $0.width <= maxW && $0.height <= maxH }
    }

    /// Fraction of set pixels in `cols` columns starting `gap` columns beside the bar.
    static func sideFill(_ bar: CaretBar, mask: [UInt8], width w: Int, gap: Int, cols: Int, left: Bool) -> Double {
        var on = 0, total = 0
        for k in 0..<cols {
            let x = left ? bar.x0 - gap - k : bar.x1 + gap + k
            guard x >= 0, x < w else { continue }
            for y in bar.y0...bar.y1 {
                total += 1
                if mask[y * w + x] != 0 { on += 1 }
            }
        }
        return total == 0 ? 0 : Double(on) / Double(total)
    }

    static func fill(_ bar: CaretBar, mask: [UInt8], width w: Int) -> Double {
        var on = 0
        for y in bar.y0...bar.y1 { for x in bar.x0...bar.x1 where mask[y * w + x] != 0 { on += 1 } }
        return Double(on) / Double(bar.width * bar.height)
    }

    /// Set pixels around the bar (±`dx` columns, ±half its height) outside the bar itself.
    static func clutter(_ bar: CaretBar, mask: [UInt8], width w: Int, height h: Int, dx: Int) -> Int {
        let ya = max(0, bar.y0 - bar.height / 2), yb = min(h - 1, bar.y1 + bar.height / 2)
        let xa = max(0, bar.x0 - dx), xb = min(w - 1, bar.x1 + dx)
        var n = 0
        for y in ya...yb {
            for x in xa...xb where mask[y * w + x] != 0 {
                if !(x >= bar.x0 && x <= bar.x1 && y >= bar.y0 && y <= bar.y1) { n += 1 }
            }
        }
        return n
    }

    /// Intensity-weighted centre column over the bar and one column either side. Each
    /// column counts with its median strength: a caret's partly covered edge column is
    /// uniform along its height, while a neighbouring glyph's ink covers only some rows.
    static func centroid(_ bar: CaretBar, strength: [UInt8], width w: Int) -> CGFloat {
        var sum = 0.0, weighted = 0.0
        for x in max(0, bar.x0 - 1)...min(w - 1, bar.x1 + 1) {
            let column = (bar.y0...bar.y1).map { strength[$0 * w + x] }.sorted()
            let col = Double(column[column.count / 2])
            sum += col
            weighted += col * (Double(x) + 0.5)
        }
        return sum > 0 ? CGFloat(weighted / sum) : CGFloat(bar.x0 + bar.x1 + 1) / 2
    }

    // MARK: - Blink detector

    /// Per-pixel colour range over several frames of one region.
    struct BlinkAccumulator {
        let width: Int
        let height: Int
        let origin: CGPoint
        let scale: CGFloat
        private(set) var lo: [UInt8]
        private(set) var hi: [UInt8]
        private(set) var count = 1

        init(_ f: PixelFrame) {
            width = f.width; height = f.height; origin = f.origin; scale = f.scale
            lo = f.bytes; hi = f.bytes
        }

        mutating func add(_ f: PixelFrame) -> Bool {
            guard f.width == width, f.height == height else { return false }
            let n = lo.count
            lo.withUnsafeMutableBufferPointer { l in
                hi.withUnsafeMutableBufferPointer { u in
                    f.bytes.withUnsafeBufferPointer { b in
                        for i in 0..<n {
                            let v = b[i]
                            if v < l[i] { l[i] = v } else if v > u[i] { u[i] = v }
                        }
                    }
                }
            }
            count += 1
            return true
        }

        /// The toggling bar, if exactly one plausible one changed. `hint` (global) breaks ties.
        func bar(hint: CGPoint?, minHeight: CGFloat = 6, maxHeight: CGFloat = 90) -> (CaretBar, CaretLook)? {
            guard count >= 2 else { return nil }
            let n = width * height
            var strength = [UInt8](repeating: 0, count: n)
            var mask = [UInt8](repeating: 0, count: n)
            lo.withUnsafeBufferPointer { l in
                hi.withUnsafeBufferPointer { u in
                    for p in 0..<n {
                        let i = p * 4
                        let d = max(u[i] - l[i], u[i + 1] - l[i + 1], u[i + 2] - l[i + 2])
                        strength[p] = d
                        if d >= 48 { mask[p] = 1 }
                    }
                }
            }
            let maxW = max(3, Int((3.5 * scale).rounded()))
            let candidates = PixelCaret.bars(mask: mask, width: width, height: height,
                                             minH: Int(minHeight * scale), maxH: Int(maxHeight * scale), maxW: maxW)
                .filter { b in
                    b.height >= 3 * b.width
                        && PixelCaret.fill(b, mask: mask, width: width) >= 0.75
                        && PixelCaret.sideFill(b, mask: mask, width: width, gap: 2, cols: 2, left: true) <= 0.2
                        && PixelCaret.sideFill(b, mask: mask, width: width, gap: 2, cols: 2, left: false) <= 0.2
                        // Typing or scrolling during the captures changes glyphs around the bar.
                        && PixelCaret.clutter(b, mask: mask, width: width, height: height, dx: Int(24 * scale)) <= b.width * b.height
                }
            let chosen: CaretBar?
            if let hint {
                let hx = (hint.x - origin.x) * scale, hy = (hint.y - origin.y) * scale
                chosen = candidates.min { a, b in
                    hypot(CGFloat(a.x0) - hx, CGFloat(a.y0 + a.y1) / 2 - hy) < hypot(CGFloat(b.x0) - hx, CGFloat(b.y0 + b.y1) / 2 - hy)
                }
            } else {
                // Without a hint an ambiguous result is no result.
                chosen = candidates.count == 1 ? candidates[0] : nil
            }
            guard var bar = chosen else { return nil }
            bar.centerX = PixelCaret.centroid(bar, strength: strength, width: width)
            return (bar, look(of: bar))
        }

        /// Caret colour: per channel, the extreme farther from the unchanged background beside it.
        private func look(of bar: CaretBar) -> CaretLook {
            func px(_ a: [UInt8], _ x: Int, _ y: Int) -> RGB {
                let i = (y * width + x) * 4
                return RGB(r: Int(a[i]), g: Int(a[i + 1]), b: Int(a[i + 2]))
            }
            let bx = bar.x1 + 3 < width ? bar.x1 + 3 : max(0, bar.x0 - 3)
            let my = (bar.y0 + bar.y1) / 2
            let bg = px(hi, bx, my)
            var colors: [RGB] = []
            for y in bar.y0...bar.y1 {
                for x in bar.x0...bar.x1 {
                    let l = px(lo, x, y), u = px(hi, x, y)
                    colors.append(RGB(r: abs(l.r - bg.r) > abs(u.r - bg.r) ? l.r : u.r,
                                      g: abs(l.g - bg.g) > abs(u.g - bg.g) ? l.g : u.g,
                                      b: abs(l.b - bg.b) > abs(u.b - bg.b) ? l.b : u.b))
                }
            }
            // A caret at a fractional position has blended edge columns; its colour is that
            // of the fully covered pixels, the ones farthest from the background.
            let far = colors.map { $0.distance(bg) }.max() ?? 0
            let core = colors.filter { $0.distance(bg) * 10 >= far * 9 }
            let rs = core.map(\.r), gs = core.map(\.g), bs = core.map(\.b)
            func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
            return CaretLook(color: RGB(r: median(rs), g: median(gs), b: median(bs)), background: bg,
                             width: CGFloat(bar.width) / scale, height: CGFloat(bar.height) / scale)
        }
    }

    // MARK: - Static detector

    /// A bar that looks like `look` within `radius` points of `near` (global), on one frame.
    static func staticBar(_ f: PixelFrame, look: CaretLook, near: CGPoint, radius: CGFloat = .greatestFiniteMagnitude) -> CaretBar? {
        let n = f.width * f.height
        let contrast = max(1, look.color.distance(look.background))
        let tol = max(24, contrast * 35 / 100)
        var strength = [UInt8](repeating: 0, count: n)
        var mask = [UInt8](repeating: 0, count: n)
        f.bytes.withUnsafeBufferPointer { b in
            let c = look.color
            for p in 0..<n {
                let i = p * 4
                let d = max(abs(Int(b[i]) - c.r), abs(Int(b[i + 1]) - c.g), abs(Int(b[i + 2]) - c.b))
                strength[p] = UInt8(max(0, 255 - d * 255 / contrast))
                if d <= tol { mask[p] = 1 }
            }
        }
        let hPx = look.height * f.scale
        let wPx = max(1, Int((look.width * f.scale).rounded()))
        let candidates = bars(mask: mask, width: f.width, height: f.height,
                              minH: Int(hPx * 0.85), maxH: Int((hPx * 1.15).rounded(.up)) + 1, maxW: wPx + 2)
            .filter { b in
                // Glyph stems in the caret's colour are shorter than a line, or sit in ink.
                fill(b, mask: mask, width: f.width) >= 0.75
                    && min(sideFill(b, mask: mask, width: f.width, gap: 1, cols: 2, left: true),
                           sideFill(b, mask: mask, width: f.width, gap: 1, cols: 2, left: false)) <= 0.3
            }
        let p = f.pixel(near)
        guard var best = candidates.filter({ abs(CGFloat($0.x0) - p.x) <= radius * f.scale })
            .min(by: { abs(CGFloat($0.x0) - p.x) < abs(CGFloat($1.x0) - p.x) }) else { return nil }
        best.centerX = centroid(best, strength: strength, width: f.width)
        return best
    }

    // MARK: - Capture

    private static let windowLock = NSLock()
    private static var windowCache: (pid: pid_t, windows: [SCWindow], at: CFAbsoluteTime)?

    /// The app's on-screen windows (cached for 2 s; ScreenCaptureKit's list costs 10–40 ms).
    private static func windows(pid: pid_t, refresh: Bool) -> [SCWindow] {
        windowLock.lock()
        if !refresh, let c = windowCache, c.pid == pid, CFAbsoluteTimeGetCurrent() - c.at < 2 {
            windowLock.unlock()
            return c.windows
        }
        windowLock.unlock()
        let done = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in
            content = c
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success, let content else { return [] }
        let list = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 30
        }
        windowLock.lock()
        windowCache = (pid, list, CFAbsoluteTimeGetCurrent())
        windowLock.unlock()
        return list
    }

    /// Captures `region` (global points) of the app window that contains it. Only that
    /// window is captured, so other windows and Foretype's overlay never appear, and the
    /// pointer is left out. Blocks up to 1.5 s; call off the main thread.
    static func capture(pid: pid_t, windowFrame: CGRect?, region: CGRect) -> PixelFrame? {
        for refresh in [false, true] {
            let list = windows(pid: pid, refresh: refresh)
            let center = CGPoint(x: region.midX, y: region.midY)
            let window = list.filter { $0.frame.contains(center) }.min { a, b in
                guard let wf = windowFrame else { return a.frame.width * a.frame.height < b.frame.width * b.frame.height }
                return abs(a.frame.minX - wf.minX) + abs(a.frame.minY - wf.minY) + abs(a.frame.width - wf.width)
                    < abs(b.frame.minX - wf.minX) + abs(b.frame.minY - wf.minY) + abs(b.frame.width - wf.width)
            }
            guard let window else { continue }
            if let f = capture(window, region: region) { return f }
        }
        return nil
    }

    private static func capture(_ window: SCWindow, region: CGRect) -> PixelFrame? {
        let wf = window.frame
        let clipped = region.intersection(wf)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        // Whole pixels, so the bytes map exactly onto points.
        let local = CGRect(x: floor((clipped.minX - wf.minX) * scale) / scale, y: floor((clipped.minY - wf.minY) * scale) / scale,
                           width: ceil(clipped.width * scale) / scale, height: ceil(clipped.height * scale) / scale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { img, _ in
            image = img
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success, let image else { return nil }
        return PixelFrame(image: image, origin: CGPoint(x: wf.minX + local.minX, y: wf.minY + local.minY),
                          scale: CGFloat(image.width) / local.width)
    }

    // MARK: - Detection runs (blocking; call on a background queue)

    /// Captures `region` every `interval` until the caret blinks or `timeout` passes.
    /// `cancelled` is checked before every capture.
    static func blink(pid: pid_t, windowFrame: CGRect?, region: CGRect, hint: CGPoint?,
                      interval: Double = 0.12, timeout: Double = 1.3, cancelled: () -> Bool = { false }) -> PixelCaretHit? {
        let t0 = CFAbsoluteTimeGetCurrent()
        var acc: BlinkAccumulator?
        while CFAbsoluteTimeGetCurrent() - t0 < timeout {
            if cancelled() { return nil }
            let shot = CFAbsoluteTimeGetCurrent()
            guard let f = capture(pid: pid, windowFrame: windowFrame, region: region) else { return nil }
            if acc == nil {
                acc = BlinkAccumulator(f)
            } else if acc?.add(f) != true {
                return nil
            }
            if let acc, let (bar, look) = acc.bar(hint: hint) {
                let r = PixelFrame(width: acc.width, height: acc.height, bytes: [], origin: acc.origin, scale: acc.scale)
                    .global(x0: bar.centerX, x1: bar.centerX, y0: bar.y0, y1: bar.y1)
                return PixelCaretHit(rect: r, look: look, frames: acc.count, ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let wait = interval - (CFAbsoluteTimeGetCurrent() - shot)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        return nil
    }

    /// A capture around `near` (global), searching `radius` points either side. Typing
    /// normally keeps the caret solid, but not every app restarts the blink on every change
    /// (TextEdit after a programmatic move), so up to `attempts` captures `interval` apart
    /// span one off phase.
    static func verify(pid: pid_t, windowFrame: CGRect?, near: CGPoint, look: CaretLook, radius: CGFloat,
                       attempts: Int = 3, interval: Double = 0.25, cancelled: () -> Bool = { false }) -> PixelCaretHit? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let region = CGRect(x: near.x - radius, y: near.y - look.height * 1.25, width: radius * 2, height: look.height * 2.5)
        for attempt in 1...max(1, attempts) {
            if cancelled() { return nil }
            let shot = CFAbsoluteTimeGetCurrent()
            guard let f = capture(pid: pid, windowFrame: windowFrame, region: region) else { return nil }
            if let bar = staticBar(f, look: look, near: near, radius: radius) {
                let r = f.global(x0: bar.centerX, x1: bar.centerX, y0: bar.y0, y1: bar.y1)
                return PixelCaretHit(rect: r, look: look, frames: attempt, ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let wait = interval - (CFAbsoluteTimeGetCurrent() - shot)
            if attempt < attempts, wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        return nil
    }
}

// MARK: - Per-field tracking

/// Keeps a pixel-located caret per field and refreshes it on typing pauses.
/// `caret(for:)` is cheap (AX thread, every snapshot); captures run on `foretype.caret`.
final class PixelCaretProvider {
    struct Target {
        var fieldKey: UInt64
        var pid: pid_t
        var bundleId: String
        var windowFrame: CGRect?
        var fieldFrame: CGRect?
        /// Index of the caret line's first character, and the line's text before the caret.
        var lineStart: Int
        var lineText: String
        var font: NSFont?
    }

    struct Estimate {
        var x: CGFloat
        var y: CGFloat
        var height: CGFloat
        var lineStart: Int
        var lineText: String
        var look: CaretLook
        /// Observed caret travel divided by the measured text width (font guesses are off).
        var widthScale: CGFloat = 1
        /// The field frame's origin when measured; the estimate moves with the field (a
        /// dragged window).
        var anchor: CGPoint?
    }

    /// Caret queue: a new or corrected estimate for a field.
    var onUpdate: ((UInt64) -> Void)?

    private let queue = DispatchQueue(label: "foretype.caret", qos: .userInitiated)
    private let lock = NSLock()
    private var estimates: [UInt64: Estimate] = [:]
    private var order: [UInt64] = []
    private var generation = 0
    private var lastField: UInt64 = 0
    private var lastBlink: [UInt64: CFAbsoluteTime] = [:]
    /// Apps whose field frame did not contain the caret (LibreOffice): search the window.
    private var searchWindow: Set<String> = []

    private let focusDelay = 0.15
    private let verifyPause = 0.25
    private let blinkPause = 0.5

    /// The current estimate for `t`, advanced by the text typed since it was measured, or
    /// nil (unknown, another line, or wrapped past the field's edge).
    func caret(for t: Target) -> CaretInfo? {
        lock.lock()
        let est = estimates[t.fieldKey]
        lock.unlock()
        guard var est, est.lineStart == t.lineStart else { return nil }
        if let a = est.anchor, let f = t.fieldFrame {
            est.x += f.minX - a.x
            est.y += f.minY - a.y
        }
        let dx = PixelCaretProvider.advance(from: est.lineText, to: t.lineText, font: font(t, est)) * est.widthScale
        let x = est.x + dx
        let field = t.fieldFrame.flatMap { f in f.insetBy(dx: -4, dy: -4).contains(CGPoint(x: est.x, y: est.y + est.height / 2)) ? f : nil }
        let right = (field ?? t.windowFrame)?.maxX ?? .greatestFiniteMagnitude
        let left = (field ?? t.windowFrame)?.minX ?? -.greatestFiniteMagnitude
        guard x < right - 1, x > left else { return nil }
        return CaretInfo(rect: CGRect(x: x, y: est.y, width: 0, height: est.height), strategy: dx == 0 ? "pixel" : "pixel+advance")
    }

    /// The font the ghost text uses (GhostPanel's fallback when the host reports none).
    private func font(_ t: Target, _ est: Estimate) -> NSFont {
        t.font ?? NSFont.systemFont(ofSize: max(11, est.height * 0.78))
    }

    /// Width change of the line when its text before the caret goes from `a` to `b`.
    static func advance(from a: String, to b: String, font: NSFont) -> CGFloat {
        guard a != b else { return 0 }
        let common = a.commonPrefix(with: b)
        let w = { (s: Substring) in s.isEmpty ? 0 : FontMatcher.width(String(s), font) }
        return w(b.dropFirst(common.count)) - w(a.dropFirst(common.count))
    }

    /// Called for every snapshot of a field that needs the pixel caret (AX thread).
    /// Schedules a check once typing pauses; a newer snapshot cancels it.
    func note(_ t: Target) {
        lock.lock()
        generation += 1
        let gen = generation
        let newField = t.fieldKey != lastField
        lastField = t.fieldKey
        let est = estimates[t.fieldKey]
        lock.unlock()
        if let est, est.lineStart == t.lineStart {
            if est.lineText != t.lineText { after(verifyPause, gen) { self.verify(t, est, gen) } }
        } else {
            after(newField ? focusDelay : blinkPause, gen) { self.blink(t, gen) }
        }
    }

    private func after(_ delay: Double, _ gen: Int, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.current(gen) else { return }
            work()
        }
    }

    private func current(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func region(_ t: Target, wholeWindow: Bool) -> CGRect? {
        if !wholeWindow, let f = t.fieldFrame, f.width >= 20, f.height >= 8 {
            return f.insetBy(dx: -6, dy: -6)
        }
        return t.windowFrame
    }

    private func blink(_ t: Target, _ gen: Int) {
        lock.lock()
        let recent = lastBlink[t.fieldKey].map { CFAbsoluteTimeGetCurrent() - $0 < 0.8 } ?? false
        let wide = searchWindow.contains(t.bundleId)
        lock.unlock()
        if recent { return after(0.8, gen) { self.blink(t, gen) } }
        var hit: PixelCaretHit?
        var usedWindow = wide
        for whole in wide ? [true] : [false, true] {
            guard let region = region(t, wholeWindow: whole) else { continue }
            usedWindow = whole
            hit = PixelCaret.blink(pid: t.pid, windowFrame: t.windowFrame, region: region, hint: nil,
                                   cancelled: { [weak self] in self?.current(gen) != true })
            if hit != nil || !current(gen) { break }
        }
        lock.lock()
        lastBlink[t.fieldKey] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        guard let hit, current(gen) else {
            if current(gen) { Log.debug("pixel caret: no blinking caret found in \(t.bundleId)") }
            return
        }
        if usedWindow, !wide, let f = t.fieldFrame, !f.insetBy(dx: -6, dy: -6).contains(CGPoint(x: hit.rect.minX, y: hit.rect.midY)) {
            lock.lock(); searchWindow.insert(t.bundleId); lock.unlock()
        }
        commit(t, hit, gen, how: "blink")
    }

    private func verify(_ t: Target, _ est: Estimate, _ gen: Int) {
        guard let predicted = caret(for: t) else {
            return after(blinkPause - verifyPause, gen) { self.blink(t, gen) }
        }
        let travel = abs(predicted.rect.minX - est.x)
        let radius = min(80, max(16, travel * 0.3 + 12))
        let near = CGPoint(x: predicted.rect.minX, y: est.y + est.height / 2)
        guard let hit = PixelCaret.verify(pid: t.pid, windowFrame: t.windowFrame, near: near, look: est.look, radius: radius,
                                          cancelled: { [weak self] in self?.current(gen) != true }) else {
            return after(0.05, gen) { self.blink(t, gen) }
        }
        commit(t, hit, gen, how: "verify")
    }

    private func commit(_ t: Target, _ hit: PixelCaretHit, _ gen: Int, how: String) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        let old = estimates[t.fieldKey]
        var scale: CGFloat = old?.widthScale ?? 1
        if let old, old.lineStart == t.lineStart {
            let f = t.font ?? NSFont.systemFont(ofSize: max(11, old.height * 0.78))
            let measured = PixelCaretProvider.advance(from: old.lineText, to: t.lineText, font: f)
            var moved: CGFloat = 0
            if let a = old.anchor, let fr = t.fieldFrame { moved = fr.minX - a.x }
            if abs(measured) >= 30 {
                let ratio = (hit.rect.minX - old.x - moved) / measured
                if ratio > 0.6, ratio < 1.6 { scale = (scale + ratio) / 2 }
            }
        }
        estimates[t.fieldKey] = Estimate(x: hit.rect.minX, y: hit.rect.minY, height: hit.rect.height, lineStart: t.lineStart,
                                         lineText: t.lineText, look: hit.look, widthScale: scale, anchor: t.fieldFrame?.origin)
        order.removeAll { $0 == t.fieldKey }
        order.append(t.fieldKey)
        if order.count > 16 { estimates[order.removeFirst()] = nil }
        lock.unlock()
        Log.debug(String(format: "pixel caret (%@): %.0f,%.0f h%.0f in %d frames %.0f ms, width scale %.2f",
                         how, hit.rect.minX, hit.rect.minY, hit.rect.height, hit.frames, hit.ms, scale))
        onUpdate?(t.fieldKey)
    }
}
