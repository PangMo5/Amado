# Releasing

Amado uses the same tagged-release flow as the other PangMo5 apps. A `v*` tag
builds and notarizes the macOS agent, publishes its DMG and Sparkle appcast to a
GitHub Release, and deploys the website to GitHub Pages.

## Repository setup

Enable GitHub Pages with **GitHub Actions** as its source, then configure these
Actions secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPMENT_TEAM` | Apple Developer team ID |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Ephemeral CI keychain password |
| `AC_API_KEY_ID` | App Store Connect API key ID for notarization |
| `AC_API_ISSUER_ID` | App Store Connect API issuer ID |
| `AC_API_KEY_P8` | Contents of the notarization API `.p8` key |
| `SPARKLE_PUBLIC_ED_KEY` | Sparkle EdDSA public key embedded in the app |
| `SPARKLE_PRIVATE_ED_KEY` | Matching Sparkle private key used to sign updates |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with write access to `PangMo5/homebrew-tap` |

Keep the Sparkle private key and Developer ID export out of the repository.

## Cut a release

1. Set `appVersion` in `Project.swift`.
2. Add a matching `## VERSION — YYYY-MM-DD` section at the top of
   `CHANGELOG.md`.
3. Merge the release commit to `main`.
4. Create and push the matching tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

The workflow rejects a tag whose version does not match `Project.swift`. The
first successful release creates `Casks/amado.rb` in `PangMo5/homebrew-tap`;
later releases update its version and SHA-256 automatically. After the run
completes, verify the GitHub Release, DMG notarization, Homebrew install,
website, and `https://pangmo5.dev/Amado/appcast.xml` before announcing it.
