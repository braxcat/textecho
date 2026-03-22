# TextEcho: Distribution & App Store Prep Plan

**Created:** 2026-03-22
**Status:** Planning

## Executive Summary

TextEcho uses two APIs that are **incompatible with the macOS App Store sandbox**:

1. **CGEventTap** (InputMonitor.swift) — system-wide keyboard/mouse interception for global hotkeys
2. **IOKit HID** (StreamDeckPedalMonitor.swift) — direct USB access for Stream Deck Pedal

These are core features. Removing them would gut the app. The realistic distribution strategy is:

| Path | Features | Effort | Timeline |
|------|----------|--------|----------|
| **Phase 1: Signed DMG** | Full features, notarized | Medium | 1-2 days |
| **Phase 2: App Store (optional)** | Reduced features (no global hotkeys, no pedal) | Large | Future |

**Recommendation:** Ship Phase 1 (signed DMG). Phase 2 only if there's demand.

---

## Phase 1: Signed DMG Distribution (Recommended)

Keep all features. Sign and notarize so users don't get Gatekeeper warnings.

### Prerequisites

- [ ] **Apple Developer Program** ($99/year) — enroll at [developer.apple.com](https://developer.apple.com/programs/)
  - Use your Apple ID (personal or BTW Enterprise)
  - Takes up to 48 hours for approval
- [ ] **Create signing identity** — after enrollment:
  - Xcode → Settings → Accounts → add your Apple ID
  - Xcode creates "Developer ID Application" certificate automatically
  - Or via CLI: `xcrun security find-identity -v -p codesigning`

### Step 1: Entitlements File

Create `mac_app/TextEcho.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- NOT sandboxed — required for CGEventTap and IOKit HID -->
    <key>com.apple.security.app-sandbox</key>
    <false/>

    <!-- Hardened Runtime (required for notarization) -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

**Why no sandbox?** CGEventTap requires Accessibility permission which is sandbox-incompatible. IOKit HID requires direct USB access. These are the two features that make TextEcho useful — removing them defeats the purpose.

**Hardened Runtime** is still enabled (required for notarization). The `disable-library-validation` entitlement is needed because WhisperKit loads Core ML models dynamically.

### Step 2: Update Build Script

Modify `build_native_app.sh` to:

1. Accept a `--sign` flag with the Developer ID identity
2. Use hardened runtime (`--options runtime`)
3. Apply entitlements
4. Embed the entitlements in the binary

```bash
# Replace ad-hoc signing (current):
#   codesign --force --deep --sign - "$APP_DIR"
# With:
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements mac_app/TextEcho.entitlements \
        "$APP_DIR"
else
    # Fallback to ad-hoc for dev builds
    codesign --force --deep --sign - "$APP_DIR"
fi
```

Usage: `./build_native_app.sh --sign "Developer ID Application: Braxton Bragg (TEAMID)"`

### Step 3: Notarization Script

Create `notarize.sh`:

```bash
#!/bin/bash
set -e

APP_PATH="dist/TextEcho.app"
ZIP_PATH="dist/TextEcho.zip"
BUNDLE_ID="com.textecho.app"

echo "==> Zipping app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service..."
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "==> Done! App is signed and notarized."
```

**Setup required:**
- Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com/account/manage) → App-Specific Passwords
- Store as: `APPLE_ID`, `TEAM_ID`, `APP_SPECIFIC_PASSWORD` environment variables
- Or use Keychain: `xcrun notarytool store-credentials "TextEcho" --apple-id ... --team-id ... --password ...`

### Step 4: Update DMG Build

Modify `build_native_dmg.sh` to use the signed + notarized app and also sign the DMG itself:

```bash
# After creating the DMG:
codesign --sign "$SIGN_IDENTITY" dist/TextEcho.dmg
xcrun notarytool submit dist/TextEcho.dmg --keychain-profile "TextEcho" --wait
xcrun stapler staple dist/TextEcho.dmg
```

### Step 5: Version Bump

Update `build_native_app.sh` Info.plist values:
- `CFBundleShortVersionString` → `2.1` (or whatever the next version is)
- `CFBundleVersion` → increment (must be unique per submission)

### Step 6: GitHub Release

```bash
# Tag and release
git tag -a v2.1.0 -m "v2.1.0: Themes, Setup Wizard, signed distribution"
git push origin v2.1.0

# Create release with DMG
gh release create v2.1.0 dist/TextEcho.dmg \
    --title "TextEcho v2.1.0" \
    --notes "Signed and notarized. See CHANGELOG for details."
```

### Step 7: CI Enhancement (Optional)

Add a release workflow that builds, signs, notarizes, and uploads the DMG on tag push:

`.github/workflows/release.yml`:
- Trigger: `on: push: tags: ['v*']`
- Steps: checkout → build → sign → notarize → create GitHub Release → upload DMG
- Secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `TEAM_ID`, `APP_SPECIFIC_PASSWORD`

This is nice-to-have — you can do the first release manually.

### Phase 1 Checklist

| Step | Task | Depends On |
|------|------|-----------|
| 0 | Enroll in Apple Developer Program | — |
| 1 | Create entitlements file | — |
| 2 | Update build script with `--sign` flag | Step 0 |
| 3 | Create notarization script | Step 0 |
| 4 | Update DMG build to sign + notarize | Steps 2, 3 |
| 5 | Version bump | — |
| 6 | Build, sign, notarize, test on a clean Mac | Steps 1-5 |
| 7 | Create GitHub Release with DMG | Step 6 |
| 8 | (Optional) CI release workflow | Step 7 |

---

## Phase 2: App Store (Optional, Future)

Only pursue this if there's user demand. Requires significant feature compromises.

### What Changes

| Feature | Current | App Store Version |
|---------|---------|-------------------|
| Global hotkeys | CGEventTap (system-wide) | App-scoped only — must activate app first |
| Stream Deck Pedal | IOKit HID (direct USB) | Removed entirely |
| Auto-start | LaunchAgent (launchd) | Login Items framework (SMAppService) |
| Text paste | CGEvent keystroke injection | NSPasteboard only (user must Cmd+V manually) |
| Model download | Runtime (~1.6GB) | Pre-bundle OR on-demand with clear messaging |

### Required Changes

1. **New InputMonitor variant** — Replace `CGEventTap` with `NSEvent.addGlobalMonitorForEvents` (limited: read-only, no event modification, can't synthesize keystrokes)
2. **Remove StreamDeckPedalMonitor** — No equivalent sandbox-safe API exists
3. **Replace TextInjector** — Can't synthesize Cmd+V in sandbox; must use `NSPasteboard` and tell user to paste
4. **Add App Sandbox entitlement** — `com.apple.security.app-sandbox = true`
5. **Add network entitlement** — `com.apple.security.network.client = true` (for model download)
6. **Add microphone entitlement** — `com.apple.security.device.audio-input = true`
7. **Replace LaunchdManager** — Use `SMAppService` (macOS 13+) for Login Items
8. **Xcode project** — App Store submissions require an Xcode project (not just SwiftPM); create `TextEcho.xcodeproj` wrapping the SwiftPM package
9. **App Store Connect** — Create app listing, screenshots, description, privacy policy

### Reality Check

The App Store version would be a **significantly worse product**:
- No global hotkeys = must click the menu bar icon or switch to TextEcho before recording
- No pedal support = power users lose hands-free workflow
- No auto-paste = extra Cmd+V step every time
- ~1.6GB app size if model is bundled

**This is why most dictation apps (Whisper Transcription, Superwhisper, MacWhisper) distribute outside the App Store.** They need the same Accessibility + Input Monitoring permissions.

---

## Comparable Apps & Their Distribution

| App | Distribution | Price | Global Hotkeys | Sandbox |
|-----|-------------|-------|----------------|---------|
| **Superwhisper** | Direct (website) | $8/mo | Yes (CGEventTap) | No |
| **MacWhisper** | Direct + App Store | $15+ | Direct only | App Store version limited |
| **Whisper Transcription** | App Store | $5 | No (app-scoped only) | Yes |
| **TextEcho** | Direct (DMG) | Free | Yes | No |

MacWhisper is the interesting case — they ship two versions. The App Store version has fewer features.

---

## Recommended Order of Operations

1. **Now:** Enroll in Apple Developer Program (if not already)
2. **While waiting for approval:** Create entitlements file, update build scripts
3. **Once approved:** Build → sign → notarize → test on a clean Mac
4. **Release:** Tag, create GitHub Release with signed DMG
5. **Later (if demand):** Consider App Store variant with reduced features

---

## Cost Summary

| Item | Cost | Frequency |
|------|------|-----------|
| Apple Developer Program | $99 | Annual |
| Code signing certificate | Included | With program |
| Notarization | Free | Per build |
| App Store listing | Free | One-time |
| **Total Year 1** | **$99** | |
