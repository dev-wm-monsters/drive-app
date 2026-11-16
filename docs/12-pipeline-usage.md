# DMG pipeline: usage

Draft v0.1 | 16 November 2026 | How to add secrets, run the build and install the DMG

The **Build DMG** workflow builds the Mac app on a GitHub-hosted macOS runner, packages it as a DMG and attaches the DMG to a **draft pre-release**. It runs only when you start it by hand. Nothing in this repo has run it yet (see [What is verified](#what-is-verified-and-what-is-not)).

| File | Role |
| --- | --- |
| `.github/workflows/build-dmg.yml` | Manual trigger, runner, secrets. Calls the script. |
| `scripts/build-dmg.sh` | All build logic. Run `scripts/build-dmg.sh --help`. |
| `scripts/ExportOptions.plist` | Developer ID export options (team ID injected at build time). |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated on the runner, never committed. |
| `App/` | Placeholder menu-bar app that shows its version. |
| `.github/actionlint.yaml` | Tells actionlint 1.7.7 that `macos-26` is a valid runner label. |

## 1. What the pipeline does

1. Runs on `macos-26` (macOS 26, Apple Silicon), with a 30-minute timeout. Only one build runs at a time.
2. Picks the newest `/Applications/Xcode_26*.app` (override with the `XCODE_APP` environment variable) and prints `xcodebuild -version`.
3. Installs XcodeGen with Homebrew and generates `DriveApp.xcodeproj` from `project.yml`.
4. If signing secrets exist, imports the Developer ID certificate into a temporary keychain. If they don't, it builds with an ad-hoc signature.
5. Runs `xcodebuild archive` (Release, arm64 only, version and build number from the inputs). For signed builds it then runs `-exportArchive` with `ExportOptions.plist`; for unsigned builds it copies the `.app` out of the archive.
6. Creates the DMG with `hdiutil` (UDZO). The DMG contains the app and an `Applications` shortcut. Signed builds also sign the DMG.
7. Notarises and staples the DMG, but only if the App Store Connect key secrets exist and the build is signed. Otherwise the log says `Notarisation skipped: …`.
8. Writes `<dmg>.sha256`, prints it and adds it to the run summary.
9. Creates the draft pre-release `v<version>-b<build>` and attaches the DMG and `.sha256`. The run fails early if that release or tag already exists.
10. Always deletes the temporary keychain and decoded key files, even if the build fails.

DMG names:

| Build | DMG name |
| --- | --- |
| Signed (Developer ID) | `DriveApp-<version>-<build>.dmg` |
| No signing secrets | `DriveApp-<version>-<build>-unsigned.dmg` |

The name comes from `APP_NAME` in `project.yml`. If you rename the app there, the DMG, volume and release title follow.

## 2. Add the secrets (all optional)

Without any secrets the workflow still succeeds and produces an **unsigned** DMG. Add secrets in *GitHub › repo › Settings › Secrets and variables › Actions › New repository secret*, or with `gh secret set` from a Mac that is logged in to `gh` for this repo.

| Secret | What it is | Needed for |
| --- | --- | --- |
| `MACOS_CERT_P12_BASE64` | Developer ID Application certificate **with its private key**, exported as `.p12`, base64-encoded | Signing |
| `MACOS_CERT_PASSWORD` | Password you set when exporting the `.p12` | Signing |
| `APPLE_TEAM_ID` | 10-character team ID | Signing (required if the `.p12` is set) |
| `KEYCHAIN_PASSWORD` | Any long random string for the temporary CI keychain. If missing, the script generates one. | Signing (optional) |
| `ASC_KEY_ID` | App Store Connect API key ID | Notarisation |
| `ASC_ISSUER_ID` | App Store Connect issuer ID (a UUID) | Notarisation |
| `ASC_KEY_P8_BASE64` | The `AuthKey_<KEYID>.p8` file, base64-encoded | Notarisation |

Notarisation needs signing. If the ASC secrets are set but the `.p12` is not, notarisation is skipped with a log line.

### Developer ID certificate (`.p12`)

Needs a paid Apple Developer Program membership. The Account Holder creates the Developer ID Application certificate.

1. On the Mac that has the certificate, open **Keychain Access › login › My Certificates**.
2. Find **Developer ID Application: <name> (<TEAMID>)**. Expand it and check that a private key is underneath.
3. Right-click it, choose **Export**, pick **Personal Information Exchange (.p12)** and set a strong password.
4. Base64-encode it and copy the result to the clipboard:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

5. Paste it as `MACOS_CERT_P12_BASE64`, and put the export password in `MACOS_CERT_PASSWORD`.
6. Delete the `.p12` file afterwards (it is git-ignored, but don't leave it lying around).

Team ID: *developer.apple.com › Account › Membership details › Team ID*.

### App Store Connect API key (`.p8`)

1. *App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys*. Create a key with the **Developer** role.
2. Note the **Key ID** (`ASC_KEY_ID`) and the **Issuer ID** shown above the list (`ASC_ISSUER_ID`).
3. Download `AuthKey_<KEYID>.p8`. Apple lets you download it only once.
4. Base64-encode it:

   ```sh
   base64 -i AuthKey_ABC123DEFG.p8 | pbcopy
   ```

5. Paste it as `ASC_KEY_P8_BASE64`. Store the `.p8` in a password manager and delete the loose file.

### Alternative: `gh secret set`

Run these on the Mac, in a clone of this repo. Each value is read from stdin, so it never appears in your shell history:

```sh
base64 -i DeveloperID.p12   | gh secret set MACOS_CERT_P12_BASE64
gh secret set MACOS_CERT_PASSWORD          # prompts for the value
gh secret set APPLE_TEAM_ID                # prompts
openssl rand -base64 32     | gh secret set KEYCHAIN_PASSWORD
gh secret set ASC_KEY_ID                   # prompts
gh secret set ASC_ISSUER_ID                # prompts
base64 -i AuthKey_ABC123DEFG.p8 | gh secret set ASC_KEY_P8_BASE64
gh secret list                             # names only; values are never shown
```

Secrets reach only the build step, through `env:`. The script never prints them and never uses `set -x`. GitHub masks secret values in logs, and the script masks the generated keychain password too.

## 3. Run the workflow

**Web:** *Actions › Build DMG › Run workflow*. Pick the branch, then fill in:

- `version`: e.g. `0.0.1`. Format `MAJOR.MINOR.PATCH`, optionally with a pre-release suffix such as `0.1.0-beta.1`. The app's `CFBundleShortVersionString` gets the numeric part only (`0.1.0`).
- `build_number`: digits only, e.g. `1`. Becomes `CFBundleVersion`. Use a new number for every run; the run fails if release `v<version>-b<build>` already exists.

**CLI** (documented here; it has not been run):

```sh
gh workflow run build-dmg.yml -f version=0.0.1 -f build_number=1
gh run watch          # follow the run
```

If you start a second run while one is running, it waits. GitHub keeps at most one waiting run per concurrency group, so starting a third run cancels the second (the one still waiting).

### Build on a Mac without CI

The same script works on a Mac with Xcode 26 installed. It doesn't publish a release by default when run outside Actions:

```sh
VERSION=0.0.1 BUILD_NUMBER=1 scripts/build-dmg.sh build
# DMG: build/dist/DriveApp-0.0.1-1-unsigned.dmg
```

On Linux, `scripts/build-dmg.sh build` stops after checking the inputs with "This build needs macOS with Xcode 26 (found Linux)" (exit code 3).

## 4. Where the DMG appears

*GitHub › repo › Releases*. The release is a **draft pre-release** named `DriveApp <version> (build <n>)`, with tag `v<version>-b<build>`. It has two assets: the DMG and `<dmg>.sha256`. The run summary page also shows the file name, SHA-256, and whether it was signed and notarised.

- Drafts are visible only to people with write access to the repo. The tag is created only when someone publishes the draft.
- The DMG is a Release asset, **not** an Actions artifact. Release assets don't count toward Actions storage (see `10-repo-ci-and-test-builds.md` §1). Delete old drafts when you no longer need them.

## 5. Verify the download

In the folder with both files:

```sh
shasum -a 256 -c DriveApp-0.0.1-1.dmg.sha256
# DriveApp-0.0.1-1.dmg: OK
```

For a signed, notarised DMG you can also check:

```sh
xcrun stapler validate DriveApp-0.0.1-1.dmg
spctl --assess --type open --context context:primary-signature -vv DriveApp-0.0.1-1.dmg
codesign -dv --verbose=2 /Applications/DriveApp.app      # after copying the app
```

## 6. Opening an unsigned build (macOS 26)

Unsigned DMGs are ad-hoc signed only, and they are not notarised. Gatekeeper blocks the first launch of a downloaded copy with a message that Apple could not verify the app.

- **macOS 15 and later, including macOS 26:** Control-click (right-click) › **Open** no longer bypasses Gatekeeper for apps that aren't notarised. It shows the same block. Do this instead:
  1. Copy `DriveApp.app` from the DMG to `/Applications` and try to open it once. Dismiss the warning.
  2. Open **System Settings › Privacy & Security** and scroll to **Security**. Click **Open Anyway** next to the message about DriveApp. This button appears for about an hour after the blocked attempt.
  3. Confirm with your password or Touch ID, then choose **Open**.
- **macOS 14 and earlier:** right-click › **Open** › **Open** worked. DriveApp needs macOS 26, so this path doesn't apply.
- **Terminal alternative** (a test machine you control only): `xattr -dr com.apple.quarantine /Applications/DriveApp.app`.

The app runs in the menu bar (no Dock icon). Look for the drive icon in the menu bar; the menu shows the version and build.

Unsigned builds are only for checking that the pipeline works. FSKit extensions and App Group IPC need a proper Developer ID signature, so B01/G0 testing needs a signed and notarised build (see `10-repo-ci-and-test-builds.md` §4). In an unsigned build, `DEVELOPMENT_TEAM` is empty, so the `DriveAppStorageMachService` Info.plist value starts with a dot (`.com.wakeupmonster.driveapp.dev.storage`).

## 7. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `VERSION '…' is not valid` / `BUILD_NUMBER '…' is not valid` | Use `1.2.3` (optionally `-beta.1`) and plain digits without leading zeros. |
| `Release v… already exists` / `Tag v… already exists` | Use a new `build_number`, or delete the old draft release (and tag). |
| `No /Applications/Xcode_26*.app found` | The runner image changed. Check the image README (link below), then pick another image or set `XCODE_APP` in the workflow `env:`. |
| `brew install xcodegen` slow or failing | Homebrew outage. Re-run. XcodeGen isn't preinstalled on the image. |
| `Could not import the .p12` | Wrong `MACOS_CERT_PASSWORD`, or the base64 got mangled. Re-encode with `base64 -i file.p12` and paste without extra spaces. |
| `No valid 'Developer ID Application' identity` | The `.p12` has no private key, or holds an "Apple Development" certificate. Export the Developer ID Application certificate together with its key. |
| `The archive is not an app archive` | A non-app target (FSKit extension, helper tool) lacks `SKIP_INSTALL: "YES"` in `project.yml`. |
| Export fails asking for a provisioning profile | A target's entitlements need a Developer ID provisioning profile (possible for FSKit; G0 decides). Add a `provisioningProfiles` dictionary to `scripts/ExportOptions.plist` and install the profile on the runner. |
| `Notarisation failed` | The log prints `notarytool log` output. Common causes: missing hardened runtime on a nested binary, an unsigned nested binary, or a missing secure timestamp. |
| `Notarisation skipped: …` | Expected when the build is unsigned or the ASC secrets are missing or incomplete. The message names what is missing. |
| `hdiutil create failed` | Rare "Resource busy" on CI. The script already retries 3 times; re-run the workflow. |
| Run cancelled while waiting | A newer run replaced it in the concurrency queue (see §3). |

The full `xcodebuild` logs are in `build/logs/` on the runner. On failure the script prints the last 60 lines. Logs are not uploaded as artifacts, on purpose.

## 8. Decisions and evidence

### Runner image: `macos-26`

Checked 16 November 2026 in the [actions/runner-images README](https://github.com/actions/runner-images):

- *macOS 26 Arm64* has the labels `macos-latest`, `macos-26` and `macos-26-xlarge`. *macOS 15 Arm64* is `macos-15`, and macOS 14 images are deprecated.
- [macos-26-arm64 image README](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md): image `20261102.0473.1`, macOS 26.7.2 (25G332). It ships Xcode 26.6 (default), 26.5, 26.4.1, 26.3, 26.2, 26.1.1 and 26.0.1 under `/Applications/Xcode_26.*.app`, plus Homebrew and GitHub CLI 2.103.3. XcodeGen is not listed, so the script installs it.

The workflow pins `macos-26`, not `macos-latest`, so a future OS change is deliberate. The script picks the newest non-beta `Xcode_26*.app`, skipping symlinks such as `Xcode_26.4.app`. Today that is Xcode 26.6. To pin an exact Xcode, set `XCODE_APP: /Applications/Xcode_26.6.app` in the workflow `env:`.

actionlint 1.7.7 predates the `macos-26` label, so `.github/actionlint.yaml` declares it.

### Actions pinned to commit SHAs

| Action | Pin | How checked |
| --- | --- | --- |
| `actions/checkout` | `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09` (v5.1.0) | `git ls-remote https://github.com/actions/checkout`: `refs/tags/v5.1.0` and `refs/tags/v5` both point at this commit. |

No other actions are used. Checkout uses `persist-credentials: false`; `gh` authenticates with `GH_TOKEN` (the job's `github.token`, `contents: write` only).

### Other choices

- **Archive, then export** (not `xcodebuild build`). Xcode signs nested code inside-out, so the B01 FSKit `.appex` and the helper tool get signed without extra script changes. Unsigned builds use `CODE_SIGN_IDENTITY=-` for every target.
- **Hardened runtime** is on in `project.yml`, and signed builds add `--timestamp --options=runtime`. The script fails a signed build if the app lacks the runtime flag, and warns for any nested code that lacks it.
- **The DMG is notarised and stapled**, not the `.app` separately. Notarising the DMG covers the app inside it.
- **No caching.** XcodeGen comes from a Homebrew bottle. DerivedData isn't cached.

## What is verified and what is not

Verified on Linux (this session):

| Check | Result |
| --- | --- |
| `actionlint .github/workflows/build-dmg.yml` (shellcheck integration on) | pass |
| `shellcheck -x scripts/build-dmg.sh` | pass |
| `yamllint -d relaxed project.yml .github/workflows/build-dmg.yml` | pass |
| `ExportOptions.plist`, `App/Info.plist` and `App/DriveApp.entitlements` parse as XML plists (Python `plistlib`) | pass |
| `scripts/build-dmg.sh --help`, input validation, non-macOS stop (exit 3), `cleanup` no-op | pass |

**Not run** (needs a macOS runner or a Mac with Xcode 26):

- `xcodegen generate` against `project.yml` (spec semantics, generated Info.plist matching `App/Info.plist`).
- Xcode selection on the real image, `xcodebuild archive` and `-exportArchive`, and compiling the Swift placeholder under Swift 6.
- Keychain import, Developer ID signing, the hardened runtime and timestamp checks.
- Ad-hoc signing path and `codesign --verify` of the unsigned app.
- `hdiutil create`/`verify`, DMG signing, notarisation, stapling, `spctl`.
- `gh release create` (draft pre-release) and the existing-release and tag checks.
- The `if: always()` cleanup on a real runner. The concurrency and timeout behaviour.
- Installing and launching the DMG on macOS 26 (Gatekeeper prompts, menu-bar item, version display).
