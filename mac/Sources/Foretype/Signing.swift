import Foundation
import Security

/// How this copy of the app is signed. macOS ties an ad-hoc build's Accessibility and Screen
/// Recording grants to that exact build (its cdhash), so after a rebuild the entry in System
/// Settings still looks on but no longer applies: it has to be removed with − and added again.
/// scripts/make-dev-cert.sh gives local builds a stable identity instead.
enum Signing {
    /// True for an app bundle signed ad hoc. False for a bare dev binary run from a terminal,
    /// which uses the terminal's grants, and for any certificate-signed build.
    static let isAdHocBundle: Bool = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32
        else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }()

    /// Shown under a permission that isn't granted, on ad-hoc builds only.
    static var staleGrantHint: String {
        L("Already on in System Settings? This build is signed ad hoc, so the old entry doesn't apply to it: remove Foretype from the list with −, then add it again.")
    }
}
