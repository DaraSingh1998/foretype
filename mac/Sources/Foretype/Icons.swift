import AppKit

/// The menu-bar glyph: a caret with a gray ghost word after it, the app icon in miniature.
/// Drawn in code as an 18 pt template image (redrawn at each screen's scale, edges on whole
/// pixels), one picture per state, with a dot in the top corner while an update waits to be
/// looked at. Main thread.
enum MenuBarIcon {
    enum State: CaseIterable {
        /// Suggesting: the caret and its ghost word.
        case active
        /// Turned off for a while by the user: a dimmed caret and a pause sign.
        case paused
        /// Paused to save power (on battery, Low Power Mode): a dimmed caret and a battery.
        case powerPaused
        /// Starting, or loading a model: the caret and three dots.
        case loading
        /// Not suggesting until something is fixed (setup, a permission, an engine error): a
        /// dimmed caret and an exclamation mark.
        case error
    }

    private(set) static var state = State.loading
    /// An update is waiting (`UpdateController.needsAttention`): a dot in the top-right corner.
    private(set) static var badge = false
    private static weak var button: NSStatusBarButton?

    /// Shows the glyph on the status item's button, in the current state.
    static func attach(_ button: NSStatusBarButton?) {
        self.button = button
        apply()
    }

    static func set(_ state: State, badge: Bool = false) {
        guard state != self.state || badge != self.badge else { return }
        self.state = state
        self.badge = badge
        apply()
    }

    private static func apply() {
        button?.image = image(state, badge: badge)
    }

    static func image(_ state: State, badge: Bool = false) -> NSImage {
        var description: String
        switch state {
        case .active: description = "Foretype"
        case .paused: description = L("Foretype (paused)")
        case .powerPaused: description = L("Foretype (paused to save power)")
        case .loading: description = L("Foretype (loading)")
        case .error: description = L("Foretype (needs attention)")
        }
        if badge { description += ", " + L("update available") }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, badge: badge, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Points, origin at the bottom left. Only alpha counts in a template image: 1 draws in
    /// the menu bar's text color, 0.45 in a lighter gray (the ghost word, a dimmed caret).
    private static func draw(_ state: State, badge: Bool, in ctx: CGContext) {
        let scale = max(1, ctx.userSpaceToDeviceSpaceTransform.a)
        // Edges on whole device pixels, and nothing thinner than one pixel.
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: px(x), y: px(y), width: max(1, (w * scale).rounded()) / scale, height: max(1, (h * scale).rounded()) / scale)
        }
        func fill(_ r: CGRect, radius: CGFloat? = nil, alpha: CGFloat = 1) {
            let rad = min(radius ?? min(r.width, r.height) / 2, min(r.width, r.height) / 2)
            ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.fillPath()
        }
        let dim: CGFloat = 0.45
        fill(box(3.5, 2.5, 1.5, 13), alpha: state == .active || state == .loading ? 1 : dim)
        switch state {
        case .active:
            fill(box(7, 7.5, 4.5, 2.5), alpha: dim)
            fill(box(12.5, 7.5, 2.5, 2.5), alpha: dim)
        case .paused:
            fill(box(8.5, 5, 2, 8), radius: 0.5)
            fill(box(12.5, 5, 2, 8), radius: 0.5)
        case .powerPaused:
            let body = box(7.5, 6, 7, 6)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.strokePath()
            fill(box(14.5, 7.5, 1, 3), radius: 0.5)
            // Nearly empty.
            fill(box(body.minX + 1.5, body.minY + 1.5, 1.5, body.height - 3), radius: 0.25)
        case .loading:
            for x in [7.5, 10.75, 14.0] { fill(box(x, 8, 2, 2)) }
        case .error:
            fill(box(10.5, 7, 2, 8.5))
            fill(box(10.5, 2.5, 2, 2))
        }
        if badge { fill(box(14.5, 14, 3.5, 3.5)) }
    }
}

/// A bare dev binary (mac/.build/release/Foretype) has no bundle and so no icon: alerts and
/// the Dock would show a generic one. Use mac/Resources/AppIcon.icns from the checkout it was
/// built in. The bundled app's Info.plist names its own (CFBundleIconFile), so this does nothing there.
enum AppIcon {
    static func useCheckoutIconIfUnbundled() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
              var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return }
        // <checkout>/mac/.build/release is a link to <triple>/release or, with newer SwiftPM,
        // out/Products/Release: mac/ is four or five levels above the executable's folder.
        for _ in 0..<6 {
            let icns = dir.appendingPathComponent("Resources/AppIcon.icns")
            if let image = NSImage(contentsOf: icns) {
                NSApp.applicationIconImage = image
                return
            }
            dir.deleteLastPathComponent()
        }
    }
}
