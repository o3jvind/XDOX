# Releasing XDOX

How to cut a signed, notarised, downloadable release of XDOX and publish it on
GitHub. You build the app in the Xojo IDE; `build-release.sh` signs, notarises,
and packages what the IDE produced. All credentials are entered interactively —
nothing sensitive is committed to this repo.

## One-time setup

- An **Apple Developer** account.
- A **Developer ID Application** certificate in your login keychain.
- An **app-specific password** for notarisation: create one at
  <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords.
- Xojo IDE 2026r1+ with your MBS licence in the keychain (for the build itself).

## Why the entitlements file exists

XDOX bundles third-party binaries that Apple did not sign: the MBS plugin
dylibs (`Contents/Frameworks/MBS_*.dylib`) and the `llama-server` executable
(`Contents/Resources/llama-server`). Under the **hardened runtime** (required
for notarisation) an app may not load unsigned/third-party libraries or spawn
such executables unless it declares it may. `XDOX.entitlements` does that — most
importantly `com.apple.security.cs.disable-library-validation`. This is **not** a
dispensation requested from Apple; the app declares its own needs and the notary
service accepts it.

## Release steps

1. **Bump the version** in the Xojo IDE if needed (Project → Build Settings →
   the macOS target → *Version* fields). This becomes the app's
   `CFBundleShortVersionString`, which the release script reads back. Move
   the `CHANGELOG.md` entry for this version out of "Unreleased" (or add
   one) at the same time.

2. **Run the release script:**

   ```bash
   ./build-release.sh
   ```

   It will, in order:
   - ask which Developer ID certificate to sign with, then prompt for your
     Apple ID, Team ID, and app-specific password (typed in, never stored),
   - run `./inject-secrets.sh` to embed MBS credentials so the app runs on
     machines without an MBS licence,
   - pause and ask you to build the **Release** target in the Xojo IDE (⌘B) —
     revert `SecretsBuiltin.xojo_code` to disk first if the project is open,
   - re-sign every embedded dylib and `llama-server`, then the app, with the
     hardened runtime + `XDOX.entitlements`,
   - submit to Apple's notary service, wait, and staple the ticket,
   - produce `XDOX-<version>.zip`,
   - run `./restore-secrets.sh` to put the empty stub back (guaranteed even if
     an earlier step fails).

3. **Verify** the stapled app is accepted (the script prints this; ideally also
   test on another Mac):

   ```bash
   spctl --assess --type exec --verbose "Builds - XDOX/macOS ARM 64 bit/XDOX.app"
   ```

   You want `accepted` / `source=Notarized Developer ID`.

4. **Tag and publish the GitHub release** (below).

## Tagging and publishing

A *tag* is a permanent, named bookmark on one commit (e.g. `v0.1.0`). A *GitHub
Release* is a page built on that tag where you attach the downloadable zip.
Tags and releases only **add** to the repo — they never rewrite history, so this
is safe.

Using the GitHub CLI (`gh`):

```bash
# from the repo root, on the commit you want to release
gh release create v0.1.0 XDOX-0.1.0.zip \
  --title "XDOX 0.1.0" \
  --notes "First public build. Signed and notarised — no MBS licence needed to run. Requires macOS on Apple Silicon and the Xojo IDE's local documentation installed."
```

That one command creates the tag `v0.1.0`, makes the release page, and uploads
the zip as a downloadable asset.

To do it by hand instead: the repo's GitHub page → **Releases** → *Draft a new
release* → choose or create the tag → drag the zip into the assets box → write
notes → **Publish**.

## Versioning convention

Use `vMAJOR.MINOR.PATCH` tags (`v0.1.0`, `v0.2.0`, …). Pre-1.0 the schema has no
migrations, so a release that bumps `DBHelper.kSchemaVersion` wipes the user's
local database and notes on first launch — call that out in the release notes.
