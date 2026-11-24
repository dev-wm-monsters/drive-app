# Shared-drive sync: product and behaviour spec

Draft v0.1 | 24 November 2026 | Branch `claude/shared-drive-sync` | Founder-directed scope

This branch builds a Mac and Windows client for one Google Workspace **Shared Drive named `WakeupMonster`**. For this branch it replaces the R1 scope in [01 PRD](01-prd.md): there is no FSKit volume, no app-created root under `drive.file`, and no menu-bar import queue. Decision record: [ADR09](adr/ADR09-file-provider-and-cloud-files.md). Google setup: [15 Google Cloud setup](15-google-cloud-setup.md). Builds: [12 Pipeline usage](12-pipeline-usage.md).

Nothing native has been built or run yet. Only the Linux unit tests can run in the cloud session.

## Scope v1

| In | Out (v1) |
| --- | --- |
| 4+ Workspace users, one Shared Drive (`WakeupMonster`), or one shared folder by ID | Personal Gmail accounts, My Drive, several roots |
| Mac (macOS 14+, Apple Silicon) and Windows 10/11 x64 desktop apps | Phone apps. Phones use the Google Drive app. |
| Whole tree visible in Finder / Explorer with metadata, nothing downloaded | Offline pinning ("keep downloaded") |
| Open a file → it downloads on demand | Streaming partial reads |
| Add **new** files → upload | Edit, rename, move or delete existing items, new folders |
| Changes polled every 30 s while the app runs | Push notifications, our own server |
| Same-name files shown with ` (2)`, ` (3)` … | Merge or conflict handling |

## User flows

| Flow | What the user sees | Pass condition |
| --- | --- | --- |
| Phone upload | A user uploads `clip.mp4` with the Drive app on iPhone or Android. | It appears on every running Mac and Windows client **within 60 s** of the phone finishing (target ~30–45 s). |
| Browse | Finder / Explorer shows every folder and file with size and dates. | Disk use for the tree stays near zero. Cloud icons show files are not local. |
| Open | Double-click a file. | It downloads, then opens in the usual app. The second open is local. Checksum matches Drive (`md5Checksum`). |
| Add new file | Drag a file into any folder of the tree. | It uploads to that Drive folder. If the name exists, the uploaded name gets ` (2)` etc. Others see it within 60 s. |
| Rename / move / delete / edit an existing item | Finder / Explorer refuses with a permission error. | Nothing changes in Drive. No local copy is lost. |
| Someone renames or deletes in Drive | The item updates or disappears. | Within 60 s. A downloaded copy is removed only from the local cache, never from Drive. |

## Per-platform mechanism

