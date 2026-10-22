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
///
/// An update found but not installed (automatic install off, or not yet idle) is offered in
/// the menu-bar menu and in Settings ▸ General (`availableVersion`). A scheduled check never
/// opens Sparkle's window in front of the user's work: it uses Sparkle's gentle reminders and
/// puts a dot on the menu-bar icon instead (`needsAttention`); choosing the update opens
/// Sparkle's window (`checkForUpdates`). See docs/DECISIONS.md D40.
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?
    /// FORETYPE_UPDATE_IDLE overrides it (scripts/sparkle-local-test.sh).
    static let idleBeforeInstall = Double(ProcessInfo.processInfo.environment["FORETYPE_UPDATE_IDLE"] ?? "") ?? 300
    /// Whether a suggestion is showing; an update waits until it isn't.
    var isBusy: () -> Bool = { false }

    var isConfigured: Bool { controller != nil }

    /// The version ("0.1.2") of an update a check found that isn't installed yet. Kept across
    /// launches until a check finds none, the user skips it in Sparkle's window or it is
    /// installed.
    private(set) var availableVersion: String?
    /// A scheduled check found the update and Sparkle's window for it hasn't been looked at.
    private(set) var needsAttention = false
    /// Called on the main thread after `availableVersion` or `needsAttention` changes.
    var onAvailabilityChange: (() -> Void)?
    private static let versionKey = "updateAvailableVersion"
    private static let buildKey = "updateAvailableBuild"

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        restoreAvailable()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // FORETYPE_UPDATE_CHECK_NOW=1: a background check at launch, as the daily one would run
        // (scripts/sparkle-local-test.sh).
        if ProcessInfo.processInfo.environment["FORETYPE_UPDATE_CHECK_NOW"] == "1" {
            controller?.updater.checkForUpdatesInBackground()
        }
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

    /// Sparkle's window: "You're up to date", or the update found (release notes, Install
    /// Update, Skip This Version, Remind Me Later), brought to the front if it is waiting.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func setAvailable(_ item: SUAppcastItem?) {
        let d = UserDefaults.standard
        if let item {
            d.set(item.displayVersionString, forKey: Self.versionKey)
            d.set(item.versionString, forKey: Self.buildKey)
        } else {
            d.removeObject(forKey: Self.versionKey)
            d.removeObject(forKey: Self.buildKey)
        }
        setState(version: item?.displayVersionString, attention: item == nil ? false : needsAttention)
    }

    private func setState(version: String?, attention: Bool) {
        guard version != availableVersion || attention != needsAttention else { return }
        Log.debug("update: available=\(version ?? "-") attention=\(attention)")
        availableVersion = version
        needsAttention = attention
        onAvailabilityChange?()
    }

    /// The update found before the app last quit, unless this build is it (or newer).
    private func restoreAvailable() {
        let d = UserDefaults.standard
        guard let version = d.string(forKey: Self.versionKey), let build = d.string(forKey: Self.buildKey) else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if SUStandardVersionComparator.default.compareVersion(build, toVersion: current) == .orderedDescending {
            availableVersion = version
        } else {
            d.removeObject(forKey: Self.versionKey)
            d.removeObject(forKey: Self.buildKey)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailable(item)
    }

    /// Up to date, the update was skipped (scheduled checks leave it out), or it needs
    /// another macOS.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        setAvailable(nil)
    }

    /// Skip This Version hides it too: Sparkle won't offer it again unless the user checks.
    /// Remind Me Later keeps it in the menu.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { setAvailable(nil) }
    }

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

    // MARK: SPUStandardUserDriverDelegate: gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle would show a scheduled update's window at once (in front, just after launch;
    /// otherwise behind other apps). Foretype marks the menu-bar icon instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { setState(version: availableVersion ?? update.displayVersionString, attention: true) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setState(version: availableVersion, attention: false)
    }

    func standardUserDriverWillFinishUpdateSession() {
        setState(version: availableVersion, attention: false)
    }
}
#else
/// Built without Sparkle (development builds): no update checks.
final class UpdateController {
    var isConfigured: Bool { false }
    var isBusy: () -> Bool = { false }
    var availableVersion: String? { nil }
    var needsAttention: Bool { false }
    var onAvailabilityChange: (() -> Void)?
    var automaticallyChecks = false
    var automaticallyInstalls = false
    var lastCheck: Date? { nil }
    func checkForUpdates() {}
}
#endif
