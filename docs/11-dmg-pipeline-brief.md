# DMG pipeline brief

Draft v0.1 | 16 November 2026 | Task for the first cloud session

## Goal

Add a GitHub Actions pipeline that builds the Mac app and packages it as a DMG. **Write it, validate it statically, commit it. Do not run or trigger it.**

## Hard rules

- Do not run the workflow, dispatch it, push tags, or create releases.
- Trigger **only** on `workflow_dispatch`, with inputs for `version` (e.g. `0.0.1`) and `build_number`. Add no `push`, `pull_request` or `schedule` triggers.
- Never commit DMGs, `.p12`, `.p8`, provisioning profiles, keychains or `.env` files. Add them to `.gitignore`.
- **Never** use `actions/upload-artifact` for the DMG, because GitHub storage quota is limited. Upload the DMG as a **GitHub Release asset** (pre-release, draft) instead.
- The cloud session runs on Linux with no Xcode, so it can't build locally. Don't claim a build passed. Validate with `actionlint` and `shellcheck` only.

## What to create

```
.github/workflows/build-dmg.yml   # the pipeline
scripts/build-dmg.sh              # all build logic; the workflow just calls it
scripts/ExportOptions.plist       # developer-id export
project.yml                       # XcodeGen spec (generated into .xcodeproj on the runner)
App/                              # minimal placeholder app, only so the pipeline has a target
.gitignore
docs/12-pipeline-usage.md         # how to add secrets and run it later
```

### Placeholder app (keep tiny)
A macOS 26+ SwiftUI menu-bar app (`LSUIElement`) that shows its version. No features, no FSKit yet. B01 adds the FSKit extension target to `project.yml` later. Use temporary bundle ID `com.wakeupmonster.driveapp.dev` and name `DriveApp` until the founder picks a product name; put both in one place (`project.yml` settings) so they're easy to change.

Use **XcodeGen** so no hand-written `.xcodeproj` is committed. Generate it on the runner (`brew install xcodegen && xcodegen generate`).

## Workflow steps

1. `runs-on`: a macOS runner image with Xcode 26 (prefer a macOS 26 image if listed in actions/runner-images, otherwise macOS 15 with Xcode 26). Pin the image name, not `macos-latest`.
2. Checkout; select Xcode 26 with `xcode-select`; print `xcodebuild -version`.
3. Install XcodeGen; generate the project.
4. **Signing is optional and secret-driven:**
   - If `MACOS_CERT_P12_BASE64` is set: create a temporary keychain, import the Developer ID Application cert, sign with hardened runtime.
   - If not set: ad-hoc sign (`-`) and name the DMG `…-unsigned.dmg`. The pipeline must still succeed.
5. `xcodebuild archive` (Release, `arm64` only for now; ADR08 says Apple Silicon first) → `-exportArchive` (or copy the `.app` from the archive when unsigned).
6. Create the DMG with `hdiutil create` (UDZO), including an `/Applications` symlink. Name it `DriveApp-<version>-<build>.dmg`.
7. **Notarise only if** `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8_BASE64` are set: `xcrun notarytool submit --wait`, then `xcrun stapler staple`. Otherwise skip with a clear log line.
8. Print the SHA-256 of the DMG.
9. Create a **draft pre-release** `v<version>-b<build>` with `gh release create --draft --prerelease` (`GITHUB_TOKEN`, `permissions: contents: write`) and attach the DMG and its `.sha256`.
10. Always delete the temporary keychain and decoded key files (`if: always()`).

Add `concurrency` so two builds don't overlap. Use a `timeout-minutes` of about 30 and cache nothing large.

## Secrets (documented in 12-pipeline-usage.md; none exist yet)

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application certificate |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain |
| `APPLE_TEAM_ID` | Signing team |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | Notarisation (App Store Connect API key) |

## Done when

- `actionlint` passes on the workflow and `shellcheck` passes on the script.
- `xcodegen` spec is valid YAML and describes one app target.
- `docs/12-pipeline-usage.md` explains: adding secrets, running via *Actions › Build DMG › Run workflow*, where the DMG appears (draft release), and that unsigned DMGs need right-click › Open on macOS 26.
- Report: files changed, validation commands and output, and anything that can only be verified on a macOS runner (mark these **not run**).

## Context

Repo note: this repo is **public**, so GitHub Actions macOS minutes are free, and secrets stay hidden. Product docs: `docs/00-start-here.md` to `docs/10-repo-ci-and-test-builds.md`. Pipeline background is in `docs/10-repo-ci-and-test-builds.md` §3.
