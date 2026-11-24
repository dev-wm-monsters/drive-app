# Build pipelines: usage

Draft v0.2 | 24 November 2026 | How to add secrets and variables, run the Mac and Windows builds, and install the results

This repo has three GitHub Actions workflows:

| Workflow | Trigger | Runner | Output |
| --- | --- | --- | --- |
| **Build DMG** (`.github/workflows/build-dmg.yml`) | Manual only | `macos-26` | Draft pre-release `v<version>-b<build>` with `DriveApp-<version>-<build>[-unsigned].dmg` and its `.sha256` |
| **Build Windows** (`.github/workflows/build-windows.yml`) | Manual only | `windows-2025` | Draft pre-release `win-v<version>-b<build>` with installer and portable zip for `win-x64` and `win-arm64`, each with a `.sha256` |
| **Core tests** (`.github/workflows/core-tests.yml`) | Pull requests that touch `Packages/DriveCore/**`, `windows/**`, `spec/**` or the workflow itself; also manual | `ubuntu-24.04` | Test results in the run log only |

Nothing in this repo has run any of them yet. See [What is verified](#9-what-is-verified-and-what-is-not).

| File | Role |
| --- | --- |
| `scripts/build-dmg.sh` | All Mac build logic. Run `scripts/build-dmg.sh --help`. |
| `scripts/ExportOptions.plist` | Developer ID export options. The script adds the team ID and provisioning profiles at build time. |
| `scripts/build-windows.ps1` | All Windows build logic (PowerShell 7). Run `pwsh scripts/build-windows.ps1 help`. |
| `scripts/windows/DriveApp.iss` | Inno Setup script for the Windows installer. |
| `.github/actionlint.yaml` | Tells actionlint 1.7.7 that `macos-26` is a valid runner label. |

The rules from the original brief (`11-dmg-pipeline-brief.md`) apply to both build workflows:

- They run only when you start them (`workflow_dispatch` with `version` and `build_number` inputs).
- Installers are **draft pre-release assets**, never `actions/upload-artifact` (artifacts count toward the Actions storage quota).
- Runner images and actions are pinned.
- Every secret is optional. Without secrets you get an unsigned build, and the run still succeeds. Each skipped step prints why.
- A cleanup step always runs. Each workflow allows one run at a time and has a timeout.

## 1. What the pipelines do

### Build DMG (macOS)

1. Runs on `macos-26` (macOS 26, Apple Silicon). Timeout 30 minutes.
2. Picks the newest `/Applications/Xcode_26*.app` (or `XCODE_APP`) and generates `DriveApp.xcodeproj` from `project.yml` with XcodeGen.
3. Reads the real build settings of the two targets, **`DriveApp`** (sandboxed menu-bar app) and **`DriveAppFileProvider`** (File Provider app extension in `Contents/PlugIns`, bundle ID `<APP_BUNDLE_ID>.fileprovider`). It resolves each target's entitlements and lists any *restricted* entitlements (see §2.3).
4. Signed builds: imports the Developer ID certificate into a temporary keychain and installs any provisioning profiles you supplied, after checking each one. Unsigned builds skip this.
5. Runs `xcodebuild archive` (Release, arm64, version and build from the inputs). The Google configuration from the repository variables goes in as build settings (`GOOGLE_CLIENT_ID_MAC=…` and so on; see §2.1).
   - **Signed:** Xcode signs the extension and then the app. The script then runs `-exportArchive`.
   - **Unsigned:** Xcode builds with `CODE_SIGNING_ALLOWED=NO`. The script copies the app and ad-hoc signs it inside-out with each target's resolved entitlements and the hardened runtime: frameworks first, then `DriveAppFileProvider.appex`, then the app.
6. Checks the result:
   - every nested signature;
   - that `GoogleClientID`, `GoogleReversedClientID`, `DriveRootSharedDriveName` and `DriveRootFolderID` in the app's Info.plist match the injected values;
   - the version and build number.
7. Builds the DMG with `hdiutil` (UDZO, with an `Applications` shortcut). Signed builds also sign the DMG.
8. Notarises and staples the DMG if the build is signed and the App Store Connect key is set.
9. Writes the `.sha256`, creates the draft pre-release `v<version>-b<build>` and attaches both files. The run fails early if that release or tag already exists.
10. Always deletes the temporary keychain, decoded keys and the profiles it installed.

### Build Windows

1. Runs on `windows-2025`. Timeout 45 minutes. Installs the .NET 10 SDK with `actions/setup-dotnet`.
2. **Preflight:** checks the inputs (the build number must be ≤ 65535, because Windows file versions use 16-bit parts) and the configuration. It finds Inno Setup (preinstalled on the image; otherwise it runs `choco install innosetup --version 6.7.1`) and checks that the draft release does not exist yet.
3. Restores and runs `windows/tests/DriveSync.Core.Tests`.
4. For **`win-x64`** and **`win-arm64`**:
   1. `dotnet publish windows/src/DriveSync.App` self-contained, with `-p:Version=<version> -p:FileVersion=<numeric version>.<build>`. `AssemblyVersion` and `InformationalVersion` are set too.
   2. Writes the configuration into the **published** `appsettings.json`: `Google:ClientId`, `Google:ClientSecret`, `Drive:SharedDriveName` and `Drive:FolderId` (see §2.1). The secret is masked in the log and never printed.
   3. **Signed:** signs our own binaries (the app `.exe` and the `DriveSync*.dll` files that are not signed yet) with `signtool /fd SHA256 /tr http://timestamp.digicert.com /td SHA256`, then verifies them.
   4. Zips the folder into `DriveApp-<version>-<build>-<rid>-portable[-unsigned].zip`.
   5. Compiles `scripts/windows/DriveApp.iss` into `DriveApp-<version>-<build>-<rid>-setup[-unsigned].exe`. Signed builds have Inno Setup sign both the setup and the uninstaller it embeds.
5. Writes a `.sha256` file for each asset (`<hash>  <file>` format) and adds the hashes to the run summary.
6. Creates the draft pre-release `win-v<version>-b<build>` with the 4 assets and 4 `.sha256` files. The `win-` prefix keeps Windows tags separate from the Mac tags (`v…`), so both platforms can use the same version and build number.
7. Always removes the imported certificate (and its key) from the runner's user store and deletes the decoded `.pfx`.

The installer:

- Installs **per user without admin rights** into `%LOCALAPPDATA%\Programs\DriveApp`.
- Adds a Start Menu shortcut and offers *Start DriveApp when I sign in to Windows* (an `HKCU\…\Run` value, checked by default).
- Runs on Windows 10 2004 (build 19041) or later.
- On uninstall, stops the app (`taskkill`), runs `DriveSync.App.exe --unregister` to remove the Cloud Files sync root and the Explorer entry, then deletes the files.

### Core tests

| Job | What it runs |
| --- | --- |
| `swift` | `swift build` and `swift test` for `Packages/DriveCore`, in the `swift:6.2.4-noble` container (pinned by digest). |
| `dotnet` | Builds the solution in `windows/` with `EnableWindowsTargeting=true`, then runs `dotnet test` on `DriveSync.Core.Tests`. |

Both jobs have read-only permissions and a 20-minute timeout. A newer push to the same pull request cancels the older run.

## 2. Secrets and variables

Add them in *GitHub › repo › Settings › Secrets and variables › Actions*: the **Secrets** tab for secrets, the **Variables** tab for variables. Or use `gh secret set NAME` / `gh variable set NAME` from a clone. Every one is optional.

### 2.1 Variables (not secret; they ship inside the apps)

| Variable | Used by | Value |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID_MAC` | Mac | Client ID of the Google OAuth client of type **iOS**, bound to bundle ID `com.wakeupmonster.driveapp.dev`. Looks like `1234567890-abc….apps.googleusercontent.com`. |
| `GOOGLE_REVERSED_CLIENT_ID` | Mac | `com.googleusercontent.apps.1234567890-abc…`. If empty, the script derives it from `GOOGLE_CLIENT_ID_MAC`. If set, it must match, or the run stops. |
| `GOOGLE_CLIENT_ID_WINDOWS` | Windows | Client ID of the Google OAuth client of type **Desktop app**. |
| `DRIVE_ROOT_SHARED_DRIVE_NAME` | both | Shared drive to show. Default `WakeupMonster`. |
| `DRIVE_ROOT_FOLDER_ID` | both | Optional folder ID. If set, it takes precedence over the shared drive name. |

If a variable is empty, the run prints a **warning** and still succeeds. The app builds with the empty default and reports "not configured" at sign-in.

How each platform gets the values:

- **Mac:** passed to `xcodebuild` as build settings. `project.yml` maps them to the Info.plist keys `GoogleClientID`, `GoogleReversedClientID`, `DriveRootSharedDriveName` and `DriveRootFolderID`.
- **Windows:** written into the published `appsettings.json`.

The Google Cloud setup is in `docs/15-google-cloud-setup.md`.

```sh
gh variable set GOOGLE_CLIENT_ID_MAC --body "1234567890-abc.apps.googleusercontent.com"
gh variable set GOOGLE_CLIENT_ID_WINDOWS --body "1234567890-def.apps.googleusercontent.com"
gh variable set DRIVE_ROOT_SHARED_DRIVE_NAME --body "WakeupMonster"
```

### 2.2 Secrets

| Secret | Platform | What it is | Needed for |
| --- | --- | --- | --- |
| `MACOS_CERT_P12_BASE64` | Mac | Developer ID Application certificate **with its private key** (`.p12`), base64 | Signing (turns it on) |
| `MACOS_CERT_PASSWORD` | Mac | Password of the `.p12` | Signing |
| `APPLE_TEAM_ID` | Mac | 10-character team ID | Signing (required if the `.p12` is set) |
| `KEYCHAIN_PASSWORD` | Mac | Any long random string for the temporary keychain; generated if missing | Signing (optional) |
| `MACOS_PROFILE_APP_BASE64` | Mac | Developer ID provisioning profile for `com.wakeupmonster.driveapp.dev`, base64 | **Required for signed builds** (shared keychain sign-in needs it, TN3137) |
| `MACOS_PROFILE_EXT_BASE64` | Mac | Developer ID provisioning profile for `com.wakeupmonster.driveapp.dev.fileprovider`, base64 | **Required for signed builds** (shared keychain sign-in needs it, TN3137) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | Mac | App Store Connect API key (Developer role); the `.p8` base64 | Notarisation |
| `WINDOWS_CERT_PFX_BASE64` | Windows | Code-signing certificate with private key (`.pfx`), base64 | Authenticode signing (turns it on) |
| `WINDOWS_CERT_PASSWORD` | Windows | Password of the `.pfx` | Authenticode signing |
| `GOOGLE_CLIENT_SECRET_WINDOWS` | Windows | Client secret of the Google **Desktop app** client | Google sign-in on Windows |

About `GOOGLE_CLIENT_SECRET_WINDOWS`:

- Google documents installed-app ("Desktop app") client secrets as **not confidential**, and the value ends up in `appsettings.json` inside the installer and the zip.
- It is still stored as a secret, so it stays out of the repo and is masked in logs.
- The Mac uses an iOS-type client, which has no secret.

Encode files on a Mac (`base64 -i file | pbcopy`) or in PowerShell (`[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.pfx")) | Set-Clipboard`). Or pipe them straight in, so nothing lands in your shell history:

```sh
base64 -i DeveloperID.p12 | gh secret set MACOS_CERT_P12_BASE64
gh secret set MACOS_CERT_PASSWORD            # prompts
gh secret set APPLE_TEAM_ID                  # prompts
openssl rand -base64 32 | gh secret set KEYCHAIN_PASSWORD
base64 -i DriveApp_App_DeveloperID.provisionprofile | gh secret set MACOS_PROFILE_APP_BASE64
base64 -i DriveApp_FileProvider_DeveloperID.provisionprofile | gh secret set MACOS_PROFILE_EXT_BASE64
gh secret set ASC_KEY_ID                     # prompts
gh secret set ASC_ISSUER_ID                  # prompts
base64 -i AuthKey_ABC123DEFG.p8 | gh secret set ASC_KEY_P8_BASE64
base64 -i codesign.pfx | gh secret set WINDOWS_CERT_PFX_BASE64
gh secret set WINDOWS_CERT_PASSWORD          # prompts
gh secret set GOOGLE_CLIENT_SECRET_WINDOWS   # prompts
gh secret list                               # names only
```

Secrets reach only the build step, through `env:`. The scripts never print them, never trace commands, and mask derived values (the keychain password, the Google client secret).

### 2.3 Mac: do I need provisioning profiles?

The answer depends on the entitlements the Mac targets claim, so the script decides for each target:

| Entitlement | Profile needed under Developer ID? | Source |
| --- | --- | --- |
| App Sandbox, network client, user-selected files (`com.apple.security.*`) | No | [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles): unrestricted on macOS |
| App Groups `com.apple.security.application-groups` with a **team-prefixed** ID (`<TEAMID>.com.wakeupmonster.driveapp.dev`) | No (unrestricted). A profile still makes the claim "validated". | TN3125; Quinn, [App Groups: macOS vs iOS](https://developer.apple.com/forums/thread/721701). macOS 15+ only skips the "access data from other apps" prompt if the ID starts with your Team ID or a profile authorises it. |
| File Provider extension point (`com.apple.fileprovider-nonui`) | No. It is an extension point, not an entitlement. Only *FileProvider Testing Mode* is a capability, and that one is development-only. | [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos) |
| **Keychain sharing / data protection keychain**: `keychain-access-groups`, or relying on `com.apple.application-identifier` | **Yes, for every process that uses it** (app *and* extension) | [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains): the entitlements that define data protection keychain access groups "must be authorized by a provisioning profile". Quinn ([forum 826107](https://developer.apple.com/forums/thread/826107)): Developer ID apps can use the data protection keychain with a profile; groups must be Team-ID-prefixed. |

So if the app and the extension share OAuth tokens through the data protection keychain (`keychain-access-groups`), a signed build needs **both** profiles. If neither target claims a restricted entitlement, no profile is needed.

What the script does:

- **Signed build:** it lists the restricted keys for each target. If a target has one and its profile secret is missing, the run **stops** with a message that names the target and the secret. That is faster than waiting for Xcode's "requires a provisioning profile", or for a DMG whose app macOS refuses to launch.
- **Each supplied profile is checked.** The run stops if:
  - the team is not `APPLE_TEAM_ID`;
  - the App ID is not `<TEAMID>.<bundle ID>`;
  - it is not a Developer ID profile (`ProvisionsAllDevices`);
  - it has expired;
  - it does not contain the imported certificate;
  - it does not list each restricted entitlement the target claims.
- **Installing the profiles:**
  1. Copies each profile to `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and `~/Library/MobileDevice/Provisioning Profiles` as `<UUID>.provisionprofile`.
  2. Passes the UUIDs to `xcodebuild` as `DRIVEAPP_APP_PROFILE` and `DRIVEAPP_EXT_PROFILE`. `project.yml` maps these to each target's `PROVISIONING_PROFILE_SPECIFIER`. There is no global `PROVISIONING_PROFILE_SPECIFIER`, because it would also reach the Swift package targets.
  3. Adds the profiles to the export options' `provisioningProfiles`.
  4. Deletes the files again in cleanup.
- **Unsigned build:** restricted entitlements cannot be authorised, and macOS refuses to launch an ad-hoc-signed program that claims them. So the ad-hoc signature **leaves them out**, and the log warns about it. The unsigned app and extension then have no shared keychain access group (see §6).

To create the profiles (Account Holder or Admin), on *developer.apple.com › Certificates, IDs & Profiles*:

1. **Identifiers:** register two explicit App IDs:
   - `com.wakeupmonster.driveapp.dev`
   - `com.wakeupmonster.driveapp.dev.fileprovider`

   Enable **App Groups** and, if the app shares the keychain, **Keychain Sharing** on both. Since June 2025, Mac profiles for an App ID with App Groups automatically authorise `TEAMID.*` groups (Quinn, forum 721701).
2. **Profiles › +:** choose **Distribution › Developer ID**, then the App ID and the same Developer ID Application certificate that is in the `.p12`. Do this once for each App ID, and download both profiles.
3. Store them as `MACOS_PROFILE_APP_BASE64` and `MACOS_PROFILE_EXT_BASE64` (commands in §2.2).

**G0-VERIFY:** this is based on Apple's documentation and forum answers. It has not been checked against a real signed build of this project.

### 2.4 Mac certificate and notarisation key

- **Developer ID Application `.p12`** (needs a paid Apple Developer Program membership):
  1. In Keychain Access › login › My Certificates, find *Developer ID Application: … (TEAMID)* and check that it has a private key.
  2. Export it as `.p12` with a strong password.
  3. Base64-encode it into `MACOS_CERT_P12_BASE64`, and delete the loose file.

  The Team ID is under *developer.apple.com › Account › Membership details*.
- **App Store Connect API key:**
  1. Create a key with the Developer role in *App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys*.
  2. Note the Key ID and the Issuer ID.
  3. Download `AuthKey_<KEYID>.p8`. Apple lets you download it only once.

### 2.5 Windows code signing

**Option A: a `.pfx` (implemented).**

You need an OV or EV code-signing certificate from a CA, exported with its private key as `.pfx`. Set `WINDOWS_CERT_PFX_BASE64` and `WINDOWS_CERT_PASSWORD`. The script:

1. Imports it into the runner's `CurrentUser\My` store.
2. Checks that it has a private key and the Code Signing EKU, and that it has not expired.
3. Signs by thumbprint (so the password is not on a command line), with the Windows SDK `signtool.exe`.
4. Removes the certificate again in cleanup.

Since 2023, CAs issue new OV/EV certificates only on hardware tokens or cloud HSMs. A plain `.pfx` is therefore only possible with an older certificate, or with a CA that offers a cloud-HSM export. Most new certificates need Option B or the CA's own signing tool.

**Option B: Azure Artifact Signing, formerly Trusted Signing (recommended; not implemented).**

Microsoft's managed signing service: about USD 10 a month, no certificate file, and the signatures build SmartScreen reputation. Limits:

- Organisations must have 3+ years of verifiable history.
- Individual developers are limited to the US and Canada ([quickstart](https://learn.microsoft.com/azure/artifact-signing/quickstart)).

To adopt it:

1. Create an Artifact Signing account and a certificate profile.
2. Give a Microsoft Entra app registration the *Artifact Signing Certificate Profile Signer* role.
3. Add a step before packaging that uses `Azure/artifact-signing-action` (v2.0.0, commit `c7ab2a863ab5f9a846ddb8265964877ef296ee82`) with OIDC (`azure/login`) or a client secret.
4. Change `scripts/build-windows.ps1` to call it instead of `signtool /sha1` (or `signtool /dlib`).

That is a small change, but it can't be tested without an account, so it is not in the workflow yet.

## 3. Run the workflows

Both build workflows take the same inputs:

| Input | Format | Notes |
| --- | --- | --- |
| `version` | `MAJOR.MINOR.PATCH`, optionally `-pre` (e.g. `0.1.0-beta.1`) | Mac `CFBundleShortVersionString` and the Windows `FileVersion` get only the numeric part. |
| `build_number` | Digits only (e.g. `1`) | Use a new number for every run. Windows allows at most 65535. |

**Web:** *Actions › Build DMG* (or *Build Windows*) › *Run workflow*. Pick the branch and fill in both inputs.

**CLI** (documented; not run from this repo):

```sh
gh workflow run build-dmg.yml     -f version=0.1.0 -f build_number=1
gh workflow run build-windows.yml -f version=0.1.0 -f build_number=1
gh workflow run core-tests.yml    # tests on demand
gh run watch
```

A second run of the same build workflow waits for the first. GitHub keeps only one waiting run per group, so a third run cancels the waiting second one.

Local builds:

- **Mac:**

  ```sh
  VERSION=0.1.0 BUILD_NUMBER=1 scripts/build-dmg.sh build
  ```

  It does not publish outside Actions; the DMG is in `build/dist/`.
- **Windows** (PowerShell 7, .NET 10 SDK, Inno Setup 6):

  ```powershell
  pwsh scripts/build-windows.ps1 build -Version 0.1.0 -BuildNumber 1
  ```

  The output is in `build\windows\dist\`.
- **On Linux:**
  - `build-dmg.sh build` stops after the input checks with exit code 3.
  - `build-windows.ps1 build` also stops with exit code 3. `-NoInstaller` runs restore, tests, both self-contained publishes and the zips, without signing or an installer. Use it as a smoke test.

## 4. Where the files appear

*GitHub › repo › Releases.* Each run creates a **draft pre-release**:

| Platform | Tag | Title | Assets |
| --- | --- | --- | --- |
| Mac | `v<version>-b<build>` | `DriveApp <version> (build <n>) for macOS` | DMG and `.sha256` |
| Windows | `win-v<version>-b<build>` | `DriveApp <version> (build <n>) for Windows` | 2 installers, 2 zips and 4 `.sha256` files |

- Only people with write access can see drafts. The tag is created only when someone publishes the draft.
- Release assets do not count toward the Actions storage quota. Delete old drafts when you no longer need them.
- The run summary shows the file names, SHA-256 hashes, and whether the build was signed and whether a Google client ID was set.

## 5. Verify a download

```sh
shasum -a 256 -c DriveApp-0.1.0-1.dmg.sha256                       # macOS
sha256sum -c DriveApp-0.1.0-1-win-x64-setup-unsigned.exe.sha256     # Linux / Git Bash
```

```powershell
(Get-FileHash .\DriveApp-0.1.0-1-win-x64-setup-unsigned.exe -Algorithm SHA256).Hash   # compare with the .sha256
Get-AuthenticodeSignature .\DriveApp-0.1.0-1-win-x64-setup.exe                          # signed builds: Status Valid
```

For a signed, notarised DMG: `xcrun stapler validate <dmg>` and `spctl --assess --type open --context context:primary-signature -vv <dmg>`.

## 6. Opening an unsigned build

### macOS (unsigned DMG, ad-hoc signed, not notarised)

Gatekeeper blocks the first launch. On macOS 15 and later, right-click › Open no longer gets past it. Instead:

1. Copy `DriveApp.app` from the DMG to `/Applications`, open it once, and dismiss the warning.
2. Open **System Settings › Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the DriveApp message. The button appears for about an hour after the blocked attempt.
3. Confirm with your password or Touch ID, then choose **Open**.

On a test machine you control, the Terminal alternative is `xattr -dr com.apple.quarantine /Applications/DriveApp.app`.

Limits of an unsigned Mac build:

- There is no Team ID. The App Group (`$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID)`) becomes `.com.wakeupmonster.driveapp.dev`, which is not team-prefixed, so macOS may ask the user to allow DriveApp to access data from other apps.
- Restricted entitlements such as keychain sharing are left out.
- Use the unsigned build to check the pipeline, the menu-bar UI and the configuration. Test Finder integration (File Provider) and token sharing with a signed, notarised build.

### Windows (unsigned installer or zip)

Microsoft Defender SmartScreen shows "Windows protected your PC". Click **More info**, then **Run anyway**. Some notes:

- If the file came from a browser, you may first have to choose **Keep** in the download list, or unblock it: right-click the file › **Properties** › **Unblock**.
- With Smart App Control on (some Windows 11 installs), unsigned apps are **blocked outright** and there is no Run anyway. Test on a PC where Smart App Control is off, or use a signed build.
- Signed builds with a new certificate can still show SmartScreen until the certificate earns reputation. Azure Artifact Signing builds reputation faster.

## 7. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `VERSION '…' is not valid` / `BUILD_NUMBER '…' is not valid` | Use `1.2.3` (optionally `-beta.1`) and plain digits without leading zeros. On Windows the build number is at most 65535. |
| `Release …/Tag … already exists` | Use a new `build_number`, or delete the old draft release (and its tag). |
| `GOOGLE_CLIENT_ID_… is empty` warning | Set the repository variable (§2.1). The build itself is fine. |
| `GOOGLE_REVERSED_CLIENT_ID … does not match` | Fix or clear the variable; the script derives it from `GOOGLE_CLIENT_ID_MAC`. |
| `Info.plist has no GoogleClientID key` warning / `Info.plist … is '…' but the build injected '…'` | `project.yml` does not map the build setting to the Info.plist key of the app. |
| `No /Applications/Xcode_26*.app found` | The runner image changed. Check the image README (§8) or set `XCODE_APP` in the workflow `env:`. |
| `project.yml must define targets DriveApp and DriveAppFileProvider` / `bundle ID is '…', expected …` / `is not an app extension` / `must set SKIP_INSTALL: YES` | `project.yml` does not match the contract: target names, `$(APP_BUNDLE_ID).fileprovider`, type `app-extension`, `SKIP_INSTALL: YES` on the extension. |
| `… claims restricted entitlements (…), so a Developer ID build needs MACOS_PROFILE_…` | Add the profile named in the message (§2.3), or remove `MACOS_CERT_P12_BASE64` for an unsigned build. |
| `MACOS_PROFILE_…: profile team/App ID/… ` / `does not authorise keychain-access-groups` | The profile does not fit. Regenerate it for that bundle ID as a Developer ID profile with the certificate from the `.p12`, and with the Keychain Sharing / App Groups capabilities enabled. |
| `Could not import the .p12` / `No valid 'Developer ID Application' identity` | Wrong password, a mangled base64 value, or a certificate without its key or of the wrong type. |
| `Expected DriveAppFileProvider.appex in Contents/PlugIns` | The app target does not embed the extension (`embed: true`). |
| `Unknown nested code …` (unsigned) | A new bundle type is embedded in the app. Teach `adhoc_sign_app` in `build-dmg.sh` about it. |
| `Nested code problems: …` (signed) | Nested code lacks the Developer ID signature, hardened runtime, timestamp or (if a profile was given) its embedded profile. Notarisation would reject it. |
| `Notarisation failed` | The log includes `notarytool log`. |
| `appsettings.json is missing from the publish output` | `DriveSync.App.csproj` must copy `appsettings.json` with `CopyToPublishDirectory`. |
| `dotnet publish did not produce DriveSync.App.exe` | The app's `AssemblyName` changed, or the project is not an executable. The script reads `AssemblyName` from the `.csproj`. |
| `signtool.exe not found` | The image changed. Check the Windows SDK in the image README. |
| `Could not open the .pfx` / `no private key` / `not valid for code signing` / `expired` | Re-export the certificate with its key, check the password, use a Code Signing certificate. |
| `signtool sign failed 3 times` | Usually the timestamp server. Re-run. |
| `Inno Setup failed` | The log shows the ISCC error with the line in `DriveApp.iss`. |
| Uninstall leaves a `WakeupMonster` entry in Explorer | The app's `--unregister` switch is missing or failed. It must unregister the sync root even when called by the uninstaller. |
| Core tests: `Expected exactly one solution in windows/` | Keep exactly one `.sln` in `windows/`. |
| Run cancelled while waiting | A newer run replaced it in the concurrency queue (§3). |

Logs are not uploaded as artifacts, on purpose. Mac `xcodebuild` logs are in `build/logs/` on the runner, and the script prints the last 60 lines on failure.

## 8. Decisions and evidence

### Runner images (checked 24 November 2026 in the [actions/runner-images README](https://github.com/actions/runner-images))

| Label | Image | Evidence |
| --- | --- | --- |
| `macos-26` | macOS 26 Arm64 (`macos-latest`, `macos-26`, `macos-26-xlarge`) | Xcode 26.x under `/Applications/Xcode_26.*.app`. The script picks the newest non-beta one. XcodeGen is not preinstalled, so it is installed with Homebrew. |
| `windows-2025` | Windows Server 2025 (`windows-latest`, `windows-2025`, `windows-2025-vs2026`) | [Image README](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-VS2026-Readme.md), image `20261116.315.1`: .NET SDKs 8.0.134 to 8.0.428 (plus 9, 10 and 11), Windows SDK 10.0.26100.0 (signtool), **Inno Setup 6.7.1**, PowerShell 7.6.10, GitHub CLI 2.104.0, Chocolatey 2.7.5. |
| `ubuntu-24.04` | Ubuntu 24.04 (`ubuntu-latest`, `ubuntu-24.04`) | Core tests. |

All three are pinned instead of using `*-latest`, so an OS change is a deliberate edit. The `windows-2025` label now points at the VS 2026 variant of the image. If Inno Setup ever disappears from it, the script installs the pinned Chocolatey package `innosetup 6.7.1` (the latest on community.chocolatey.org, 17 February 2026).

actionlint 1.7.7 does not know `macos-26`, so `.github/actionlint.yaml` declares it.

### Pinned actions and images

| Item | Pin | How checked |
| --- | --- | --- |
| `actions/checkout` | `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09` (v5.1.0) | `git ls-remote https://github.com/actions/checkout`: `refs/tags/v5.1.0` and `v5` point here. v5 runs on Node 24. v6.1.0 exists; v5 is kept because it is already in use. |
| `actions/setup-dotnet` | `26b0ec14cb23fa6904739307f278c14f94c95bf1` (v5.4.0) | `git ls-remote https://github.com/actions/setup-dotnet`: `refs/tags/v5.4.0` and `v5` point here (lightweight tags). v5 is used rather than v4.3.1 (`67a3573c…`) because v4 runs on Node 20, which GitHub is retiring from its runners. v5 needs runner 2.327.1+, which hosted runners have. |
| `swift` container | `swift:6.2.4-noble@sha256:576698469fd3cf95b2abdeb91a7571d3afcd91806c87283dd01d564803554c0f` | Docker Hub tags `6.2.4-noble` and `6.2-noble` both have this OCI index digest (registry `HEAD` on 24 November 2026). Local toolchain: Swift 6.2. |

### Other choices

- **Mac: archive, then export.** The signed path lets Xcode sign inside-out and re-sign for Developer ID on export.
- **Mac: unsigned builds don't let Xcode sign.** With `CODE_SIGN_IDENTITY=-`, Xcode still demands profiles for restricted entitlements ([Apple Developer Forums 751658](https://developer.apple.com/forums/thread/751658)). The script ad-hoc signs instead:
  - It reads entitlements from the target's real `CODE_SIGN_ENTITLEMENTS`.
  - It expands every `$(VAR)` / `${VAR}` from that target's build settings, with `DEVELOPMENT_TEAM` empty as Xcode would. Undefined settings become empty, with a warning.
  - It leaves out restricted keys.
- **Mac: the DMG is notarised and stapled**, not the app separately.
- **Windows: self-contained, folder publish** (not single-file). There is no runtime to install, and the Cloud Files and WinRT interop DLLs stay as ordinary files.
- **Windows: Inno Setup, per-user.** No admin prompt, and a sync client is per-user anyway. MSIX was not chosen: Cloud Files providers can be packaged, but an MSIX normally needs a trusted signature to install, which an unsigned test build cannot have.
- **Windows: only our binaries are signed.** Microsoft and NuGet binaries keep their own signatures.
- **No caching** in any workflow.
- **`scripts/validate-env.sh` was removed.** It checked FSKit-era requirements: macOS 26, SIP, the FSKit SDK and a spike test machine. `scripts/build-dmg.sh preflight` plus `select_xcode` now cover the generic checks on a build machine (macOS, Xcode 26 and its SDK, XcodeGen, tools).
- **Windows targets .NET 10 (LTS).** .NET 8 support ended on 10 November 2026, so `windows/` and both workflows use .NET 10 (`dotnet-version: 10.0.x`).

## 9. What is verified and what is not

Verified on Linux in this session (24 November 2026):

| Check | Result |
| --- | --- |
| `actionlint` (1.7.7, shellcheck integration) on all 3 workflows | pass |
| `shellcheck -x scripts/*.sh` (0.11.0) | pass |
| `yamllint -d relaxed .github/` | pass (line-length warnings only) |
| `scripts/ExportOptions.plist` parses (Python `plistlib`) | pass |
| `bash scripts/build-dmg.sh --help`; `build` on Linux stops with exit 3 after the input and config checks; invalid version exits 2; client ID / reversed ID mismatch stops; reversed ID derived; `cleanup` no-op | pass |
| `build-dmg.sh` entitlement resolver (perl `$(VAR)` expansion, undefined → empty) and restricted-key filter, on a sample entitlements file | pass |
| `build-windows.ps1`: PowerShell 7.4.6 parser (0 errors); PSScriptAnalyzer 1.23.0 (0 warnings or errors; only *Information* about positional arguments) | pass |
| `build-windows.ps1` help, invalid inputs (exit 2), non-Windows stop (exit 3), `cleanup` | pass |
| `build-windows.ps1 build -NoInstaller` on a scratch copy of the layout with stub projects: test run, self-contained `win-x64` and `win-arm64` publish, `FileVersion 0.1.0.7` / `ProductVersion 0.1.0-beta.1+build.7` in the binary, `appsettings.json` values injected, secret absent from the log, zips plus `.sha256` (`sha256sum -c` OK) | pass (not on the real `windows/` projects, which were being written at the same time) |

**Not run** (needs GitHub-hosted runners, a Mac with Xcode 26, or Windows):

- Any workflow run, including concurrency, timeouts, the `if: always()` cleanup and `gh release create`.
- Mac:
  - XcodeGen and `xcodebuild` against the new `project.yml`;
  - `-showBuildSettings` parsing on real output;
  - the unsigned archive and inside-out ad-hoc signing of `PlugIns/DriveAppFileProvider.appex`;
  - the signed path with and without profiles, export, notarisation;
  - the Info.plist configuration check;
  - installing and launching the app, and whether an ad-hoc-signed File Provider extension loads at all.
- Windows:
  - the real `DriveSync.App` publish;
  - Inno Setup compiling `DriveApp.iss` (syntax not checked: no ISCC on Linux);
  - Authenticode signing and verification;
  - the certificate store import and cleanup;
  - choco fallback;
  - installing, upgrading and uninstalling, including `--unregister`;
  - SmartScreen behaviour.
- Core tests in GitHub Actions. The `swift` container job and the `dotnet` job on `ubuntu-24.04` were not run there, and the real `Packages/DriveCore` and `windows/` code was not built here by this pipeline work.
