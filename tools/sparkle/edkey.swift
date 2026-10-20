// Throwaway Sparkle EdDSA (Ed25519) keys for local update tests, using CryptoKit instead of
// Sparkle's generate_keys / sign_update (which keep the private key in the login keychain).
// Never use these keys for a release: see RELEASING.md for the real ones.
//
//   swift tools/sparkle/edkey.swift generate KEY_FILE      prints the public key (SUPublicEDKey)
//   swift tools/sparkle/edkey.swift sign KEY_FILE ARCHIVE  prints the appcast enclosure attributes
import CryptoKit
import Foundation

let args = CommandLine.arguments
func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(2)
}

switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "generate"):
    let key = Curve25519.Signing.PrivateKey()
    let path = args[2]
    FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case (4, "sign"):
    guard let text = try? String(contentsOfFile: args[2], encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("edkey: bad key file") }
    guard let archive = try? Data(contentsOf: URL(fileURLWithPath: args[3])) else { fail("edkey: cannot read archive") }
    guard let sig = try? key.signature(for: archive) else { fail("edkey: signing failed") }
    print("sparkle:edSignature=\"\(sig.base64EncodedString())\" length=\"\(archive.count)\"")
default:
    fail("usage: edkey.swift generate KEY_FILE | sign KEY_FILE ARCHIVE")
}
