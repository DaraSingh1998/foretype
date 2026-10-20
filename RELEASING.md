# Releasing Foretype

Foretype ships as a notarized, unsandboxed DMG (Accessibility control, global event taps and
posting keystrokes into other apps rule out the App Store sandbox), updated through Sparkle
and also installable with a Homebrew cask.

## One-time setup

1. **Developer ID certificate.** In an Apple Developer account, create a "Developer ID
   Application" certificate and install it in your login keychain. Check with
   `security find-identity -v -p codesigning`.
2. **Notary credentials.** Create an app-specific password for your Apple ID, then:

   ```bash
   xcrun notarytool store-credentials foretype-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID1234
   ```

3. **Sparkle keys.** Download the Sparkle release tarball (the version pinned in
   `mac/Package.swift`, 2.10.0) and run `bin/generate_keys`. It stores the EdDSA private key
   in your keychain and prints the public key. Keep a backup of the private key
   (`generate_keys -x private-key-file`): losing it means existing installs can no longer
   verify updates.
4. **Appcast hosting.** Serve `appcast.xml` from a stable HTTPS URL, for example GitHub
   Pages on a `gh-pages` branch: `https://OWNER.github.io/foretype/appcast.xml`.

## Release (local)

```bash
FORETYPE_VERSION=0.2.0 \
FORETYPE_SIGN_IDENTITY="Developer ID Application: Jane Doe (TEAMID1234)" \
FORETYPE_NOTARY_PROFILE=foretype-notary \
FORETYPE_SPARKLE=1 \
FORETYPE_FEED_URL=https://OWNER.github.io/foretype/appcast.xml \
FORETYPE_SPARKLE_PUBLIC_KEY=... \
SPARKLE_BIN=/path/to/Sparkle/bin \
scripts/package-mac.sh
```

This produces:

- `build/Foretype-0.2.0.dmg`: app signed inside-out with the hardened runtime and a secure
  timestamp, DMG signed, notarized and stapled, verified with `spctl`;
- `build/Foretype-0.2.0.dmg.sha256`;
- `build/appcast-item.xml`: the `<item>` to add to `appcast.xml`, with the EdDSA signature;
- `build/foretype.rb`: the Homebrew cask with version and checksum filled in.

Then upload the DMG to a GitHub release tagged `v0.2.0`, add the appcast item to
`appcast.xml` on `gh-pages`, and submit the cask (or keep it in your own tap).

## Release (CI)

`.github/workflows/release.yml` does the same on a pushed `v*` tag. Add the repository
secrets it lists (certificate as base64 `.p12` and its password, the identity name, notary
Apple ID / team ID / app-specific password, Sparkle private and public keys). The workflow
creates the GitHub release; adding the appcast item is still a manual step. The workflow has
not been run yet.

## Without a Developer ID

`scripts/package-mac.sh` with no environment builds an ad-hoc-signed, unnotarized DMG. It
runs on your own Mac, but Gatekeeper blocks it on others (right-click → Open, or
`xattr -dr com.apple.quarantine /Applications/Foretype.app`), and the Accessibility grant
has to be renewed after every update because ad-hoc signatures change with each build.

## Testing updates locally (no Developer ID needed)

```bash
scripts/sparkle-local-test.sh            # builds 0.0.1 and 0.0.2, serves the feed on 127.0.0.1:8977
open "$WORK/Foretype.app"                # the path it prints; menu-bar icon → Check for Updates…
```

The script signs the 0.0.2 DMG with a throwaway Ed25519 key (`tools/sparkle/edkey.swift`,
CryptoKit; nothing goes into the keychain), writes `appcast.xml` and serves both over plain
HTTP; `build-mac.sh` adds an ATS local-networking exception only when the feed URL is on
127.0.0.1 or localhost. Sparkle then downloads the DMG, logs "OK: EdDSA signature is
correct for update", replaces the app in place and relaunches it. With ad-hoc builds it also
logs "Code signature of the new version doesn't match the old version": ad-hoc signatures
are tied to each build's cdhash, so only the EdDSA check applies; Developer ID builds pass
both. The test app shares the bundle ID `dev.foretype.Foretype`, so back up and restore its
defaults (`defaults export` / `import`) if you also use a development build.

Verified on 2026-10-20 (macOS 27.0.1, Sparkle 2.10.0): 0.0.1 → 0.0.2 installed and
relaunched; a second check then reported "You're up to date!".

Ad-hoc builds are signed without the hardened runtime: the runtime enforces library
validation, and ad-hoc signatures carry no Team ID, so an ad-hoc app with Sparkle.framework
embedded failed to launch ("Library missing", found by this test). Developer ID builds keep
the hardened runtime, which notarization requires.

## Checks before tagging

```bash
cargo test --release --manifest-path core/Cargo.toml
scripts/build-mac.sh && mac/.build/release/Foretype --font-selftest && mac/.build/release/Foretype --ocr-selftest
FORETYPE_MODEL=/path/Qwen3-1.7B-Base.Q4_K_M.gguf scripts/e2e-textedit.sh
FORETYPE_MODEL=/path/Qwen3-1.7B-Base.Q4_K_M.gguf scripts/e2e-terminal.sh
core/target/release/ft-replay /path/Qwen3-1.7B-Base.Q4_K_M.gguf --corpus eval/corpus.jsonl
```

Publish the replay numbers in the release notes.
