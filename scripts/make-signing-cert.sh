#!/usr/bin/env bash
# Creates "Foretype", the self-signed code-signing identity that local builds and published
# releases are signed with, so installs keep their Accessibility and Screen Recording grants
# across rebuilds and updates.
#
# macOS ties a privacy grant to the app's designated requirement. An ad-hoc signature's
# requirement is the exact build's cdhash, so every rebuild or update loses the grant (tccd:
# "Failed to match existing code requirement"). Signed with this identity the requirement is
# `identifier "dev.foretype.Foretype" and certificate leaf = H"<this certificate>"`, the same
# for every build. Local builds and releases share one certificate because they share the
# bundle ID: two certificates would keep invalidating each other's grant on the same Mac.
#
# Run it yourself, once. It adds one certificate and its private key to your login keychain
# (no trust settings, no admin password) and writes a PKCS#12 backup of them: the release
# workflow needs that file as a GitHub secret, and without it releases can't be signed with
# the same identity again (every user would have to grant the permissions once more). It
# prints every command and asks before running them.
#
#   scripts/make-signing-cert.sh [BACKUP.p12]   create the identity (backup default: ~/Foretype-signing.p12)
#   scripts/make-signing-cert.sh --import FILE  install an existing backup (another Mac, a new keychain)
#   scripts/make-signing-cert.sh --remove       delete the identity (certificate and private key)
#
# Environment:
#   FORETYPE_SIGN_KEYCHAIN  A keychain file to use instead of the login keychain (testing and
#                           CI; the same variable makes build-mac.sh look there).
#   FORETYPE_P12_PASSWORD   Passphrase for --import (asked for otherwise).
#   FORETYPE_YES=1          Don't ask before running (tests).
set -euo pipefail
NAME="Foretype"
KEYCHAIN="${FORETYPE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
REPO="DaraSingh1998/foretype"
# macOS's LibreSSL: its PKCS#12 encryption is one `security import` reads (OpenSSL 3's
# default AES/PBKDF2 one fails with "MAC verification failed").
OPENSSL=/usr/bin/openssl

existing() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }'
}

confirm() {
  [ "${FORETYPE_YES:-0}" = 1 ] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing changed."; exit 1 ;; esac
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

import_p12() {  # file passphrase
  printf '+ %s\n' "security import $1 -k $KEYCHAIN -f pkcs12 -x -P <passphrase> -T /usr/bin/codesign"
  security import "$1" -k "$KEYCHAIN" -f pkcs12 -x -P "$2" -T /usr/bin/codesign
}

after_install() {
  local hash
  hash="$(existing)"
  [ -n "$hash" ] || { echo "The identity was imported but security find-identity doesn't list it."; exit 1; }
  cat <<NEXT

Installed: $hash "$NAME".

  scripts/build-mac.sh                   now signs with "$NAME"
  codesign -dr - build/Foretype.app      designated => identifier "dev.foretype.Foretype"
                                         and certificate leaf = H"$(echo "$hash" | tr 'A-F' 'a-f')"

Grants made for an ad-hoc build don't carry over, so renew them one last time: in System
Settings > Privacy & Security, select Foretype under Accessibility and under Screen Recording,
remove it with −, and add the app again with + (or run
"tccutil reset Accessibility dev.foretype.Foretype" and
"tccutil reset ScreenCapture dev.foretype.Foretype", then allow both when the app asks).
After that, rebuilds and updates keep them.

If macOS asks whether codesign may use the key "$NAME", enter your login password and click
Always Allow.
NEXT
}

[ -f "$KEYCHAIN" ] || { echo "keychain not found: $KEYCHAIN"; exit 1; }

case "${1:-}" in
  --remove)
    HASH="$(existing)"
    [ -n "$HASH" ] || { echo "No \"$NAME\" identity in $KEYCHAIN."; exit 0; }
    echo "This deletes the \"$NAME\" certificate ($HASH) and its private key from"
    echo "$KEYCHAIN:"
    echo
    echo "  security delete-identity -Z $HASH \"$KEYCHAIN\""
    echo
    echo "Builds go back to ad-hoc signing, and the grants of builds signed with it stop matching."
    echo "Releases can still be signed from the backup (.p12) if you kept it."
    confirm "Delete it?"
    run security delete-identity -Z "$HASH" "$KEYCHAIN"
    exit 0
    ;;
  --import)
    FILE="${2:?usage: $0 --import FILE.p12}"
    [ -f "$FILE" ] || { echo "not found: $FILE"; exit 1; }
    HASH="$(existing)"
    [ -z "$HASH" ] || { echo "\"$NAME\" is already in $KEYCHAIN ($HASH)."; exit 0; }
    PASS="${FORETYPE_P12_PASSWORD:-}"
    if [ -z "$PASS" ]; then read -r -s -p "Passphrase of $FILE: " PASS; echo; fi
    echo "This imports \"$NAME\" from $FILE into $KEYCHAIN (private key non-extractable,"
    echo "usable by /usr/bin/codesign without asking)."
    confirm "Import it?"
    import_p12 "$FILE" "$PASS"
    after_install
    exit 0
    ;;
  -*) echo "usage: $0 [BACKUP.p12] | --import FILE.p12 | --remove"; exit 2 ;;
