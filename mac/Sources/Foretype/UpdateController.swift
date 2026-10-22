import Foundation
import IOKit

/// Seconds since the last keyboard or mouse input (IOHIDSystem's HIDIdleTime).
enum UserIdle {
    static func seconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? NSNumber).map { $0.doubleValue / 1e9 }
    }
}

#if canImport(Sparkle)
import Sparkle

/// Sparkle 2 auto-updates. Active only in release builds made with FORETYPE_SPARKLE=1 whose
/// Info.plist carries SUFeedURL and SUPublicEDKey (scripts/build-mac.sh writes them; the feed
/// is the latest GitHub release's appcast.xml). Updates are EdDSA-signed.
///
/// Release builds check daily and download a found update on their own. Sparkle would install
/// it when the app quits, but Foretype is a menu-bar app that can run for weeks, so the update
/// is installed (and the app relaunched) once the user has left the keyboard and mouse alone
/// for `idleBeforeInstall` and no suggestion is on screen. Both switches are in Settings ▸
/// General; Sparkle keeps them in the app's defaults.
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?
    static let idleBeforeInstall: Double = 300
    /// Whether a suggestion is showing; an update waits until it isn't.
    var isBusy: () -> Bool = { false }

    var isConfigured: Bool { controller != nil }

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// When the last check ran, if one has.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.installIfIdle() }
        return true
    }

    private func installIfIdle() {
        guard let install = pendingInstall, let idle = UserIdle.seconds(),
              idle >= Self.idleBeforeInstall, !isBusy() else { return }
        pendingInstall = nil
        idleTimer?.invalidate()
        idleTimer = nil
        // Quits through NSApp.terminate (applicationWillTerminate saves downloads in progress),
        // replaces the app and relaunches it.
        install()
    }
}
#else
/// Built without Sparkle (development builds): no update checks.
final class UpdateController {
    var isConfigured: Bool { false }
    var isBusy: () -> Bool = { false }
    var automaticallyChecks = false
    var automaticallyInstalls = false
    var lastCheck: Date? { nil }
    func checkForUpdates() {}
}
#endif
