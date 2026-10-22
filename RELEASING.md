# Releasing Foretype

Foretype ships as a DMG on GitHub Releases and updates itself with Sparkle 2. The DMG is
unsandboxed: Accessibility control, global event taps and typing into other apps rule out the
App Store sandbox. Releases are signed with a self-signed certificate named "Foretype", not an
Apple Developer ID, and are not notarized (D36).

How a release reaches people:

1. You run `scripts/release.sh X.Y.Z`. It bumps the version, dates the CHANGELOG, commits,
   tags `vX.Y.Z` and, after asking, pushes `main` and the tag.
2. `.github/workflows/release.yml` runs on the tag (macos-26 runner). It runs the core tests,
   builds the app with Sparkle, signs it with the "Foretype" identity, packages
   `Foretype-X.Y.Z.dmg`, signs the DMG with the EdDSA update key, writes `appcast.xml` and
   creates the GitHub release with the DMG, its `.sha256`, `appcast.xml` and `install.sh`.
3. Installed apps read `https://github.com/DaraSingh1998/foretype/releases/latest/download/appcast.xml`
   once a day, download the new DMG, check its EdDSA signature and its code signature (same
   certificate as the installed app), and install it once the user has been idle for five
   minutes with no suggestion on screen. The app then reopens by itself, and its
   Accessibility and Screen Recording grants still apply.

The repository has to be public: release downloads and the update feed must work without
signing in.

## One-time setup

1. **Signing identity.** Run `scripts/make-signing-cert.sh`. It creates the "Foretype"
   identity in your login keychain (local builds sign with it from then on) and writes a
   backup, `~/Foretype-signing.p12`, with a passphrase it prints once. Store both in your
   password manager, add them as repository secrets, then delete the file:

   ```bash
   base64 -i ~/Foretype-signing.p12 | gh secret set SIGNING_P12 --repo DaraSingh1998/foretype
   gh secret set SIGNING_P12_PASSWORD --repo DaraSingh1998/foretype
   ```

   On another Mac, install the same identity with `scripts/make-signing-cert.sh --import FILE.p12`.
   **If the backup is lost**, later releases can't carry the same certificate, and every user
   has to grant Accessibility and Screen Recording once more after updating.

2. **Update key.** The EdDSA key pair was made on 2026-10-22 with
   `swift tools/sparkle/edkey.swift generate ~/Foretype-sparkle.key`. Its public half is
   committed in `packaging/sparkle-public-key.txt` and built into every app as
   `SUPublicEDKey`. Store the private key file in your password manager, add it as a secret,
   then delete the file:

   ```bash
   gh secret set SPARKLE_PRIVATE_KEY --repo DaraSingh1998/foretype < ~/Foretype-sparkle.key
   ```

   **If this key is lost**, installed copies can't verify updates any more; everyone would
   have to download the next version by hand. Never commit it.

## Publishing a version

Before the first release, or after changing the workflow, do a dry run: `gh workflow run
release.yml --repo DaraSingh1998/foretype --ref main`. It builds, signs and packages exactly as
a release does and uploads the DMG and `appcast.xml` as a workflow artifact, but publishes
nothing.

1. Describe the changes under `## Unreleased` in `CHANGELOG.md` (the release notes are taken
   from there) and commit them on `main`.
2. Run the checks below.
3. `scripts/release.sh 0.1.1`, and answer `y` to push.
4. Follow the build with `gh run watch --repo DaraSingh1998/foretype`. The release appears at
   `https://github.com/DaraSingh1998/foretype/releases`.

GitHub sometimes starts no workflow for a pushed tag (it happened for v0.1.0). `release.sh`
waits a minute and otherwise starts the workflow on the tag by hand (`gh workflow run
release.yml --ref vX.Y.Z`), which does the same full release.

The workflow refuses a tag that isn't on `main`, a tag that doesn't match `core/Cargo.toml`, and a
build number (the commit count) that isn't higher than the previous release's, because Sparkle
only offers a higher one. If a run fails after the tag was pushed, fix it on `main` and
release the next patch version. Don't move a published tag.

## What people install

- **One line in Terminal**, no Gatekeeper step, because curl doesn't mark files as downloaded:
  `curl -fsSL https://github.com/DaraSingh1998/foretype/releases/latest/download/install.sh | bash`.
  The script checks the DMG's SHA-256, copies the app to `/Applications` (or `~/Applications`)
  and opens it.
- **Or the DMG**: drag Foretype to Applications and open it. macOS refuses the first time
  ("Apple could not verify…"). Click Done, open System Settings ▸ Privacy & Security, click
  **Open Anyway** next to the Foretype message, and confirm. This is needed only once; Sparkle
  updates aren't marked as downloaded, so they never ask again.

Then the setup window asks for Accessibility, offers Screen Recording and downloads a model.
Requirements: Apple silicon and macOS 14 or later.

## Testing updates locally

```bash
scripts/sparkle-local-test.sh
```

The script builds 0.0.1 and packages 0.0.2, both signed with a throwaway "Foretype" identity
in a temporary keychain and a throwaway EdDSA key, and serves the feed on 127.0.0.1:8977. It
then starts 0.0.1 with `FORETYPE_UPDATE_CHECK_NOW=1` and `FORETYPE_UPDATE_IDLE=0`, waits for
it to replace itself with 0.0.2 and relaunch, and prints PASS/FAIL. `build-mac.sh` adds an ATS
local-networking exception only when the feed URL is on 127.0.0.1 or localhost. The old app
runs with `FORETYPE_ONLY_APPS=none.invalid`, and the relaunched copy has no Accessibility
grant, so neither reads anything.

`scripts/install.sh` can be tried against a local folder too: set `FORETYPE_RELEASE_BASE` to
the folder's URL, `FORETYPE_INSTALL_DIR` to a scratch folder and `FORETYPE_NO_OPEN=1`.

Notes from the earlier ad-hoc tests: ad-hoc signatures are tied to each build's cdhash, so
Sparkle logs "Code signature of the new version doesn't match the old version" and only the
EdDSA check applies. The hardened runtime enforces library validation, and neither ad-hoc nor
self-signed signatures carry a Team ID, so such an app with Sparkle.framework embedded fails
to launch ("Library missing"). That is why only a Developer ID build gets the hardened runtime.

## Moving to a Developer ID later

With a paid Apple Developer account, set `FORETYPE_SIGN_IDENTITY="Developer ID Application:
Name (TEAMID)"` and `FORETYPE_NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) in
the workflow. `build-mac.sh` then adds the hardened runtime and a secure timestamp, and
`package-mac.sh` signs, notarizes and staples the DMG. The browser download then installs with
no Open Anyway step. The designated requirement changes with the certificate, so every user
grants Accessibility and Screen Recording once more after that update. Sparkle accepts the
switch because the EdDSA signature still verifies.

## Homebrew

`package-mac.sh` writes `build/foretype.rb` from `packaging/homebrew/foretype.rb.in`. It isn't
published yet: Homebrew quarantines casks, so an unnotarized app would still need Open Anyway.

## Checks before tagging

```bash
cargo test --release --manifest-path core/Cargo.toml
scripts/build-mac.sh && mac/.build/release/Foretype --font-selftest && mac/.build/release/Foretype --ocr-selftest
python3 scripts/check-localization.py
scripts/sparkle-local-test.sh
FORETYPE_MODEL=/path/Qwen3-1.7B-Base.Q4_K_M.gguf scripts/e2e-textedit.sh
core/target/release/ft-replay /path/Qwen3-1.7B-Base.Q4_K_M.gguf --corpus eval/corpus.jsonl
```

Put the replay numbers in the CHANGELOG entry.
