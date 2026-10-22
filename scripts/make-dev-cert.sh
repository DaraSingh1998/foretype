#!/usr/bin/env bash
# Creates "Foretype Local Dev", a self-signed code-signing identity in your login keychain, so
# local builds keep their Accessibility and Screen Recording grants across rebuilds.
#
# macOS ties a privacy grant to the app's designated requirement. An ad-hoc signature's
# requirement is the exact build's cdhash, so every rebuild loses the grant (tccd: "Failed to
# match existing code requirement"). Signed with this identity the requirement is
# `identifier "dev.foretype.Foretype" and certificate leaf = H"<this certificate>"`, the same
# for every build. scripts/build-mac.sh signs with it whenever it is in the keychain.
#
# Run it yourself, once per Mac. It adds one certificate and its private key to your login
# keychain and changes nothing else: no trust settings, no admin password. It prints every
# command and asks before running them.
#
#   scripts/make-dev-cert.sh            create the identity
#   scripts/make-dev-cert.sh --remove   delete it again (certificate and private key)
#
# Environment:
#   FORETYPE_SIGN_KEYCHAIN  A keychain file to use instead of the login keychain (testing; the
#                           same variable makes build-mac.sh look there).
set -euo pipefail
NAME="Foretype Local Dev"
KEYCHAIN="${FORETYPE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# macOS's LibreSSL: its PKCS#12 encryption is one `security import` reads (OpenSSL 3's
# default AES/PBKDF2 one fails with "MAC verification failed").
OPENSSL=/usr/bin/openssl

existing() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }'
}

confirm() {
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

[ -f "$KEYCHAIN" ] || { echo "keychain not found: $KEYCHAIN"; exit 1; }

if [ "${1:-}" = "--remove" ]; then
  HASH="$(existing)"
  [ -n "$HASH" ] || { echo "No \"$NAME\" identity in $KEYCHAIN."; exit 0; }
  echo "This deletes the \"$NAME\" certificate ($HASH) and its private key from"
  echo "$KEYCHAIN:"
  echo
  echo "  security delete-identity -Z $HASH \"$KEYCHAIN\""
  echo
  echo "Builds go back to ad-hoc signing, and the grants of builds signed with it stop matching."
  confirm "Delete it?"
  run security delete-identity -Z "$HASH" "$KEYCHAIN"
  exit 0
fi
[ -z "${1:-}" ] || { echo "usage: $0 [--remove]"; exit 2; }

HASH="$(existing)"
if [ -n "$HASH" ]; then
  echo "\"$NAME\" is already in $KEYCHAIN ($HASH). scripts/build-mac.sh uses it."
  exit 0
fi

cat <<PLAN
This creates a self-signed code-signing identity named "$NAME" for local builds.

  1. In a new temporary folder (mktemp -d), make a 2048-bit RSA key and a self-signed
     certificate for it: CN=$NAME, code signing only, valid 10 years.
       $OPENSSL req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config <temp>/cert.cnf \\
           -keyout <temp>/key.pem -out <temp>/cert.pem
  2. Bundle them into a PKCS#12 file with a random one-time passphrase (openssl rand).
       $OPENSSL pkcs12 -export -inkey <temp>/key.pem -in <temp>/cert.pem -name "$NAME" \\
           -out <temp>/identity.p12 -passout env:FORETYPE_P12_PASS
  3. Import it into your keychain. The private key is marked non-extractable, and only
     /usr/bin/codesign may use it without asking.
       security import <temp>/identity.p12 -k "$KEYCHAIN" -f pkcs12 -x \\
           -P <random> -T /usr/bin/codesign
  4. Delete the temporary folder.

Nothing else changes: no trust settings, no admin password. Keychain Access will show the
certificate as "not trusted"; that is expected and doesn't matter for local builds.
Undo with: scripts/make-dev-cert.sh --remove
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
run "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>"$TMP/req.log" || { cat "$TMP/req.log"; exit 1; }
run "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout env:FORETYPE_P12_PASS
printf '+ %s\n' "security import $TMP/identity.p12 -k $KEYCHAIN -f pkcs12 -x -P <random> -T /usr/bin/codesign"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -f pkcs12 -x -P "$PASS" -T /usr/bin/codesign
unset FORETYPE_P12_PASS
run rm -rf "$TMP"

HASH="$(existing)"
[ -n "$HASH" ] || { echo "The identity was imported but security find-identity doesn't list it."; exit 1; }
cat <<NEXT

Done: $HASH "$NAME".

Next:
  scripts/build-mac.sh                   now signs with "$NAME"
  codesign -dr - build/Foretype.app      designated => identifier "dev.foretype.Foretype"
                                         and certificate leaf = H"$(echo "$HASH" | tr 'A-F' 'a-f')"

The existing grants belong to the last ad-hoc build, so renew them one last time: in System
Settings > Privacy & Security, select Foretype under Accessibility and under Screen Recording,
remove it with −, and add build/Foretype.app again with + (or run
"tccutil reset Accessibility dev.foretype.Foretype" and
"tccutil reset ScreenCapture dev.foretype.Foretype", then allow both when the app asks).
After that, rebuilds keep them.

If macOS asks whether codesign may use the key "$NAME",
enter your login password and click Always Allow.
NEXT
