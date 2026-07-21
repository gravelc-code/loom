#!/bin/bash
# Build, sign, notarize and staple loom.app for direct distribution.
#
# Prereqs (one-time):
#   - "Developer ID Application" cert in your login keychain
#       (Xcode > Settings > Accounts > Manage Certificates)
#   - a stored notarytool credential profile named $NOTARY_PROFILE:
#       xcrun notarytool store-credentials loom-notary \
#         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-pw>
#
# Usage: ./package.sh
#
# Everything is built and signed OUTSIDE Dropbox (in $SCRATCH) because Dropbox's
# file-provider extended attributes break codesign. The finished, stapled bundle
# and a distributable zip are copied back into the repo root at the end.
#
# No personal identifiers are hardcoded: the signing identity is discovered from
# the keychain, so this file is safe to commit.

set -euo pipefail

# ---- config ----------------------------------------------------------------
NOTARY_PROFILE="loom-notary"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

# Discover the Developer ID Application identity (override with SIGN_ID=... if you
# have more than one). Team ID is derived from it — nothing personal lives here.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 \
  | sed -E 's/^[^"]*"([^"]+)".*/\1/')}"
[ -n "$SIGN_ID" ] || { echo "error: no 'Developer ID Application' identity in keychain"; exit 1; }
TEAM_ID="$(printf '%s' "$SIGN_ID" | sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/')"
echo "==> signing as: $SIGN_ID"

REPO="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HOME/.cache/loom-build"          # swift build products (outside Dropbox)
STAGE="$SCRATCH/stage"                      # bundle assembled here (outside Dropbox)
APP="$STAGE/loom.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/packaging/Info.plist")"
ZIP="loom-${VERSION}.zip"

# ---- 1. build release binary ----------------------------------------------
echo "==> swift build (release)"
swift build -c release --scratch-path "$SCRATCH" --product LoomApp
BIN="$SCRATCH/release/LoomApp"

# ---- 2. assemble the .app bundle ------------------------------------------
echo "==> assembling loom.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/loom"
cp "$REPO/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/packaging/loom.icns" "$APP/Contents/Resources/loom.icns"
xattr -cr "$APP"

# ---- 3. sign (hardened runtime + secure timestamp) ------------------------
echo "==> codesign"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ---- 4. pre-flight: catch signing mistakes locally before the slow upload --
echo "==> pre-flight signature checks"
info="$(codesign -dvvv "$APP" 2>&1)"
echo "$info" | grep -q 'flags=.*runtime' \
  || { echo "FAIL: hardened runtime not enabled"; exit 1; }
echo "$info" | grep -q 'Timestamp=' \
  || { echo "FAIL: no secure timestamp (would fail notarization)"; exit 1; }
echo "$info" | grep -q "Authority=Developer ID Application:.*(${TEAM_ID})" \
  || { echo "FAIL: not signed with a Developer ID cert for team ${TEAM_ID}"; exit 1; }
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "FAIL: get-task-allow set (debug entitlement) — not allowed for distribution"; exit 1
fi
echo "    ok: hardened runtime + secure timestamp + Developer ID($TEAM_ID), no get-task-allow"

# ---- 5. notarize (dumps Apple's log automatically if it fails) ------------
echo "==> notarize (this waits for Apple)"
ditto -c -k --keepParent "$APP" "$STAGE/$ZIP"
set +e
submit_out="$(xcrun notarytool submit "$STAGE/$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
submit_rc=$?
set -e
echo "$submit_out"
sub_id="$(printf '%s\n' "$submit_out" | awk '/ id: /{print $2; exit}')"
if [ $submit_rc -ne 0 ] || ! printf '%s\n' "$submit_out" | grep -q 'status: Accepted'; then
  echo "!! notarization did not succeed — fetching Apple's log:"
  [ -n "$sub_id" ] && xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE" || true
  exit 1
fi

# ---- 6. staple + verify ---------------------------------------------------
echo "==> staple"
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"

# ---- 7. deliver: stapled app + zip back into repo -------------------------
echo "==> copying artifacts into repo"
rm -rf "$REPO/loom.app"
ditto "$APP" "$REPO/loom.app"                    # ditto preserves the signature
ditto -c -k --keepParent "$REPO/loom.app" "$REPO/$ZIP"

echo ""
echo "Done. Distributable: $REPO/$ZIP"
