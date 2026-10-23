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
        /// Each pixel's change over the frames, and the pixels that changed enough to count.
        private func changes() -> (strength: [UInt8], mask: [UInt8]) {
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
            return (strength, mask)
        }

        /// The changed bars, and those left after each test a caret must pass: thin and tall,
        /// filled, clear on both sides, nothing else changed around it (typing or scrolling
        /// during the captures changes glyphs around the bar).
        private func stages(_ mask: [UInt8], minHeight: CGFloat, maxHeight: CGFloat) -> [[CaretBar]] {
            let maxW = max(3, Int((3.5 * scale).rounded()))
            let all = PixelCaret.bars(mask: mask, width: width, height: height,
                                      minH: Int(minHeight * scale), maxH: Int(maxHeight * scale), maxW: maxW)
            let shaped = all.filter { $0.height >= 3 * $0.width }
            let filled = shaped.filter { PixelCaret.fill($0, mask: mask, width: width) >= 0.75 }
            let clear = filled.filter {
                PixelCaret.sideFill($0, mask: mask, width: width, gap: 2, cols: 2, left: true) <= 0.2
                    && PixelCaret.sideFill($0, mask: mask, width: width, gap: 2, cols: 2, left: false) <= 0.2
            }
            let quiet = clear.filter { PixelCaret.clutter($0, mask: mask, width: width, height: height, dx: Int(24 * scale)) <= $0.width * $0.height }
            return [all, shaped, filled, clear, quiet]
        }

        /// For the debug log when no caret was found: the frames, how many pixels changed and
        /// how many bars passed each test, with the sizes of the last ones (points). Nothing of
        /// the image itself.
        func diagnosis(minHeight: CGFloat = 6, maxHeight: CGFloat = 90) -> String {
            guard count >= 2 else { return "\(count) frame" }
            let (_, mask) = changes()
            let s = stages(mask, minHeight: minHeight, maxHeight: maxHeight)
            let last = s.last { !$0.isEmpty } ?? []
            let sizes = last.prefix(4).map { String(format: "%.1fx%.0f", CGFloat($0.width) / scale, CGFloat($0.height) / scale) }
            return "\(count) frames of \(width)x\(height) px at \(Int(scale))x, \(mask.reduce(0) { $0 + Int($1) }) px changed, bars "
                + s.map { String($0.count) }.joined(separator: "/") + " (all/thin/filled/clear/quiet) " + sizes.joined(separator: " ")
        }

        func bar(hint: CGPoint?, minHeight: CGFloat = 6, maxHeight: CGFloat = 90) -> (CaretBar, CaretLook)? {
            guard count >= 2 else { return nil }
            let (strength, mask) = changes()
            let candidates = stages(mask, minHeight: minHeight, maxHeight: maxHeight).last ?? []
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
        let p = f.pixel(near)
        return staticBars(f, look: look).filter { abs(CGFloat($0.x0) - p.x) <= radius * f.scale }
            .min { abs(CGFloat($0.x0) - p.x) < abs(CGFloat($1.x0) - p.x) }
    }

    /// Every bar that looks like `look` on one frame, with its centre.
    static func staticBars(_ f: PixelFrame, look: CaretLook) -> [CaretBar] {
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
        return candidates.map { b in
            var b = b
            b.centerX = centroid(b, strength: strength, width: f.width)
            return b
        }
    }

    // MARK: - Capture

    private static let windowLock = NSLock()
    private static var windowCache: (pid: pid_t, windows: [SCWindow], displays: [SCDisplay], at: CFAbsoluteTime)?

    /// The app's on-screen windows and the displays (cached for 2 s; ScreenCaptureKit's list
    /// costs 10–40 ms).
    private static func windows(pid: pid_t, refresh: Bool) -> (windows: [SCWindow], displays: [SCDisplay]) {
        windowLock.lock()
        if !refresh, let c = windowCache, c.pid == pid, CFAbsoluteTimeGetCurrent() - c.at < 2 {
            windowLock.unlock()
            return (c.windows, c.displays)
        }
        windowLock.unlock()
        let done = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in
            content = c
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success, let content else { return ([], []) }
        let list = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 30
        }
        windowLock.lock()
        windowCache = (pid, list, content.displays, CFAbsoluteTimeGetCurrent())
        windowLock.unlock()
        return (list, content.displays)
    }

    /// Captures `region` (global points) of the app window that contains it. Only that
    /// window is captured, so other windows and Foretype's overlay never appear, and the
    /// pointer is left out. Blocks up to 1.5 s; call off the main thread.
    static func capture(pid: pid_t, windowFrame: CGRect?, region: CGRect) -> PixelFrame? {
        for refresh in [false, true] {
            let (list, displays) = windows(pid: pid, refresh: refresh)
            let center = CGPoint(x: region.midX, y: region.midY)
            let window = list.filter { $0.frame.contains(center) }.min { a, b in
                guard let wf = windowFrame else { return a.frame.width * a.frame.height < b.frame.width * b.frame.height }
                return abs(a.frame.minX - wf.minX) + abs(a.frame.minY - wf.minY) + abs(a.frame.width - wf.width)
                    < abs(b.frame.minX - wf.minX) + abs(b.frame.minY - wf.minY) + abs(b.frame.width - wf.width)
            }
            guard let window,
                  let shot = WindowCapture.image(of: window, rect: region.intersection(window.frame), displays: displays) else { continue }
            return PixelFrame(image: shot.image, origin: shot.origin, scale: shot.scale)
        }
        return nil
    }

    // MARK: - Detection runs (blocking; call on a background queue)

    /// Captures `region` every `interval` until the caret blinks or `timeout` passes.
    /// `cancelled` is checked before every capture.
    /// `failed` gets the reason when it finds nothing (for the debug log).
    static func blink(pid: pid_t, windowFrame: CGRect?, region: CGRect, hint: CGPoint?,
                      interval: Double = 0.12, timeout: Double = 1.3, cancelled: () -> Bool = { false },
                      failed: (String) -> Void = { _ in }) -> PixelCaretHit? {
        let t0 = CFAbsoluteTimeGetCurrent()
        var acc: BlinkAccumulator?
        while CFAbsoluteTimeGetCurrent() - t0 < timeout {
            if cancelled() { return nil }
            let shot = CFAbsoluteTimeGetCurrent()
            guard let f = capture(pid: pid, windowFrame: windowFrame, region: region) else {
                failed("no capture of \(Int(region.width))x\(Int(region.height)) pt")
                return nil
            }
            if acc == nil {
                acc = BlinkAccumulator(f)
            } else if acc?.add(f) != true {
                failed("frame size changed")
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
        if let acc { failed(acc.diagnosis()) }
        return nil
    }

    /// One capture of `region` for every bar like `look`, as zero-width rectangles (global).
    /// The caret is drawn solid while the user types, so no blink is needed to see it.
    static func solid(pid: pid_t, windowFrame: CGRect?, region: CGRect, look: CaretLook) -> (rects: [CGRect], ms: Double)? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let f = capture(pid: pid, windowFrame: windowFrame, region: region) else { return nil }
        let rects = staticBars(f, look: look).map { f.global(x0: $0.centerX, x1: $0.centerX, y0: $0.y0, y1: $0.y1) }
        return (rects, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// The caret among the bars `rects` found by one capture. Without a previous position it
    /// must be the only one. With one (`from`, the caret's last known place): on that row near
    /// `predictedX` when `direction` is 0 (the line may be about to wrap), else on the nearest
    /// row below (`direction` 1: a new line or a wrap) or above (-1) that has any; there the
    /// leftmost at a line start, the rightmost at a line end, or the only one.
    static func choose(_ rects: [CGRect], from: CGRect?, predictedX: CGFloat?, direction: Int,
                       lineStart: Bool, lineEnd: Bool) -> CGRect? {
        guard let from else { return rects.count == 1 ? rects[0] : nil }
        let h = from.height
        func sameRow(_ r: CGRect, _ y: CGFloat) -> Bool { abs(r.midY - y) <= h / 2 }
        if direction == 0, let px = predictedX,
           let r = rects.filter({ sameRow($0, from.midY) && abs($0.minX - px) <= max(16, h) })
               .min(by: { abs($0.minX - px) < abs($1.minX - px) }) {
            return r
        }
        let d: CGFloat = direction < 0 ? -1 : 1
        let beyond = rects.filter { ($0.midY - from.midY) * d > h / 2 }
        guard let nearest = beyond.min(by: { abs($0.midY - from.midY) < abs($1.midY - from.midY) }) else { return nil }
        let row = beyond.filter { sameRow($0, nearest.midY) }
        if lineStart { return row.min { $0.minX < $1.minX } }
        if lineEnd { return row.max { $0.minX < $1.minX } }
        return row.count == 1 ? row[0] : nil
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

// MARK: - Window capture

/// One screenshot of `rect` (global points) of one window alone: no other window, Foretype's
/// overlay or the pointer is in it. A window in full screen (its own Space) can't be captured
/// as a desktop-independent window (ScreenCaptureKit error -3811, "audio/video capture
/// failure"); such a window is captured through its display with only that window included,
/// and remembered so the failing attempt isn't repeated. Blocks up to 1.5 s per attempt; call
/// off the main thread.
enum WindowCapture {
    private static let lock = NSLock()
    private static var viaDisplay: Set<CGWindowID> = []

    static func image(of window: SCWindow, rect: CGRect, displays: [SCDisplay]) -> (image: CGImage, origin: CGPoint, scale: CGFloat)? {
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        lock.lock()
        let known = viaDisplay.contains(window.windowID)
        lock.unlock()
        if !known, let shot = shot(SCContentFilter(desktopIndependentWindow: window), rect: rect, origin: window.frame.origin) {
            return shot
        }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = displays.first(where: { $0.frame.contains(centre) }),
              let shot = shot(SCContentFilter(display: display, including: [window]), rect: rect.intersection(display.frame),
                              origin: display.frame.origin) else { return nil }
        if !known {
            lock.lock()
            let first = viaDisplay.insert(window.windowID).inserted  // screen context may race here
            lock.unlock()
            if first { Log.debug("capture: \(window.owningApplication?.applicationName ?? "?") window \(window.windowID) only through its display (full screen)") }
        }
        return shot
    }

    /// `rect` relative to `origin` (the filter's own origin), in whole pixels so the bytes map
    /// exactly onto points.
    private static func shot(_ filter: SCContentFilter, rect: CGRect, origin: CGPoint) -> (image: CGImage, origin: CGPoint, scale: CGFloat)? {
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        let scale = CGFloat(filter.pointPixelScale)
        let local = CGRect(x: floor((rect.minX - origin.x) * scale) / scale, y: floor((rect.minY - origin.y) * scale) / scale,
                           width: ceil(rect.width * scale) / scale, height: ceil(rect.height * scale) / scale)
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
        return (image, CGPoint(x: origin.x + local.minX, y: origin.y + local.minY), CGFloat(image.width) / local.width)
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
        /// The AX caret rejected only for lying outside the field frame, to confirm.
        var edgeOutsideFrame: CGRect?
        /// Nothing but spaces follows the caret on its line.
        var lineEnd = true
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
    /// The caret look last learned in each app, for a solid search in its other fields.
    private var looks: [String: CaretLook] = [:]
    /// When a solid search last found nothing, per field (not retried for `solidRetry`).
    private var solidMiss: [UInt64: CFAbsoluteTime] = [:]
    /// The field and generation of a solid search that is scheduled or running.
    private var locating: (field: UInt64, gen: Int)?

    private let focusDelay = 0.15
    private let verifyPause = 0.25
    private let blinkPause = 0.5
    /// After a snapshot, before a solid search: the app has drawn the new text by then.
    private let solidDelay = 0.04
    private let solidRetry = 0.3

    /// The current estimate for `t`, advanced by the text typed since it was measured, or
    /// nil (unknown, another line, or wrapped past the field's edge).
    func caret(for t: Target) -> CaretInfo? {
        lock.lock()
        let est = estimates[t.fieldKey]
        lock.unlock()
        guard let est, est.lineStart == t.lineStart else { return nil }
        let p = project(t, est)
        guard p.rect.minX < p.right - 1, p.rect.minX > p.left else { return nil }
        return CaretInfo(rect: p.rect, strategy: p.rect.minX == p.at.minX ? "pixel" : "pixel+advance")
    }

    /// The estimate where it was measured (`at`, moved with the field) and advanced by the
    /// text typed since on its line (`rect`, unchecked), and the line's horizontal bounds.
    private func project(_ t: Target, _ est: Estimate) -> (at: CGRect, rect: CGRect, left: CGFloat, right: CGFloat) {
        var est = est
        if let a = est.anchor, let f = t.fieldFrame {
            est.x += f.minX - a.x
            est.y += f.minY - a.y
        }
        let at = CGRect(x: est.x, y: est.y, width: 0, height: est.height)
        let dx = est.lineStart == t.lineStart
            ? PixelCaretProvider.advance(from: est.lineText, to: t.lineText, font: font(t, est)) * est.widthScale : 0
        // The field's horizontal extent bounds the line (LibreOffice's frames are only off vertically).
        let field = t.fieldFrame.flatMap { f in est.x >= f.minX - 4 && est.x <= f.maxX + 4 ? f : nil }
        let right = (field ?? t.windowFrame)?.maxX ?? .greatestFiniteMagnitude
        let left = (field ?? t.windowFrame)?.minX ?? -.greatestFiniteMagnitude
        return (at, at.offsetBy(dx: dx, dy: 0), left, right)
    }

    /// Whether a solid search for this field is under way: the controller then waits for it
    /// (a few tens of milliseconds) rather than showing the mirror card for a moment.
    func isLocating(_ fieldKey: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return locating?.field == fieldKey
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

    /// Called for every snapshot of a field that needs the pixel caret (AX thread), before
    /// the snapshot is submitted. Schedules a check once typing pauses; a newer snapshot
    /// cancels it. Where the estimate gives no position (a new field, another line, a wrap) or
    /// the line may be about to wrap, and the app's caret look is known, it searches right
    /// away instead: the caret is solid while the user types, so one capture finds it.
    func note(_ t: Target) {
        lock.lock()
        generation += 1
        let gen = generation
        let newField = t.fieldKey != lastField
        lastField = t.fieldKey
        let est = estimates[t.fieldKey]
        let look = est?.look ?? looks[t.bundleId]
        let missed = solidMiss[t.fieldKey].map { CFAbsoluteTimeGetCurrent() - $0 < solidRetry } ?? false
        lock.unlock()
        var solid: CaretLook?
        if let est, est.lineStart == t.lineStart, let c = caret(for: t) {
            let p = project(t, est)
            // Within about a word of the right edge the host may wrap the word being typed.
            if est.lineText != t.lineText, !missed, p.right - c.rect.minX < max(40, est.height * 3) {
                solid = est.look
            } else if est.lineText != t.lineText {
                after(verifyPause, gen) { self.verify(t, est, gen) }
            }
        } else if let look, !missed {
            solid = look
        } else {
            after(newField ? focusDelay : blinkPause, gen) { self.blink(t, gen) }
        }
        lock.lock()
        locating = solid == nil ? nil : (t.fieldKey, gen)
        lock.unlock()
        if let solid { after(solidDelay, gen) { self.locate(t, est, solid, gen) } }
    }

    /// Drops every check and search not yet run (paused).
    func cancel() {
        lock.lock()
        generation += 1
        locating = nil
        lock.unlock()
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
        if !wholeWindow, let e = t.edgeOutsideFrame {
            // Where AX says the caret is (to confirm it): that line, across the field.
            let xs = t.fieldFrame.map { ($0.minX - 6, $0.width + 12) } ?? (e.minX - 300, 600)
            return CGRect(x: xs.0, y: e.minY - e.height, width: xs.1, height: e.height * 3)
        }
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
        var why: [String] = []
        for whole in wide ? [true] : [false, true] {
            guard let region = region(t, wholeWindow: whole) else { continue }
            usedWindow = whole
            hit = PixelCaret.blink(pid: t.pid, windowFrame: t.windowFrame, region: region, hint: nil,
                                   cancelled: { [weak self] in self?.current(gen) != true },
                                   failed: { why.append("\(whole ? "window" : "field"): \($0)") })
            if hit != nil || !current(gen) { break }
        }
        lock.lock()
        lastBlink[t.fieldKey] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        guard let hit, current(gen) else {
            if current(gen) { Log.debug("pixel caret: no blinking caret found in \(t.bundleId) (\(why.joined(separator: "; ")))") }
            return
        }
        if usedWindow, !wide, let f = t.fieldFrame, !f.insetBy(dx: -6, dy: -6).contains(CGPoint(x: hit.rect.minX, y: hit.rect.midY)) {
            lock.lock(); searchWindow.insert(t.bundleId); lock.unlock()
        }
        commit(t, hit, gen, how: "blink")
    }

    /// One capture for a solid caret like `look`: the whole field without an estimate, else
    /// the lines around it, choosing the row the caret moved to (`PixelCaret.choose`). When
    /// nothing is found it falls back to a blink search at the next pause.
    private func locate(_ t: Target, _ est: Estimate?, _ look: CaretLook, _ gen: Int) {
        lock.lock()
        let wide = searchWindow.contains(t.bundleId)
        lock.unlock()
        var from: CGRect?, predicted: CGFloat?, direction = 0
        var area = region(t, wholeWindow: wide)
        if let est {
            let p = project(t, est)
            if est.lineStart != t.lineStart {
                from = p.at
                direction = t.lineStart > est.lineStart ? 1 : -1
            } else {
                from = p.rect
                predicted = p.rect.minX
                direction = p.rect.minX >= p.right - 1 ? 1 : p.rect.minX <= p.left ? -1 : 0
            }
            if let a = area {
                let h = p.at.height
                area = a.intersection(CGRect(x: a.minX, y: p.at.minY - 4 * h, width: a.width, height: 9 * h))
            }
        }
        let found = area.flatMap { $0.isNull ? nil : PixelCaret.solid(pid: t.pid, windowFrame: t.windowFrame, region: $0, look: look) }
        guard current(gen) else { return }
        let rect = found.flatMap {
            PixelCaret.choose($0.rects, from: from, predictedX: predicted, direction: direction,
                              lineStart: t.lineText.isEmpty, lineEnd: t.lineEnd)
        }
        guard let rect, let found else {
            lock.lock()
            solidMiss[t.fieldKey] = CFAbsoluteTimeGetCurrent()
            if locating?.gen == gen { locating = nil }
            lock.unlock()
            Log.debug("pixel caret: no solid caret found in \(t.bundleId) (\(found?.rects.count ?? -1) bars, direction \(direction), from y \(from.map { Int($0.minY) } ?? -1))")
            // The controller held the suggestion back for this search: show it anyway.
            onUpdate?(t.fieldKey)
            return after(blinkPause - solidDelay, gen) { self.blink(t, gen) }
        }
        commit(t, PixelCaretHit(rect: rect, look: look, frames: 1, ms: found.ms), gen, how: "solid")
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
        looks[t.bundleId] = hit.look
        solidMiss[t.fieldKey] = nil
        if locating?.gen == gen { locating = nil }
        order.removeAll { $0 == t.fieldKey }
        order.append(t.fieldKey)
        if order.count > 16 { estimates[order.removeFirst()] = nil }
        lock.unlock()
        Log.debug(String(format: "pixel caret (%@): %.0f,%.0f h%.0f in %d frames %.0f ms, width scale %.2f",
                         how, hit.rect.minX, hit.rect.minY, hit.rect.height, hit.frames, hit.ms, scale))
        // An AX character rect that only the frame check rejected, where the caret really is:
        // after two such matches the app's rects are trusted and AX places the caret again.
        if let e = t.edgeOutsideFrame {
            let agreed = abs(e.minX - hit.rect.minX) <= 1.5 && abs(e.midY - hit.rect.midY) <= max(3, hit.rect.height * 0.25)
            if CaretResolver.notePixelCheck(t.bundleId, agreed: agreed) {
                Log.debug("pixel caret: \(t.bundleId)'s character rects match the screen outside the field frame; using them")
            }
        }
        onUpdate?(t.fieldKey)
    }
}
