# Release Pipeline Setup — one-time prerequisites

Everything Track D (#19, #20, #23, #24) needs you to configure before
the first `git tag v0.1.0 && git push --tags` will produce a real
notarized DMG that `brew install` can pull.

## 1. Apple Developer Program membership

The Apple Development cert used in local dev (free, issued by Xcode
with any Apple ID) is NOT sufficient for release signing. Notarization
and Gatekeeper require a **Developer ID Application** certificate,
which is gated behind the paid Apple Developer Program ($99 / year).

Enroll at <https://developer.apple.com/programs/enroll/> if you
haven't already.

Once enrolled:

1. Xcode → Settings → Accounts → *your Apple ID* → Manage Certificates.
2. Click `+` → **Developer ID Application**. A new cert lands in
   Keychain.
3. Export it as a `.p12` with a password:
   - Open Keychain Access → login → My Certificates.
   - Right-click "Developer ID Application: *Your Name (TEAMID)*" →
     Export → set password → save `.p12`.

## 2. App-specific password for `notarytool`

1. <https://appleid.apple.com/account/manage> → Sign-In and Security
   → App-Specific Passwords → `+`.
2. Label it `clicky-ai notary`, copy the generated password.

## 3. GitHub repository secrets

Settings → Secrets and variables → Actions → New repository secret.
Add five:

| Secret name | Value |
|---|---|
| `APPLE_ID` | Your Apple Developer Apple ID email |
| `APPLE_APP_PASSWORD` | The app-specific password from step 2 |
| `APPLE_TEAM_ID` | 10-char Team ID (Xcode → Accounts shows it; also visible as `TeamIdentifier` in `make doctor`) |
| `SIGNING_CERTIFICATE_P12` | `base64 -i DeveloperIDApplication.p12 \| pbcopy` — paste |
| `SIGNING_CERTIFICATE_PASSWORD` | The `.p12` password you set in step 1.3 |

Optional — for the "auto-bump the Homebrew tap" job (Track B #24):

| Secret name | Value |
|---|---|
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with `repo` scope on `proyecto26/homebrew-tap` |

If you skip the optional secret, the `bump-tap` job is simply
skipped. You still get a notarized DMG attached to the GitHub release —
you'd just have to bump the cask manually the first few releases.

## 4. Create the Homebrew tap repo (Track B #23)

One-time on GitHub:

1. Create empty public repo at `https://github.com/proyecto26/homebrew-tap`.
2. Seed it with a `Casks/` directory:
   ```bash
   gh repo create proyecto26/homebrew-tap --public --description "Homebrew casks by Proyecto 26"
   git clone https://github.com/proyecto26/homebrew-tap.git
   cd homebrew-tap
   mkdir Casks
   cp ../clicky-ai-plugin/casks/clicky-ai.rb Casks/clicky-ai.rb
   git add Casks/clicky-ai.rb
   git commit -m "Seed clicky-ai cask"
   git push
   ```
3. Verify:
   ```bash
   brew tap proyecto26/tap
   brew info --cask proyecto26/tap/clicky-ai
   ```

After the first release tag (`v0.1.0`), the `bump-tap` workflow will
open a PR on this repo with the new version + SHA256.

## 5. Dry-run — cut a throwaway tag

Before shipping `v0.1.0`, cut `v0.0.0-ci-test`:

```bash
git tag v0.0.0-ci-test
git push origin v0.0.0-ci-test
```

Watch Actions → Release Clicky.app. Expected:

1. `build` job completes (signed + notarized + stapled).
2. `release` job creates GitHub Release with DMG + `.dmg.sha256`.
3. `bump-tap` opens a PR on `proyecto26/homebrew-tap` if you set
   `HOMEBREW_TAP_TOKEN`.

Delete the test release afterwards:
```bash
gh release delete v0.0.0-ci-test --yes
git push --delete origin v0.0.0-ci-test
git tag -d v0.0.0-ci-test
```

## What happens without step 3

The workflow has graceful fallbacks:

| Missing | Effect |
|---|---|
| `SIGNING_CERTIFICATE_P12` | Build still runs but with ad-hoc signing — `Clicky.app` Gatekeeper-quarantines on user machines. OK for smoke testing, NOT for brew users. |
| `APPLE_ID` / `APPLE_APP_PASSWORD` / `APPLE_TEAM_ID` | Notarization skipped, DMG still attached. First user launch will show Gatekeeper warning. |
| `HOMEBREW_TAP_TOKEN` | `bump-tap` job skipped silently. Manual cask update required per release. |

All three missing = DMG + SHA256 still produced; just not distributable.
Good for validating the pipeline end-to-end before you spend $99.
