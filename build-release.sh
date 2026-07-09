#!/bin/zsh
set -e

# ---------------------------------------------------------------------------
# build-release.sh — sign, notarise, and package XDOX for distribution.
#
# XDOX is built in the Xojo IDE, so this script does NOT build the app. It
# embeds MBS credentials, waits for you to build in the IDE, then signs every
# bundled binary + the app with your Developer ID, notarises it with Apple, and
# produces a distributable zip. Credentials are entered interactively — nothing
# sensitive is stored in the repo.
#
# Requires: a Developer ID Application certificate, and an app-specific password
#           from appleid.apple.com.
# ---------------------------------------------------------------------------

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

APP_PATH="$SCRIPT_DIR/Builds - XDOX/macOS ARM 64 bit/XDOX.app"
ENTITLEMENTS="$SCRIPT_DIR/XDOX.entitlements"

print "\n=== XDOX — release builder ===\n"

# --- Pick signing certificate -----------------------------------------------

print "Available Developer ID Application certificates:"
APP_CERTS=("${(@f)$(security find-identity -v -p codesigning | grep "Developer ID Application" | sed 's/^ *[0-9]*) //')}")
if [[ ${#APP_CERTS} -eq 0 ]]; then
    print "No Developer ID Application certificate found — cannot sign for distribution."
    exit 1
fi
for i in {1..${#APP_CERTS}}; do
    print "  $i) ${APP_CERTS[$i]}"
done
print -n "Pick number: "
read APP_CERT_IDX
SIGN_IDENTITY="${APP_CERTS[$APP_CERT_IDX]}"
SIGN_HASH="${SIGN_IDENTITY%% *}"
print "Using: $SIGN_IDENTITY\n"

# --- Collect notarisation credentials ---------------------------------------

print -n "Apple ID (email): "
read APPLE_ID
print -n "Team ID (10-char code from developer.apple.com/account): "
read TEAM_ID
print -n "App-specific password (from appleid.apple.com): "
read -s APP_PASSWORD
print ""

# --- Inject MBS secrets and prompt for the IDE build ------------------------

print "\n[1/6] Injecting MBS credentials into SecretsBuiltin…"
./inject-secrets.sh

print "\n>>> Now build the RELEASE target in the Xojo IDE (⌘B)."
print ">>> If the project is open, revert SecretsBuiltin.xojo_code to disk first"
print ">>> so the injected credentials are compiled in."
print -n ">>> Press Enter here once the build has finished… "
read _

# Restore the empty stub the moment the build is captured, no matter what
# happens next — a trap guarantees it even if signing/notarisation fails.
trap './restore-secrets.sh >/dev/null 2>&1 || true' EXIT

if [[ ! -d "$APP_PATH" ]]; then
    print "Built app not found at:\n  $APP_PATH"
    print "Did the IDE build succeed? Aborting."
    exit 1
fi

# --- Read the version the IDE stamped into the app --------------------------

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
if [[ -z "$VERSION" ]]; then
    print -n "Could not read app version. Enter it manually (e.g. 0.1.0): "
    read VERSION
fi
print "\nPackaging XDOX $VERSION\n"

ZIP_PATH="$SCRIPT_DIR/XDOX-${VERSION}.zip"

# --- Sign every embedded binary, inside-out, then the app -------------------
# Nested code (dylibs, the llama-server executable) must be signed BEFORE the
# outer app, or the app signature won't cover them and notarisation fails.

print "[2/6] Signing embedded binaries (MBS plugins, llama-server)…"
# Frameworks/*.dylib and the llama-server executable in Resources.
find "$APP_PATH/Contents/Frameworks" -type f -name "*.dylib" -print0 2>/dev/null | \
while IFS= read -r -d '' lib; do
    codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$lib"
done

LLAMA="$APP_PATH/Contents/Resources/llama-server"
if [[ -f "$LLAMA" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$LLAMA"
fi

print "[3/6] Signing XDOX.app…"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_HASH" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
print "Signed with: $SIGN_IDENTITY"

# --- Notarise ---------------------------------------------------------------

print "\n[4/6] Zipping for notarisation…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

print "\n[5/6] Submitting to Apple's notary service (a few minutes)…"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait \
    --timeout 30m

print "\nStapling the notarisation ticket to the app…"
xcrun stapler staple "$APP_PATH"

# --- Repackage the stapled app ----------------------------------------------

print "\n[6/6] Repackaging the stapled app…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Gatekeeper sanity check on the stapled app.
print "\nGatekeeper assessment:"
spctl --assess --type exec --verbose "$APP_PATH" || true

print "\n✓ Done! Distributable zip:\n  $ZIP_PATH"
print "\nNext: create a GitHub release and attach the zip. See RELEASING.md.\n"