esac

BACKUP="${1:-$HOME/Foretype-signing.p12}"
HASH="$(existing)"
if [ -n "$HASH" ]; then
  echo "\"$NAME\" is already in $KEYCHAIN ($HASH). scripts/build-mac.sh uses it."
  exit 0
fi
[ ! -e "$BACKUP" ] || { echo "$BACKUP already exists. Install it with: $0 --import $BACKUP"; exit 1; }

cat <<PLAN
This creates the self-signed code-signing identity "$NAME" that Foretype builds and
releases are signed with.

  1. In a new temporary folder (mktemp -d), make a 2048-bit RSA key and a self-signed
     certificate for it: CN=$NAME, code signing only, valid 20 years.
       $OPENSSL req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 -config <temp>/cert.cnf \\
           -keyout <temp>/key.pem -out <temp>/cert.pem
  2. Bundle them into a PKCS#12 file protected by a random passphrase (openssl rand).
       $OPENSSL pkcs12 -export -inkey <temp>/key.pem -in <temp>/cert.pem -name "$NAME" \\
           -out <temp>/identity.p12 -passout env:FORETYPE_P12_PASS
  3. Import it into your keychain. The private key is marked non-extractable, and only
     /usr/bin/codesign may use it without asking.
       security import <temp>/identity.p12 -k "$KEYCHAIN" -f pkcs12 -x \\
           -P <passphrase> -T /usr/bin/codesign
  4. Save the PKCS#12 file as the backup $BACKUP (readable only by you), print its
     passphrase once, and delete the temporary folder.

Nothing else changes: no trust settings, no admin password. Keychain Access will show the
certificate as "not trusted"; that is expected and doesn't matter for code signing.
Undo with: scripts/make-signing-cert.sh --remove
PLAN
echo
confirm "Create it?"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
PASS="$("$OPENSSL" rand -hex 16)"
export FORETYPE_P12_PASS="$PASS"
run "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>"$TMP/req.log" || { cat "$TMP/req.log"; exit 1; }
run "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout env:FORETYPE_P12_PASS
unset FORETYPE_P12_PASS
import_p12 "$TMP/identity.p12" "$PASS"
(umask 077 && cp "$TMP/identity.p12" "$BACKUP")
echo "+ cp <temp>/identity.p12 $BACKUP"
run rm -rf "$TMP"
after_install

cat <<BACKUP_NOTE

Backup: $BACKUP
Passphrase: $PASS

Store both in your password manager now; the passphrase isn't saved anywhere else. Releases
are signed with this identity by the GitHub workflow, which needs them as secrets:

  base64 -i "$BACKUP" | gh secret set SIGNING_P12 --repo $REPO
  gh secret set SIGNING_P12_PASSWORD --repo $REPO      (paste the passphrase when asked)

Then delete $BACKUP from this folder. If the backup is lost, releases can't keep the
identity: every user would have to grant Accessibility and Screen Recording once more.
BACKUP_NOTE
