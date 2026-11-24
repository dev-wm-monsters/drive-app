# AI handoff: shared-drive sync

Draft v0.2 | 24 November 2026 | Branch `claude/shared-drive-sync`

## Read first, in this order

1. [docs/14-shared-drive-sync.md](docs/14-shared-drive-sync.md): scope, Google API rules, display-name algorithm, requirements SD-FR01…, acceptance tests SD-AT01….
2. [docs/15-google-cloud-setup.md](docs/15-google-cloud-setup.md): OAuth client types, config names, Shared Drive roles.
3. [docs/adr/ADR09-file-provider-and-cloud-files.md](docs/adr/ADR09-file-provider-and-cloud-files.md): why File Provider + Cloud Files, what changed from the FSKit plan.
4. [docs/12-pipeline-usage.md](docs/12-pipeline-usage.md): builds, repo variables and secrets.

Docs 01–08 describe the older FSKit R1 plan. Where they conflict with 14, 14 wins on this branch. The FSKit spike is on branch `claude/beautiful-goldberg-dr7wlu`; do not bring it back here.

## Hard rules

- **No secrets in the repo.** No tokens, client secrets, real client IDs, certificates, keys or DMGs. Config placeholders stay `""`; CI injects real values.
- **Never claim a native pass.** No Xcode, Windows, Mac or phone in a Linux cloud session. Mark every native build and device test **not run** / **blocked**. Blocked never counts as pass.
- **Existing items stay read-only.** No code path may edit, rename, move, trash or delete a Drive item. The only write is creating a new file (and its resumable upload).
- **Never delete user data.** Local cleanup may remove only our cached copies. Never touch a user's originals.
- **Disposable test accounts and files only.** Never use the founder's or users' real accounts for automated tests. Do not connect a real account without the founder's go-ahead.
- **Display names:** Swift and C# must pass every vector in `spec/name-vectors.json`. Change the algorithm only together with the vectors and doc 14.
- **Logs:** never log tokens, auth codes or upload session URLs; file names only at debug level.
- Do not upgrade the OS, weaken signing, sandbox or security settings, or spend money without the founder's approval.
- Stay in scope (doc 14). No edits, renames, deletes, new folders, extra providers, encryption or payments in v1.

## Build and test on Linux

```sh
# Swift core (Swift 6)
cd Packages/DriveCore && swift build && swift test

# Windows (.NET 8) - builds Windows-targeted projects on Linux; runs only the cross-platform tests
cd windows && dotnet build -p:EnableWindowsTargeting=true && dotnet test -p:EnableWindowsTargeting=true

# Workflows and scripts
actionlint && shellcheck scripts/*.sh
```

Mac app and File Provider extension need Xcode on macOS (`xcodegen generate`, then `xcodebuild`; see doc 12). The Windows app needs Windows 10/11 to run.

## When you finish a task

Return: files changed, exact commands run and their real results, what was not run and why, and which SD-FR / SD-AT IDs the change affects. Save device evidence under `validation/<BUILD>/<OS>/<TEST_ID>/result.json` ([validation/README.md](validation/README.md)).
