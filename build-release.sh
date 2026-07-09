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
# Nested code must be signed BEFORE the outer app, or the app signature won't
# cover it and notarisation fails. We sign EVERY Mach-O binary anywhere in the
# bundle — not just Frameworks/*.dylib — because Xojo ships its core
# XojoFramework as a .framework bundle (no .dylib suffix, nested a level deeper)
# and there may be other executables in Resources (e.g. llama-server). Missing
# even one binary makes Apple reject the whole submission.

print "[2/6] Signing .framework bundles…"
# Frameworks are signed as bundles (sign the bundle dir, not the inner binary).
find "$APP_PATH/Contents/Frameworks" -type d -name "*.framework" -print0 2>/dev/null | \
while IFS= read -r -d '' fw; do
    codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$fw"
done

print "[2/6] Signing every embedded Mach-O binary (MBS plugins, llama-server, …)…"
# Any regular file that is actually Mach-O code, skipping anything already
# inside a .framework (handled above). --force re-signs; harmless if repeated.
find "$APP_PATH/Contents" -type f -print0 2>/dev/null | \
while IFS= read -r -d '' f; do
    case "$f" in
        *.framework/*) continue ;;   # covered by the framework signing above
    esac
    if file "$f" 2>/dev/null | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$f"
    fi
done

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
# --wait returns 0 even when the result is "Invalid", so capture the submission
# id and check the status explicitly — otherwise we'd try to staple a ticket
# Apple never issued (the "Record not found" / Error 65 failure mode).
SUBMIT_OUT=$(xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait \
    --timeout 30m 2>&1)
print "$SUBMIT_OUT"

SUBMISSION_ID=$(print "$SUBMIT_OUT" | grep -Eo 'id: [0-9a-f-]+' | head -1 | awk '{print $2}')
NOTARY_STATUS=$(print "$SUBMIT_OUT" | grep -E '^\s*status:' | tail -1 | awk '{print $2}')

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    print "\n✗ Notarisation did not succeed (status: ${NOTARY_STATUS:-unknown})."
    if [[ -n "$SUBMISSION_ID" ]]; then
        print "\nApple's rejection log:"
        xcrun notarytool log "$SUBMISSION_ID" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" || true
    fi
    print "\nFix the issues above and re-run. (Secrets stub already restored.)"
    exit 1
fi

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
