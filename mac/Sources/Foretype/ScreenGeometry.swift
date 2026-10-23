import AppKit

/// Screen coordinates across displays, as pure functions so `--geometry-selftest` can check
/// them against made-up display layouts.
///
/// Two coordinate spaces meet in the shell:
/// - Global (Quartz) coordinates: origin at the top-left of the primary display (the one in
///   System Settings ▸ Displays with the menu bar), y grows downwards. Accessibility
///   (`AXPosition`, `AXBoundsForRange`), `CGDisplayBounds` and ScreenCaptureKit
///   (`SCWindow.frame`, `SCDisplay.frame`) use them.
/// - Cocoa coordinates: origin at the bottom-left of the primary display, y grows upwards.
///   `NSScreen.frame` and `NSWindow` frames use them.
///
/// A display left of or above the primary has negative global x or y; one above it has a
/// Cocoa y beyond the primary's height. Converting takes only the primary's height, and the
/// formula is its own inverse.
enum ScreenGeometry {
    struct Display: Equatable {
        /// Global coordinates, in points.
        var bounds: CGRect
        /// Backing pixels per point: 2 on Retina displays, 1 on most external ones.
        var scale: CGFloat
    }

    static func cocoaRect(fromGlobal r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func globalRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The display showing most of `rect` (global); for a rect on none, the nearest one.
    /// nil only when there are no displays.
    static func displayIndex(for rect: CGRect, in displays: [CGRect]) -> Int? {
        let overlaps = displays.map { d -> CGFloat in
            let i = d.intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return best
        }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func distance(_ d: CGRect) -> CGFloat {
            let dx = max(d.minX - c.x, 0, c.x - d.maxX), dy = max(d.minY - c.y, 0, c.y - d.maxY)
            return dx * dx + dy * dy
        }
        return displays.indices.min { distance(displays[$0]) < distance(displays[$1]) }
    }

    /// The display a rect (a window, a field, a caret) is on.
    static func display(for rect: CGRect, in displays: [CGRect]) -> CGRect? {
        displayIndex(for: rect, in: displays).map { displays[$0] }
    }

    /// Backing scale for capturing `rect` (global), from the display showing most of it.
    static func scale(for rect: CGRect, in displays: [Display]) -> CGFloat? {
        displayIndex(for: rect, in: displays.map(\.bounds)).map { displays[$0].scale }
    }

    /// Global y for a card `height` tall next to `anchor`: above it, `gap` apart, when that
    /// stays on `display` (the anchor's), otherwise below it.
    static func cardY(nextTo anchor: CGRect, height: CGFloat, gap: CGFloat, display: CGRect?) -> CGFloat {
        let above = anchor.minY - height - gap
        return above >= (display?.minY ?? 0) ? above : anchor.maxY + gap
    }

    // MARK: - Live values

    /// Height of the primary display: the one Cocoa and global coordinates flip around.
    static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Active displays in global coordinates, with their backing scales.
    static func displays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? bounds.width
            return Display(bounds: bounds, scale: bounds.width > 0 ? max(1, (pixels / bounds.width).rounded()) : 1)
        }
    }

    // MARK: - Self-test

    /// `Foretype --geometry-selftest`: conversions and display matching for layouts with a
    /// second display left of, above, below and right of the primary, at mixed scales. Needs
    /// no permissions and no second display.
    static func selfTest() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL: \(what)") }
        }
        // A 14-inch MacBook Pro at its default resolution (Retina) is the primary display.
        let laptop = Display(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let h = laptop.bounds.height
        let layouts: [(name: String, external: Display)] = [
            ("right, top-aligned", Display(bounds: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 1)),
            ("above, centred", Display(bounds: CGRect(x: -524, y: -1440, width: 2560, height: 1440), scale: 1)),
            ("left, bottom-aligned", Display(bounds: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1)),
            ("below", Display(bounds: CGRect(x: 0, y: 982, width: 1920, height: 1080), scale: 2)),
        ]

        // Conversions: the primary maps onto itself, every display stays the same size, a
        // rect inside a display stays inside it, and the conversion undoes itself.
        check(cocoaRect(fromGlobal: laptop.bounds, primaryHeight: h) == laptop.bounds, "primary maps onto itself")
        let caret = CGRect(x: 100, y: 100, width: 1, height: 18)
        check(cocoaRect(fromGlobal: caret, primaryHeight: h) == CGRect(x: 100, y: 864, width: 1, height: 18), "caret on the primary")
        for (name, ext) in layouts {
            let cocoaDisplay = cocoaRect(fromGlobal: ext.bounds, primaryHeight: h)
            check(cocoaDisplay.size == ext.bounds.size, "\(name): size kept")
            let inside = CGRect(x: ext.bounds.minX + 40, y: ext.bounds.minY + 30, width: 1, height: 18)
            let cocoa = cocoaRect(fromGlobal: inside, primaryHeight: h)
            check(cocoaDisplay.contains(cocoa), "\(name): a caret stays on its display (\(cocoa) in \(cocoaDisplay))")
            check(globalRect(fromCocoa: cocoa, primaryHeight: h) == inside, "\(name): round trip")
        }
        check(cocoaRect(fromGlobal: layouts[1].external.bounds, primaryHeight: h) == CGRect(x: -524, y: 982, width: 2560, height: 1440),
              "a display above the primary starts at the primary's height in Cocoa")

        // Display matching and capture scale.
        for (name, ext) in layouts {
            let displays = [laptop, ext]
            let onExternal = CGRect(x: ext.bounds.minX + 100, y: ext.bounds.minY + 80, width: 800, height: 600)
            let onLaptop = CGRect(x: 200, y: 150, width: 900, height: 700)
            check(scale(for: onExternal, in: displays) == ext.scale, "\(name): window on the external display")
            check(scale(for: onLaptop, in: displays) == 2, "\(name): window on the laptop")
            check(display(for: onExternal, in: displays.map(\.bounds)) == ext.bounds, "\(name): display of a window")
        }
        // A window across both displays takes the one showing most of it.
        let wide = [laptop, layouts[0].external]
        check(scale(for: CGRect(x: 1300, y: 100, width: 1000, height: 500), in: wide) == 1, "straddling: mostly external")
        check(scale(for: CGRect(x: 700, y: 100, width: 1000, height: 500), in: wide) == 2, "straddling: mostly laptop")
        // Off every display (a window being dragged past an edge): the nearest one.
        check(display(for: CGRect(x: -3000, y: 200, width: 100, height: 100), in: [laptop.bounds, layouts[2].external.bounds])
              == layouts[2].external.bounds, "off-screen: nearest display")
        check(displayIndex(for: caret, in: []) == nil, "no displays")

        // The bug this replaced (ScreenContext until 2026-10-23): matching a window's global frame
        // against NSScreen's Cocoa frames. With displays above and below the primary, a window
        // on the lower one matches the upper one and is captured at the wrong scale.
        let above = Display(bounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080), scale: 1)
        let below = Display(bounds: CGRect(x: 0, y: 982, width: 1920, height: 1080), scale: 2)
        let three = [laptop, above, below]
        let windowBelow = CGRect(x: 100, y: 1100, width: 900, height: 600)
        let cocoaScreens = three.map { (frame: cocoaRect(fromGlobal: $0.bounds, primaryHeight: h), scale: $0.scale) }
        let old = cocoaScreens.first { $0.frame.intersects(windowBelow) }?.scale ?? 2
        check(old == 1, "the old matching picks the display above for a window below")
        check(scale(for: windowBelow, in: three) == 2, "three displays: window below")
        check(scale(for: CGRect(x: 100, y: -900, width: 900, height: 600), in: three) == 1, "three displays: window above")

        // Cards above a field: the display's own top edge decides, not y = 0.
        let fieldAbove = CGRect(x: 100, y: -1000, width: 600, height: 40)
        check(cardY(nextTo: fieldAbove, height: 24, gap: 4, display: above.bounds) == -1028, "card above a field on the upper display")
        let fieldAtTop = CGRect(x: 100, y: -1075, width: 600, height: 40)
        check(cardY(nextTo: fieldAtTop, height: 24, gap: 4, display: above.bounds) == -1031, "card below a field at the upper display's top")
        let fieldBelowTop = CGRect(x: 100, y: 990, width: 600, height: 40)
        check(cardY(nextTo: fieldBelowTop, height: 24, gap: 4, display: below.bounds) == 1034,
              "card below a field at the lower display's top (above it would be on the laptop)")
        check(cardY(nextTo: CGRect(x: 10, y: 300, width: 100, height: 20), height: 24, gap: 4, display: laptop.bounds) == 272,
              "card above a field on the primary")

        // This Mac's displays, for the record (not checked: any layout is valid). For a window
        // in the middle of each, the scale the old matching would have used.
        let live = displays()
        let screens = NSScreen.screens.map { (frame: $0.frame, scale: $0.backingScaleFactor) }
        print("this Mac: \(live.count) display(s), primary height \(primaryHeight())")
        for d in live {
            let window = d.bounds.insetBy(dx: d.bounds.width / 4, dy: d.bounds.height / 4)
            let old = screens.first { $0.frame.intersects(window) }?.scale ?? 2
            let cocoa = cocoaRect(fromGlobal: d.bounds, primaryHeight: primaryHeight())
            let matches = screens.contains { $0.frame == cocoa && $0.scale == d.scale }
            print("  global \(d.bounds) at \(d.scale)x; Cocoa \(cocoa)\(matches ? " (= an NSScreen)" : " (NO NSScreen matches)");"
                  + " capture scale \(scale(for: window, in: live) ?? 0)x, the old matching \(old)x")
            check(matches, "this Mac: display \(d.bounds) converts to an NSScreen frame")
        }

        print(failures == 0 ? "geometry self-test passed" : "geometry self-test FAILED (\(failures))")
        return failures == 0
    }
}
