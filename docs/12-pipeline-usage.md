# DMG pipeline: usage

Draft v0.1 | 16 November 2026 | How to add secrets, run the build and install the DMG

The **Build DMG** workflow builds the Mac app on a GitHub-hosted macOS runner, packages it as a DMG and attaches the DMG to a **draft pre-release**. It runs only when you start it by hand. Nothing in this repo has run it yet (see [What is verified](#what-is-verified-and-what-is-not)).

| File | Role |
| --- | --- |
| `.github/workflows/build-dmg.yml` | Manual trigger, runner, secrets. Calls the script. |
| `scripts/build-dmg.sh` | All build logic. Run `scripts/build-dmg.sh --help`. |
| `scripts/ExportOptions.plist` | Developer ID export options (team ID and provisioning profiles injected at build time). |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated on the runner, never committed. |
| `App/` | Placeholder menu-bar app that shows its version. |
| `.github/actionlint.yaml` | Tells actionlint 1.7.7 that `macos-26` is a valid runner label. |

## 1. What the pipeline does

1. Runs on `macos-26` (macOS 26, Apple Silicon), with a 30-minute timeout. Only one build runs at a time.
2. Picks the newest `/Applications/Xcode_26*.app` (override with the `XCODE_APP` environment variable) and prints `xcodebuild -version`.
3. Installs XcodeGen with Homebrew and generates `DriveApp.xcodeproj` from `project.yml`.
4. If signing secrets exist, imports the Developer ID certificate into a temporary keychain and installs the Developer ID provisioning profile(s) after checking them against the certificate, team and bundle IDs. If they don't, the build is unsigned.
5. Runs `xcodebuild archive` (Release, arm64 only, version and build number from the inputs). For signed builds it then runs `-exportArchive` with `ExportOptions.plist`. For unsigned builds Xcode builds with `CODE_SIGNING_ALLOWED=NO`; the script copies the `.app` out of the archive and ad-hoc signs it inside-out (StorageService tool, FSKit `.appex`, then the app), each with its own entitlements and the hardened runtime flag.
6. Creates the DMG with `hdiutil` (UDZO). The DMG contains the app and an `Applications` shortcut. Signed builds also sign the DMG.
7. Notarises and staples the DMG, but only if the App Store Connect key secrets exist and the build is signed. Otherwise the log says `Notarisation skipped: …`.
8. Writes `<dmg>.sha256`, prints it and adds it to the run summary.
9. Creates the draft pre-release `v<version>-b<build>` and attaches the DMG and `.sha256`. The run fails early if that release or tag already exists.
10. Always deletes the temporary keychain, decoded key files and the profiles it installed, even if the build fails.

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
| `MACOS_PROFILE_FSEXT_BASE64` | Developer ID provisioning profile for the FSKit module (`<APP_BUNDLE_ID>.fsext`) with the **FSKit Module** capability, base64-encoded | Signing (**required** if the `.p12` is set) |
| `MACOS_PROFILE_APP_BASE64` | Developer ID provisioning profile for the app (`<APP_BUNDLE_ID>`), base64-encoded | Signing (optional; see below) |
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

### Developer ID provisioning profiles (`.provisionprofile`)

The FSKit module claims `com.apple.developer.fskit.fsmodule`. That is a *restricted* entitlement: on macOS it must be authorised by a provisioning profile embedded in the `.appex`, or the module will not run ([TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)). Apple's [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos) lists FSKit Module as available for Developer ID. So a signed build needs `MACOS_PROFILE_FSEXT_BASE64`. If the `.p12` is set and this secret is not, the run **stops in preflight** with a clear error instead of failing 10 minutes later in Xcode, or producing a signed DMG whose file system can never load. Remove `MACOS_CERT_P12_BASE64` if you want an unsigned build.

The app and the StorageService tool claim only the App Sandbox and a team-prefixed App Group (`<TEAMID>.<APP_BUNDLE_ID>`). TN3125 lists `com.apple.security.application-groups` as unrestricted on macOS, and the [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) page says team-prefixed macOS groups need no registration. So the app needs no profile, and the tool cannot carry one (TN3125: a standalone executable has nowhere to embed it). `MACOS_PROFILE_APP_BASE64` is there in case Xcode or a later entitlement asks for an app profile (G0-VERIFY).

Create the FSKit module profile (Account Holder or Admin):

1. *developer.apple.com › Certificates, IDs & Profiles › Identifiers*: register an explicit App ID `<APP_BUNDLE_ID>.fsext` (today `com.wakeupmonster.driveapp.dev.fsext`). Enable **FSKit Module**. Also enable **App Groups** if you plan to list the group there.
2. *Profiles › +*: choose **Distribution › Developer ID**, pick that App ID and the **same Developer ID Application certificate** that is in the `.p12`. Name it, e.g. `DriveApp FSKit Developer ID`, and download it.
3. Base64-encode it into the secret:

   ```sh
   base64 -i DriveApp_FSKit_Developer_ID.provisionprofile | gh secret set MACOS_PROFILE_FSEXT_BASE64
   ```

For an optional app profile, repeat with the App ID `<APP_BUNDLE_ID>` and store it as `MACOS_PROFILE_APP_BASE64`.

Before the build, the script decodes each profile (`security cms -D`) and stops if the team is not `APPLE_TEAM_ID`, the App ID is not `<TEAMID>.<bundle ID>`, it is not a Developer ID profile (`ProvisionsAllDevices`), it has expired, it lacks the imported certificate, or (FSKit profile) it does not authorise `com.apple.developer.fskit.fsmodule`. It installs the profiles as `<UUID>.provisionprofile` in `~/Library/Developer/Xcode/UserData/Provisioning Profiles` (Xcode 16 and later) and `~/Library/MobileDevice/Provisioning Profiles` (older tools), passes their UUIDs to the matching targets (`DRIVEAPP_FS_PROFILE` / `DRIVEAPP_APP_PROFILE` in `project.yml`, mapped to `PROVISIONING_PROFILE_SPECIFIER`), adds them to the export options' `provisioningProfiles`, and deletes the files it installed during cleanup.

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
base64 -i DriveApp_FSKit_Developer_ID.provisionprofile | gh secret set MACOS_PROFILE_FSEXT_BASE64
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

Unsigned builds are only for checking that the pipeline works. The FSKit module in an unsigned build claims its restricted entitlement without a profile, so macOS will not run it. FSKit extensions and App Group IPC need a proper Developer ID signature and profile, so B01/G0 testing needs a signed and notarised build (see `10-repo-ci-and-test-builds.md` §4). In an unsigned build, `DEVELOPMENT_TEAM` is empty, so the `DriveAppStorageMachService` Info.plist value starts with a dot (`.com.wakeupmonster.driveapp.dev.storage`).

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
| `MACOS_CERT_P12_BASE64 is set but MACOS_PROFILE_FSEXT_BASE64 is not` | Add the FSKit module profile secret (§2), or remove the `.p12` secret for an unsigned build. |
| `MACOS_PROFILE_…: profile team/App ID/…` | The profile does not match this build. The message names the field. Regenerate it for the right bundle ID, as a Developer ID profile, with the certificate in the `.p12`. |
| `…requires a provisioning profile` from Xcode for `DriveApp` | Xcode wants an app profile after all. Add `MACOS_PROFILE_APP_BASE64` (§2). |
| `…does not support provisioning profiles` for `DriveAppStorageService` | A profile reached the command-line tool. Only set profiles through `DRIVEAPP_FS_PROFILE` / `DRIVEAPP_APP_PROFILE`, never a global `PROVISIONING_PROFILE_SPECIFIER`. |
| `Unknown nested code …` (unsigned build) | A new target is embedded in the app. Add it to `ADHOC_NESTED` in `scripts/build-dmg.sh` with its entitlements file. |
| `Nested code problems: …` (signed build) | A nested binary lacks the Developer ID signature, hardened runtime, secure timestamp or (for the `.appex`) the embedded profile. Notarisation would reject it, so the run stops before submitting. |
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

- **Archive, then export** (not `xcodebuild build`). For signed builds Xcode signs nested code inside-out (StorageService tool in `Contents/MacOS`, FSKit `.appex` in `Contents/Extensions`, then the app), and the export re-signs it for Developer ID. All non-app targets set `SKIP_INSTALL: YES`, so the archive stays an app archive.
- **Unsigned builds don't let Xcode sign.** With `CODE_SIGN_IDENTITY=-` ("Sign to Run Locally"), Xcode still checks entitlements and reports "requires a provisioning profile" for restricted entitlements such as the FSKit one ([Apple Developer Forums 751658](https://developer.apple.com/forums/thread/751658)). So the archive uses `CODE_SIGNING_ALLOWED=NO`, and the script ad-hoc signs the copy inside-out with each target's entitlements file (`$(DEVELOPMENT_TEAM)` expanded to empty, as Xcode would) and `--options runtime`. The signed path is unchanged by this.
- **Hardened runtime** is on in `project.yml`, and signed builds add `--timestamp --options=runtime`. A signed build fails if the app or any nested code lacks the Developer ID signature, the runtime flag or a secure timestamp, or if the `.appex` lacks its embedded profile. `codesign --verify --deep --strict` is used only to *verify*; Apple discourages `--deep` for signing, which the script never does.
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
| `xcodegen generate` (XcodeGen 2.44.1 built from source on Linux) into a scratch directory: "Embed ExtensionKit Extensions" (`$(EXTENSIONS_FOLDER_PATH)`, CodeSignOnCopy) for the `.appex`, Copy Files to Executables for the tool, per-target `PROVISIONING_PROFILE_SPECIFIER`, the LaunchAgent script phase inlined with its output path | pass (generated project not committed) |

**Not run** (needs a macOS runner or a Mac with Xcode 26):

- Building the generated project with Xcode (the XcodeGen output itself was inspected on Linux).
- The unsigned path: `CODE_SIGNING_ALLOWED=NO` archive, then ad-hoc signing inside-out and `codesign --verify --deep --strict`.
- The signed path with the FSKit profile: profile checks, Xcode accepting `PROVISIONING_PROFILE_SPECIFIER=<UUID>` on the `.appex` and no profile on the app and tool, `-exportArchive` with `provisioningProfiles` (including how export treats the profile-less tool in `Contents/MacOS`).
- Xcode selection on the real image, `xcodebuild archive` and `-exportArchive`, and compiling the Swift placeholder under Swift 6.
- Keychain import, Developer ID signing, the hardened runtime and timestamp checks.
- `hdiutil create`/`verify`, DMG signing, notarisation, stapling, `spctl`.
- `gh release create` (draft pre-release) and the existing-release and tag checks.
- The `if: always()` cleanup on a real runner. The concurrency and timeout behaviour.
- Installing and launching the DMG on macOS 26 (Gatekeeper prompts, menu-bar item, version display).
