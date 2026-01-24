# ADR-0004: Sparkle Auto-Updates

**Date**: 2026-01-23
**Status**: Accepted
**Context**: Ayna is distributed outside the Mac App Store and needs automatic updates

## Context

Ayna is distributed via GitHub Releases and Homebrew Cask, outside the Mac App Store. Users need a reliable way to receive updates without manually downloading new versions. The lack of automatic updates creates friction for users and delays security fixes and feature rollouts.

Requirements:
- **Non-App Store distribution**: App Store's built-in update mechanism is not available
- **User trust**: Updates must be cryptographically signed to prevent tampering
- **Seamless UX**: Updates should happen with minimal user intervention
- **macOS native**: The solution should follow Apple's design patterns

## Decision

We integrate [Sparkle 2.x](https://sparkle-project.org/) for automatic update checks and installation.

### Key Design Choices

1. **Sparkle 2.x via Swift Package Manager**
   - Modern Swift-compatible API
   - EdDSA (Ed25519) signatures for security
   - Automatic delta updates for bandwidth efficiency

2. **Appcast hosted on GitHub**
   - `appcast.xml` in repository root
   - Served via GitHub raw content
   - Updated by CI on each release

3. **EdDSA code signing**
   - Private key stored in GitHub Secrets (`SPARKLE_PRIVATE_KEY`)
   - Public key embedded in app bundle (via Info.plist)
   - Signatures verified before installation

4. **User preferences**
   - Automatic checks enabled by default (every 24 hours)
   - Manual "Check for Updates..." menu item in app menu
   - Settings UI for toggling automatic checks (future enhancement)

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        aynaApp                               │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │  UpdaterService │───▶│ SPUStandardUpdaterController   │  │
│  │  (@Observable)  │    │        (Sparkle)               │  │
│  └────────┬────────┘    └───────────────┬────────────────┘  │
│           │                             │                    │
│           ▼                             ▼                    │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │  App Menu       │    │    Sparkle Update UI           │  │
│  │  (Check for     │    │  (Download/Install dialogs)    │  │
│  │   Updates...)   │    │                                │  │
│  └─────────────────┘    └────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   GitHub (appcast.xml)        │
              │   https://raw.githubusercontent│
              │   .com/sozercan/ayna/main/    │
              │   appcast.xml                 │
              └───────────────────────────────┘
```

### Update Flow

1. **On app launch** (if automatic checks enabled):
   - Sparkle fetches `appcast.xml` from GitHub
   - Compares version against current app version
   - If newer version exists, shows update dialog

2. **User clicks "Install Update"**:
   - Sparkle downloads the DMG from GitHub Releases
   - Verifies EdDSA signature
   - Extracts and replaces app bundle
   - Relaunches the app

3. **Manual check** (Ayna → Check for Updates...):
   - Same flow but user-initiated
   - Shows "You're up to date" if no update available

### Release Process

1. Tag new version: `git tag v1.2.3 && git push --tags`
2. CI builds, archives, and creates DMG
3. CI signs DMG with EdDSA key
4. CI updates `appcast.xml` with new entry
5. CI uploads DMG to GitHub Releases
6. Users receive update on next check

## Consequences

### Positive

- **Seamless updates**: Users receive updates automatically without visiting GitHub
- **Security**: EdDSA signatures prevent malicious update injection
- **Standard UX**: Sparkle is the de facto standard for macOS app updates
- **Delta updates**: Sparkle can generate deltas to reduce download size (future)
- **Rollback support**: Users can skip versions if needed
- **No infrastructure cost**: Hosted entirely on GitHub

### Negative

- **Framework dependency**: Adds ~2MB to app size (Sparkle.framework)
- **Key management**: EdDSA private key must be secured in CI secrets
- **macOS only**: Sparkle doesn't support iOS/watchOS (not applicable there anyway)

### Neutral

- **Info.plist configuration**: Requires `SUFeedURL`, `SUPublicEDKey` entries
- **Homebrew Cask**: Users installing via Cask may see duplicate update prompts
  - Mitigated by `auto_updates true` in Cask definition

## Implementation Notes

### Required Info.plist Keys

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/sozercan/ayna/main/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>YOUR_BASE64_ENCODED_PUBLIC_KEY</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

### Key Generation

Generate an EdDSA keypair (run once, store private key securely):

```bash
# After building with Sparkle, find the generate_keys tool
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

This outputs:
- Public key: Add to Info.plist as `SUPublicEDKey`
- Private key: Add to GitHub Secrets as `SPARKLE_PRIVATE_KEY`

### Signing a Release Locally

```bash
./Tools/sign-update.sh ./build/ayna-v1.2.3.dmg
```

### GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing releases |

## Files Added/Modified

- `Core/Services/UpdaterService.swift` - Sparkle wrapper service (macOS only)
- `Core/Diagnostics/DiagnosticsLogger.swift` - Added `.updater` category
- `App/macOS/aynaApp.swift` - Added "Check for Updates..." menu item
- `App/macOS/Info.plist` - Added Sparkle configuration keys
- `appcast.xml` - Sparkle update feed (updated by CI)
- `Tools/sign-update.sh` - Local signing helper script
- `.github/workflows/release.yml` - Sparkle signing and appcast updates

## References

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle GitHub Repository](https://github.com/sparkle-project/Sparkle)
- [EdDSA Signing](https://sparkle-project.org/documentation/eddsa-migration/)