| Platform | Mechanism |
| --- | --- |
| Mac | Menu-bar app `DriveApp` + `NSFileProviderReplicatedExtension` (`DriveAppFileProvider`). Items are dataless until opened; `fetchContents` downloads; `createItem` uploads; modify/delete are refused. Shared code: `Packages/DriveCore`. |
| Windows | .NET 8 app registers a Cloud Files sync root at `%USERPROFILE%\WakeupMonster` with an Explorer nav-pane entry. Placeholders for every item; the fetch-data callback downloads; new local files upload; rename/delete callbacks are refused. Code: `windows/`. |
| Both | Google Drive REST v3, OAuth code + PKCE, `drive` scope, changes API every 30 s. Rules: [Google API rules](#google-api-rules). |
| Phones | Google Drive app. No code of ours. |

## Google API rules

Both platforms follow these. Shared code: `DriveCore` (Swift) and the `windows/` Core library (C#).

| Topic | Rule |
| --- | --- |
| Scopes | `https://www.googleapis.com/auth/drive`, `openid`, `email` |
| OAuth | Authorization code + PKCE (S256) + `state`. Mac: Google **iOS** client, redirect `<reversed client id>:/oauth2redirect` via `ASWebAuthenticationSession`. Windows: **Desktop app** client, loopback `http://127.0.0.1:<random port>/`, client secret sent at token exchange. |
| Every call | `supportsAllDrives=true`; list and changes also `includeItemsFromAllDrives=true`. Shared-drive mode: `corpora=drive&driveId=<id>` on list, `driveId=<id>` on changes. |
| Root | `drives.list` with `name = 'WakeupMonster'`: exactly one → its ID is the root folder ID. 0 → root not found. >1 → ambiguous; set the folder/drive ID. |
| List | `files.list`, `'<parent>' in parents and trashed = false`, `pageSize=1000`, all pages. |
| Download | `files.get?alt=media` (Range allowed). Verify `md5Checksum` after full downloads. Write to a temp file, then rename. |
| Changes | `changes.getStartPageToken` once, then `changes.list` every 30 s. Folder mode: no `driveId`; keep only changes under known folders. |
| Upload | Resumable, 8 MiB chunks; on interruption ask the server for the received range and continue. Metadata `{name, parents:[folderId]}`. |
| Retries | 429, 5xx, 403 `rateLimitExceeded` / `userRateLimitExceeded`: exponential backoff with full jitter, 1 s base, 32 s cap, 5 attempts, honour `Retry-After`. 401: refresh once, then sign-in needed. `invalid_grant`: sign-in needed. |
| Logs | Never log tokens, auth codes or upload session URLs. File names only at debug level. |

## Display names

Drive allows several files with the same name in one folder. Finder and Explorer do not. Both apps compute the display name with the same algorithm. Test vectors: [`spec/name-vectors.json`](../spec/name-vectors.json). Swift and C# tests must both pass every vector.

1. **sanitize(name):** NFC-normalize. Replace each of `/ \ : * ? " < > |`, U+0000–U+001F and U+007F with `_`. Trim trailing spaces and dots. Empty → `_`. If the part before the first `.`, uppercased, is one of `CON PRN AUX NUL COM1…COM9 LPT1…LPT9`, append `_` to that part (`CON.txt` → `CON_.txt`).
2. **split(name):** the extension starts at the **last** `.`, unless that `.` is at index 0. `.bashrc` → stem `.bashrc`, ext `""`. `a.tar.gz` → `a.tar` + `.gz`.
3. **key(name)** = sanitize(name), lowercased per character (Swift `lowercased()`, C# `ToLowerInvariant()`), except U+0130 `İ`, which stays unchanged so both platforms agree (Swift would expand it to `i` + U+0307).
4. **assign(children of one folder):** drop hidden items (Workspace docs, shortcuts, trashed). Sort by `createdTime` ascending, then `id` ordinal ascending. `taken = {}`. For each item: `candidate = sanitize(name)`, `n = 2`; while `key(candidate)` is in `taken`: `candidate = stem + " (" + n + ")" + ext`, `n += 1`. Add `key(candidate)` to `taken`; `display[id] = candidate`.
5. **uniqueUploadName(desired, existing):** the same loop with `taken = {key(x) for x in existing}`, starting from `sanitize(desired)`. Our uploads pick a free name up front, so we never create a new duplicate.

The oldest file keeps the plain name, so a later upload never renames what users already see. Deleting the oldest copy shifts the numbers; that is accepted in v1.

## Metadata shown

| Field | Mac | Windows |
| --- | --- | --- |
| Name (display), folder/file, size | Yes | Yes |
| Created, modified time | Yes | Yes |
| Kind (from extension / MIME type) | Yes | Yes |
| Downloaded or cloud-only | Finder cloud icon | Explorer status column |
| Thumbnail, last modified by, video duration and dimensions | Best effort; not promised in v1 | Best effort; not promised in v1 |

## Limits

| Limit | Detail |
| --- | --- |
| Workspace only | Shared Drives exist only in Google Workspace. The OAuth app is **Internal**, so only accounts in the founder's Workspace can sign in. |
| `drive` scope | Full Drive access, needed to see files that phones uploaded. Allowed without Google verification because the app is Internal. The Workspace admin may still need to mark it Trusted ([15](15-google-cloud-setup.md#4-workspace-admin-checks)). |
| Latency | Polling every 30 s. A phone upload shows up after the phone finishes plus up to ~30 s plus platform refresh. Target ≤ 60 s. Nothing updates while the app is closed. |
| Offline | The tree stays visible. Files that were never opened cannot be opened offline. |
| Google Docs, Sheets, Slides, shortcuts | Hidden in v1 (no file bytes to download). |
| No edit, no merge | Existing items are read-only. To change a file, edit a copy and add it as a new file. |
| Quota | Drive API: 325,000 quota units per user per minute and 1,000,000 per project per minute; 750 GB upload per user per day; 5 TB max file. Our 30 s poll costs ~200 units per user per minute. See [15 › Quotas](15-google-cloud-setup.md#6-quotas). Rate-limit errors back off up to 32 s. |
| Large videos, disk space | Opening a file downloads the whole file. A 20 GB video needs 20 GB free. The OS may evict downloaded copies when space is low; they download again on next open. |
| Mac unsigned build | Gatekeeper blocks first launch: System Settings › Privacy & Security › **Open Anyway**. An unsigned or ad-hoc File Provider extension may not load at all; a Developer ID signed and notarised build is expected for real use. Not yet verified. |
| Windows unsigned build | SmartScreen shows "Windows protected your PC": **More info › Run anyway**. |
| Where the files appear | Mac: Finder sidebar under **Locations** (File Provider domain), stored under `~/Library/CloudStorage/`. Windows: Explorer nav pane entry `WakeupMonster`, folder `%USERPROFILE%\WakeupMonster`. |

## Requirements and traceability

Unit = automated tests that run on Linux: `Packages/DriveCore` (`swift test`) and the `windows/` Core tests (`dotnet test`). Manual = acceptance tests below, on real machines. Native results are **not run** until evidence exists under `validation/`.

| ID | Requirement | Unit | Manual |
| --- | --- | --- | --- |
| SD-FR01 | Sign in with a Workspace account: code + PKCE (S256) + state; tokens only in the OS secure store | PKCE, auth URL, token exchange/refresh (fake transport) | SD-AT02, SD-AT14 |
| SD-FR02 | Resolve root: Shared Drive by name (0 → not found, >1 → ambiguous), or folder ID override | Root resolve cases | SD-AT02 |
| SD-FR03 | Show the whole tree with metadata without downloading | Listing, paging, field parsing | SD-AT03 |
| SD-FR04 | Download on open; verify `md5Checksum`; atomic write | Download, MD5 mismatch | SD-AT04, SD-AT12 |
| SD-FR05 | Existing items are read-only (no edit, rename, move, delete) | — | SD-AT07 |
| SD-FR06 | New files upload (resumable, 8 MiB chunks, resume after interruption); no new folders | Resumable upload, 308 resume | SD-AT06, SD-AT13 |
| SD-FR07 | Uploads pick a free name up front | `uniqueUploadName` vectors | SD-AT06, SD-AT08 |
| SD-FR08 | Display names per the algorithm above, identical on Mac and Windows | `sanitize` and `assign` vectors | SD-AT08 |
| SD-FR09 | Hide Workspace docs, shortcuts and trashed items | Hidden-item vectors | SD-AT10 |
| SD-FR10 | Poll changes every 30 s; apply adds, updates, removals; ≤ 60 s end to end | Changes paging, folder-mode filter | SD-AT05, SD-AT09 |
| SD-FR11 | Retry 429 / 5xx / rate-limit 403 with backoff; 401 → refresh once → sign-in needed | Retry policy, 401 path | SD-AT11 |
| SD-FR12 | No tokens, auth codes or upload URLs in logs; file names only at debug level | Log redaction (where testable) | SD-AT14 |
| SD-FR13 | Never delete user data in Drive; local cleanup only removes cached copies | No delete call exists | SD-AT07, SD-AT09 |
| SD-FR14 | Viewer-role users can browse and download; adding a file fails with a clear message | — | SD-AT15 |

## Manual acceptance tests

Setup: 4 Workspace test users, members of `WakeupMonster` (3 Content managers, 1 Viewer). One Mac (macOS 14+, Apple Silicon), one Windows 10/11 PC, one iPhone and one Android phone with the Google Drive app. Use test files only, never anyone's real originals. Save each result as `validation/<BUILD>/<OS>/<TEST_ID>/result.json` ([validation/README](../validation/README.md)).

| ID | Run on | Steps | Pass |
| --- | --- | --- | --- |
| SD-AT01 | Mac, Win | Install the unsigned build; get past Gatekeeper / SmartScreen; launch. | App starts; Mac: `WakeupMonster` appears under Finder › Locations (allow the extension if macOS asks); Windows: nav-pane entry appears. |
| SD-AT02 | Mac, Win | Sign in as user A. Then try an account outside the Workspace. | `WakeupMonster` resolves; outside account refused (`org_internal`). |
| SD-AT03 | Mac, Win | Browse every folder. Check sizes and dates against drive.google.com. Check free disk space before and after. | Tree and metadata match; disk use grows < 50 MB. |
| SD-AT04 | Mac, Win | Open a photo, a PDF and a 500 MB video. Open them again. Compare MD5 with Drive. | Each opens; second open is instant; MD5 matches. |
| SD-AT05 | iPhone, Android → Mac, Win | Upload a photo from each phone. Time until it shows on both desktops. | ≤ 60 s on both. |
| SD-AT06 | Mac, Win | Drag a new file into a subfolder; then drag a file with an existing name. | Both appear on phones and the other desktop ≤ 60 s; second one named `… (2)…`. |
| SD-AT07 | Mac, Win | Try to rename, move, delete, and edit-and-save an existing file and folder. | Every attempt refused; drive.google.com unchanged. |
| SD-AT08 | All | From two phones upload `same.jpg` to one folder. | Mac and Windows both show `same.jpg` and `same (2).jpg` with the same mapping. |
| SD-AT09 | Phone → Mac, Win | On a phone rename one file and delete another. | Both desktops reflect it ≤ 60 s; nothing else changes. |
| SD-AT10 | Mac, Win | Create a Google Doc, a shortcut and trash a file in the drive. | None of them is shown. |
| SD-AT11 | Mac, Win | Turn the network off: browse, open a downloaded and a cloud-only file. Turn it on. | Tree visible; downloaded file opens; cloud-only fails with a clear error; changes resume after reconnect. |
| SD-AT12 | Mac, Win | Open a ≥ 4 GB video; repeat with less free disk space than the file. | First downloads and plays; second fails cleanly with no partial file left. |
| SD-AT13 | Mac, Win | Add a ≥ 1 GB file; cut the network mid-upload for 1 minute; restore. | Upload resumes and completes; exactly one copy in Drive. |
| SD-AT14 | Mac, Win | Sign out; sign in; revoke the app at myaccount.google.com › Security; wait one poll. Grep logs for tokens. | Sign-in needed is shown; no tokens or codes in logs; no local files deleted. |
| SD-AT15 | Mac or Win | Sign in as the Viewer user; open a file; try to add one. | Download works; add refused with a clear message; nothing uploaded. |
