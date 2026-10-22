#!/usr/bin/env bash
# Publishes a new version of Foretype: sets the version, dates the CHANGELOG, commits, tags
# v<version> and, after asking, pushes main and the tag. GitHub Actions
# (.github/workflows/release.yml) then builds, signs and publishes the release, and installed
# copies find it at their next daily check and update themselves.
#
#   scripts/release.sh 0.1.1
#
# Needs: a clean main that contains origin/main, a non-empty "## Unreleased" section in
# CHANGELOG.md, and a version higher than core/Cargo.toml's (or equal to it while no tag
# exists for it, for the first release).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="DaraSingh1998/foretype"
cd "$ROOT"
fail() { echo "release: $*" >&2; exit 1; }

V="${1:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh X.Y.Z"
[ "$(git branch --show-current)" = main ] || fail "check out main first"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || fail "main is behind origin/main: pull first"
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && fail "tag v$V already exists"
git ls-remote --exit-code --tags origin "refs/tags/v$V" >/dev/null 2>&1 && fail "tag v$V already exists on origin"

OLD="$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)"
if [ "$V" != "$OLD" ]; then
  [ "$(printf '%s\n%s\n' "$OLD" "$V" | sort -V | tail -1)" = "$V" ] || fail "$V is lower than the current version $OLD"
fi
NOTES="$(awk '/^## Unreleased/ {f=1; next} /^## / {if (f) exit} f' CHANGELOG.md | grep -v '^[[:space:]]*$' || true)"
[ -n "$NOTES" ] || fail "CHANGELOG.md has no entries under '## Unreleased'"

echo "Running the core tests..."
MACOSX_DEPLOYMENT_TARGET=14.0 cargo test --release --quiet --manifest-path core/Cargo.toml >/dev/null \
  || fail "core tests failed (cargo test --release --manifest-path core/Cargo.toml)"

python3 - "$V" <<'PY'
import re, sys, datetime
v = sys.argv[1]
def sub(path, pattern, repl):
    s = open(path, encoding="utf-8").read()
    t, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    assert n == 1, (path, pattern)
    open(path, "w", encoding="utf-8").write(t)
sub("core/Cargo.toml", r'^version = ".*"$', f'version = "{v}"')
sub("core/Cargo.lock", r'(^name = "foretype-core"\nversion = )".*"$', rf'\g<1>"{v}"')
sub("CHANGELOG.md", r"^## Unreleased$", f"## Unreleased\n\n## {v} ({datetime.date.today().isoformat()})")
PY
git add core/Cargo.toml core/Cargo.lock CHANGELOG.md
git commit -q -m "Release $V"
git tag -a "v$V" -m "Foretype $V"

cat <<SUMMARY

Committed "Release $V" ($(git rev-parse --short HEAD), build $(git rev-list --count HEAD)) and tagged v$V.
Pushing publishes it: GitHub Actions builds, signs and releases Foretype $V, and every
installed copy updates itself within a day.

SUMMARY
read -r -p "Push main and v$V to origin? [y/N] " answer
case "$answer" in
  y|Y|yes|YES) ;;
  *)
    echo "Not pushed. Later: git push origin main v$V"
    echo "Or undo: git tag -d v$V && git reset --hard HEAD~1"
    exit 0
    ;;
esac
git push origin main "v$V"
echo
# GitHub doesn't always start a workflow for a pushed tag (v0.1.0's push started none). Started
# by hand on the tag, the workflow does the same full release.
echo "Waiting for the release workflow to start..."
STARTED=""
for _ in $(seq 12); do
  sleep 5
  STARTED="$(gh run list --repo "$REPO" --workflow release.yml --branch "v$V" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  [ -n "$STARTED" ] && break
done
if [ -z "$STARTED" ]; then
  echo "No run started for the tag push; starting the release workflow on v$V by hand."
  gh workflow run release.yml --repo "$REPO" --ref "v$V"
fi
echo "Pushed. Follow the build: gh run watch --repo $REPO (or https://github.com/$REPO/actions)"
echo "Release page when done: https://github.com/$REPO/releases/tag/v$V"
