# Repository, CI and test builds

Draft v0.1 | 16 November 2026 | Proposed workflow

How to go from a GitHub repo and a cloud coding session to a DMG you can install and test, without filling GitHub storage.

## 1. Facts that shape the plan (checked 16 Nov 2026)

| Fact | Consequence |
| --- | --- |
| Claude Code cloud sessions run in an **Ubuntu 24.04 x86_64 VM**, with no Xcode or macOS tooling. | A cloud session can write Swift code and push it, but **cannot build, sign or notarise the Mac app or produce a DMG**. Pure-Swift logic in `Packages/StorageCore` (range maths, cache policy, state machines) can be unit-tested on Linux if a Swift toolchain is installed in the environment. Verify in the first session. |
| Cloud sessions output only pushed branches, PRs and diffs. | The DMG must come from a **macOS build machine**: GitHub Actions macOS runners, or this Mac. |
| The founder's Mac: Apple M4, Xcode 26.0.1, **macOS 15.7.1**. | It can **build** against the macOS 26 SDK, but **cannot run** the app: FSKit volume features and our minimum OS are 26+. Testing needs macOS 26 (see §4). |
| One claude.ai account holds **one GitHub connection at a time** (`/web-setup` replaces it). The Claude GitHub App can be installed on several accounts or orgs. | See §5 for multiple accounts. |
| GitHub **Release assets** have no total-size or bandwidth limit (max 2 GiB per file) and are not billed as storage. **Actions artifacts** and Packages count toward the account's storage quota. | Publish DMGs as Release assets (or external storage), **never** as Actions artifacts. Verify against GitHub's current billing docs before relying on it. |
| Private repos get a limited number of free Actions minutes, and macOS minutes are billed at a multiplier (historically 10×). Public repos run free. | About 200 real macOS minutes a month on the free plan for a private repo. Keep CI builds lean (see §3). |

## 2. Recommended workflow

```
Cloud session (Linux)          GitHub                        Founder
──────────────────────         ──────────────────────        ─────────────────────────
write Swift code      ──push──▶ PR / branch
run StorageCore tests           │
                                ▼
                         Actions: macOS runner
                         xcodebuild → sign → notarise
                         → create DMG
                                │
                                ├─▶ GitHub Release asset (pre-release, tag v0.0.x-bN)
                                └─▶ or Cloudflare R2 / S3 bucket (signed URL)
                                                               download DMG ──▶ install
                                                               on macOS 26 test Mac
                                                               record results in validation/
```

Alternative (simplest for G0): run a **local** Claude Code session on this Mac (the desktop app's Code tab with the repo folder). It can run `xcodebuild` directly, so no CI minutes are needed. Copy the built app to the macOS 26 test machine. Use cloud sessions for parallel or background work once the build pipeline exists.

## 3. CI workflow outline (P)

`.github/workflows/build-dmg.yml`, triggered on tag push `v*` or manual dispatch, **not** on every commit, to save macOS minutes.

1. `runs-on`: a macOS runner image with Xcode 26 (use the macOS 26 image if GitHub offers one, otherwise a macOS 15 image with Xcode 26 selected). Check the runner-images list.
2. Select Xcode: `sudo xcode-select -s /Applications/Xcode_26.x.app`.
3. Import signing certificate (Developer ID Application) from secrets into a temporary keychain.
4. `xcodebuild archive` → `xcodebuild -exportArchive` with `ExportOptions.plist` (method `developer-id`).
5. Create DMG (`hdiutil create` or `create-dmg`).
6. Notarise: `xcrun notarytool submit --wait` using an App Store Connect API key from secrets, then `xcrun stapler staple`.
7. Upload: `gh release create v0.0.x-bN --prerelease app.dmg`, or `aws s3 cp` / `rclone` to R2.
8. Do **not** use `actions/upload-artifact` for the DMG (it uses storage quota). If you must, set `retention-days: 1`.

Run unit tests on Linux, or on the macOS runner only for PRs that touch native code.

### Secrets needed

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application certificate |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | notarytool API key |
| `R2_*` (optional) | External DMG storage |
| Provisioning profiles (if the FSKit entitlement requires them) | Confirm in G0 |

Google OAuth client IDs for desktop apps are public identifiers (PKCE, no secret), but keep separate dev and prod clients in config, not hard-coded across builds.

## 4. Where to test the DMG

The app needs **macOS 26+**. Options, in order of preference:

1. **A second Mac, or this Mac upgraded to macOS 26.** Most realistic (Finder, extension approval, real network). Back up first: upgrading is the founder's decision.
2. **A macOS 26 virtual machine on this M4** (UTM or another Apple Virtualization-based tool). Cheap and disposable, good for G0. Confirm that FSKit extension enablement works inside a VM; treat it as a G0 check, not an assumption.
3. **A cloud Mac** (for example a rented Apple Silicon Mac with macOS 26) for occasional runs.

Gatekeeper: a DMG that isn't notarised will be blocked on another Mac. FSKit extensions need correct signing and entitlements, so the **Apple Developer Program (US$99/yr)** is effectively required before G0 can pass on a clean machine (already in 07-setup-costs).

## 5. GitHub accounts

- **You probably don't need a second account.** Source code is small; "storage full" on GitHub usually means the Actions/Packages (or LFS) quota, which source repos don't use. Keep DMGs in Releases or R2 and the existing account works. Check *Settings › Billing › Usage* to see which quota is full.
- **On your Mac:** `gh` supports several logged-in accounts (`gh auth login` again, then `gh auth switch`). Git can use per-repo credentials or SSH host aliases.
- **In Claude Code cloud sessions:** one GitHub connection per claude.ai account at a time. Switching (`/web-setup` with a different `gh` login) replaces the previous one. You can install the Claude GitHub App on **several accounts or orgs**.
- **If you do use the second account:** the cleanest setup is a free **GitHub organization** owned by the second account, with your main account added as a member/owner. Install the Claude GitHub App on that org and keep your main account as the connected identity. Whether being a plain collaborator on a personal repo is enough for the App wasn't confirmed in the docs; use the org route to be safe.

## 6. Repository bootstrap checklist (P)

- [ ] Choose product name and bundle IDs (app, FS extension, service) before the first signed build; changing them later resets Keychain/App Group data.
- [ ] Create a private repo; add `docs/` (this pack) and `AI-HANDOFF.md` at the root.
- [ ] Layout from 06-build-plan: `App/`, `FileSystemExtension/`, `StorageService/`, `Packages/StorageCore/`, `Tests/`, `validation/`, `docs/`.
- [ ] `.gitignore`: `build/`, `DerivedData/`, `*.dmg`, `*.xcarchive`, `*.p12`, `*.p8`, `.env`.
- [ ] Add CI only after B01 builds locally; first CI job = build + sign + notarise the empty spike.
- [ ] Branch protection on `main`; every PR from a cloud session reviewed before merge.
- [ ] Tell the cloud session explicitly: it cannot run `xcodebuild`, so it must not claim native tests passed (AI-HANDOFF already requires marking them blocked).

## Sources

- https://code.claude.com/docs/en/cloud-environments.md (Ubuntu VM, installed tools)
- https://code.claude.com/docs/en/web-quickstart.md (GitHub App per account/org, `/web-setup` replaces connection)
- https://code.claude.com/docs/en/claude-code-on-the-web.md (GitHub authentication options)
- https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases (release asset limits)
- https://docs.github.com/en/billing (Actions minutes and storage; check current numbers)
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
