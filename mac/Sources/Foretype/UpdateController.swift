import Foundation

#if canImport(Sparkle)
import Sparkle

/// Sparkle 2 auto-updates. Active only in release builds made with FORETYPE_SPARKLE=1 whose
/// Info.plist carries SUFeedURL and SUPublicEDKey (scripts/build-mac.sh writes them from
/// FORETYPE_FEED_URL and FORETYPE_SPARKLE_PUBLIC_KEY). Updates are EdDSA-signed.
final class UpdateController {
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
#else
/// Built without Sparkle (development builds): no update checks.
final class UpdateController {
    var isConfigured: Bool { false }
    func checkForUpdates() {}
}
#endif
