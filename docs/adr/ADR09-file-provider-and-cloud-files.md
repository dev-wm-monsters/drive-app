# ADR09 File Provider on Mac, Cloud Files on Windows

Draft v0.1 | 24 November 2026 | Status: **Accepted** (founder-directed, 24 November 2026; not yet proven by device evidence)

Branch `claude/shared-drive-sync`. Spec: [14 Shared-drive sync](../14-shared-drive-sync.md).

## Context

- The founder's real need: 4+ people share a Google Workspace Shared Drive `WakeupMonster`. Phones upload with the Google Drive app. Macs and Windows PCs must see the whole tree in Finder / Explorer without downloading it, download a file when it is opened, and add new files.
- Existing files are uploaded by others, so the app needs the full `drive` scope, not `drive.file`. An **Internal** Workspace OAuth app may use it without Google verification.
- Windows is now in scope. An FSKit volume is Mac-only and needs macOS 26.
- Both OSes have a built-in "cloud files" framework that shows placeholders and downloads on open: Apple File Provider and the Windows Cloud Files API.

## Decision

| Part | Choice |
| --- | --- |
| Mac | Sandboxed menu-bar app + `NSFileProviderReplicatedExtension`, macOS 14+, Apple Silicon. Shared Swift package `DriveCore`. |
| Windows | .NET 8 app using the Cloud Files API (sync root + placeholders + fetch-data callback). |
| Cloud API | Google Drive REST v3 directly, no Google SDK. OAuth code + PKCE. Mac: iOS-type client with reversed-client-ID scheme. Windows: Desktop client with loopback. |
| Updates | Poll the changes API every 30 s while the app runs. No server of ours. |
| Write policy | Existing items read-only. New files upload. No new folders, no edits, no deletes. |
| Names | Display-name disambiguation identical on both platforms ([14 › Display names](../14-shared-drive-sync.md#display-names)). |

## Alternatives

| Option | Why not (now) |
| --- | --- |
| FSKit read-only volume (B01 spike) | Mac-only, macOS 26+, unproven service/XPC arrangement (ADR03). Kept on branch `claude/beautiful-goldberg-dr7wlu`. |
| Google Drive for desktop | Exists, free, does this on Mac and Windows. Reasons to build anyway: we control the read-only + add-new policy (Drive for desktop lets Content managers edit, move and delete), same-name disambiguation, and a base for later features. **The founder should confirm this is worth building** — it is the cheapest alternative. |
| FUSE (macFUSE) / WinFsp | Third-party kernel extension or driver to install. macFUSE's kernel extension needs Reduced Security on Apple Silicon. No cloud status icons in Finder / Explorer. |
| A server that mirrors Drive | Costs money, holds user data and tokens. Not needed for 4 users. |
| Drive push notifications instead of polling | Need a public HTTPS endpoint, so a server. 30 s polling is within quota. |

## Consequences

- Downloads are whole-file. Large videos need equal free disk space. No streaming partial reads.
- Updates stop while the app is closed; latency is ~30–60 s.
- The `drive` scope sees everything the user can see; the app filters to the one root. A Workspace admin with Drive Restricted must mark the app Trusted.
- Two codebases (Swift and C#) must stay identical in naming and API behaviour; `spec/name-vectors.json` enforces naming.
- Unsigned test builds hit Gatekeeper / SmartScreen. The File Provider extension likely needs a Developer ID signed build to load; not yet verified.

## Changes to earlier decisions (this branch only)

| ADR | Was | Now |
| --- | --- | --- |
| ADR01 | Native Swift and FSKit | Native Swift and **File Provider** on Mac; C#/.NET 8 and Cloud Files on Windows |
| ADR02 | One Drive account, `drive.file`, app-created root | One Workspace account per user, **`drive` scope, Internal app**, Shared Drive root |
| ADR03 | Single storage service (XPC) | **Superseded** by this ADR. The File Provider extension owns its own Drive client. |
| ADR04 | Read-only Finder volume | **Read-only existing items + add new files** |
| ADR07 | New objects only, suffix duplicates | Kept: uploads pick a free name; display names add ` (n)` |

## Evidence

None yet. This is accepted on the founder's direction. It is proven when SD-AT01–SD-AT15 in [14](../14-shared-drive-sync.md#manual-acceptance-tests) pass on a Mac and a Windows PC, with results under `validation/`.
