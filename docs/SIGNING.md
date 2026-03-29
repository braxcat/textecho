# TextEcho Code Signing & Distribution

TextEcho is distributed as a signed + notarized DMG (not via Mac App Store, because CGEventTap and IOKit HID require non-sandboxed execution).

## Architecture

```
Developer pushes tag v*.*.* → GitHub Actions (release.yml)
  ├── Ephemeral keychain created
  ├── Developer ID certificate imported from secret
  ├── App built + signed with hardened runtime
  ├── DMG created + signed
  ├── Notarized via App Store Connect API key
  ├── Notarization ticket stapled
  ├── Sigstore build provenance attested
  ├── GitHub Release created with DMG
  └── Ephemeral keychain destroyed
```

## Security Controls

| Control | Purpose |
|---------|---------|
| GitHub Environment (`release`) | Secrets only accessible after manual approval |
| Tag protection (`v*`) | Only admins can create release tags |
| Tag-on-main verification | Workflow verifies tagged commit is on main branch |
| Ephemeral keychain | Certificate exists only during build, destroyed in `always()` cleanup |
| SHA-pinned Actions | Immutable action references, not mutable tags |
| App Store Connect API key | Scoped to ASC only (not full Apple ID access) |
| CODEOWNERS | Workflow changes require @braxcat review |
| Sigstore attestation | Cryptographic proof of build provenance |
| Minimal entitlements | `audio-input` + `network.client` (for WhisperKit model download) — each entitlement weakens hardened runtime |

## Local Signing

For local development builds with proper signing:

```bash
export DEVELOPER_ID="Developer ID Application: Scott Braxton Bragg (DEVDSX2TPQ)"
./build_native_app.sh --sign
```

For local DMG with notarization:

```bash
export DEVELOPER_ID="Developer ID Application: Scott Braxton Bragg (DEVDSX2TPQ)"
export ASC_API_KEY_PATH="/path/to/AuthKey_KEYID.p8"
export ASC_KEY_ID="your-key-id"
export ASC_ISSUER_ID="your-issuer-uuid"
./build_native_app.sh --sign
./build_native_dmg.sh --sign
```

Without `--sign`, builds use ad-hoc signing (dev/debug only).

## Verify Signatures

```bash
# Check app signature
codesign -dv --verbose=4 dist/TextEcho.app

# Check entitlements
codesign -d --entitlements - dist/TextEcho.app

# Gatekeeper assessment
spctl --assess --type exec dist/TextEcho.app

# DMG notarization
spctl --assess --type open --context context:primary-signature dist/TextEcho.dmg

# Build provenance (Sigstore)
gh attestation verify TextEcho.dmg --owner braxcat
```

## Setting Up (First Time)

### 1. Developer ID Certificate

1. Open **Xcode > Settings > Accounts** — add your Apple ID
2. Select your team > **Manage Certificates** > **+** > **Developer ID Application**
3. Verify: `security find-identity -v -p codesigning | grep "Developer ID"`

### 2. App Store Connect API Key

1. Go to **appstoreconnect.apple.com > Users and Access > Integrations > Keys**
2. Generate API Key — name "TextEcho CI", role: **Developer**
3. Download the `.p8` file (one-time download)
4. Note the Key ID and Issuer ID

### 3. Export .p12 for GitHub

1. **Keychain Access** — find "Developer ID Application" certificate + private key
2. Select both > right-click > **Export 2 items** as .p12
3. Base64 encode: `base64 -i Certificates.p12 | pbcopy`

### 4. GitHub Configuration

All secrets go in the `release` environment (NOT repo-level):

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERT_BASE64` | Base64-encoded .p12 |
| `DEVELOPER_ID_CERT_PASSWORD` | .p12 export password |
| `SIGNING_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `APPLE_API_KEY_BASE64` | Base64-encoded .p8 file |
| `APPLE_API_KEY_ID` | Key ID from ASC |
| `APPLE_API_ISSUER_ID` | Issuer UUID from ASC |

## Credential Rotation

| Credential | Rotation | How |
|------------|----------|-----|
| Developer ID cert | When compromised or expired (5 years) | Xcode > Manage Certificates, update GitHub secret |
| ASC API key | Annually or when compromised | ASC > Keys > Revoke, generate new, update secrets |
| .p12 password | When rotating certificate | Set new password during export |

## Revoking

- **Developer ID cert:** developer.apple.com > Certificates > Revoke. All signed apps fail Gatekeeper online checks.
- **ASC API key:** appstoreconnect.apple.com > Keys > Revoke. Notarization stops; existing notarized apps unaffected.
