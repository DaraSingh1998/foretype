#!/usr/bin/env bash
# Builds axprobe and installs a TCC-grantable copy at bin/axprobe.
# SwiftPM's linker-signed ad-hoc signature (flags adhoc,linker-signed) cannot be matched by
# tccd ("Failed to match existing code requirement"), so a granted toggle never takes effect.
# A full ad-hoc signature fixes that. The grant is still tied to the cdhash, so re-grant
# Accessibility after every run of this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
mkdir -p bin
cp .build/release/axprobe bin/axprobe
codesign --force --sign - --identifier dev.phase0.axprobe bin/axprobe
codesign -dvvv bin/axprobe 2>&1 | grep -E "CDHash=|flags"
