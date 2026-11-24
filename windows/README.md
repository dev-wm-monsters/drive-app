# DriveApp for Windows (`windows/`)

Tray app that shows the Google **Shared Drive `WakeupMonster`** (or one shared folder, by ID) in File Explorer
as a **Cloud Files sync root** at `%USERPROFILE%\WakeupMonster`: Explorer nav-pane entry, cloud status icons,
placeholders with real names/sizes/dates, contents downloaded only when a file is opened. Existing items are
read-only; new files dropped into the folder are uploaded. Product rules and Google API facts come from the
binding contract (Contract v2); display names follow the shared algorithm checked by `spec/name-vectors.json`.

Target: **.NET 10 (LTS)**, Windows 10 2004 (19041) or later, Windows 11 recommended. x64 and arm64.

## Layout

```
windows/
  DriveApp.sln                 the only solution; CI builds it
  global.json                  SDK 10.0.100, rollForward latestFeature
  Directory.Build.props        Version 0.0.1 (override: -p:Version=x.y.z), Nullable, TreatWarningsAsErrors,
                               LangVersion latest, Deterministic, analyzers (latest-recommended)
  src/DriveSync.Core/          net10.0, cross-platform, no Windows APIs (all the testable logic)
  src/DriveSync.Windows/       net10.0-windows10.0.19041.0: cfapi interop, sync-root registration, DPAPI
  src/DriveSync.App/           net10.0-windows10.0.19041.0 WinForms tray app → DriveSync.App.exe
  tests/DriveSync.Core.Tests/  xUnit tests for Core (run on Linux/macOS/Windows)
```

### DriveSync.Core (portable)

| Area | Files | Notes |
|---|---|---|
| Config | `Config/DriveAppConfig.cs` | Reads `Google:ClientId`, `Google:ClientSecret`, `Drive:SharedDriveName`, `Drive:FolderId`, `Sync:RootFolderName`, `App:Name`, `App:Id`; `Validate()` lists problems. Poll interval 30 s. Scopes `drive openid email`. |
| Display names | `Names/DisplayNames.cs` | Contract algorithm: NFC (`Normalize(FormC)`), forbidden chars → `_`, trailing space/dot trim, reserved device names, split at last dot, key = `ToLowerInvariant()`, sort `(createdTime, id ordinal)`, `" (n)"` suffixes, `UniqueUploadName`. |
| Drive client | `Drive/GoogleDriveService.cs`, `DriveFields.cs` | Official `Google.Apis.Drive.v3`. Every call `supportsAllDrives=true`; list/changes `includeItemsFromAllDrives=true`; shared drive → `corpora=drive&driveId=…` (list) / `driveId` (changes). Field masks are the contract's verbatim. Root resolve via `drives.list q=name = '…'` (0 → rootNotFound, >1 → rootAmbiguous) or `files.get(FolderId)`. Range download (`alt=media` + `Range`). Resumable upload, 8 MiB chunks. |
| Retries | `Drive/RetryPolicy.cs`, `RetryHandler.cs` | 429 / 5xx / 403 `rateLimitExceeded`/`userRateLimitExceeded` → full-jitter exponential backoff, base 1 s, cap 32 s, max 5 attempts, `Retry-After` honoured. Plugged into the Google client's `ConfigurableMessageHandler`; the client's own back-off is disabled. 401 → the `UserCredential` refreshes once; a second 401 or `invalid_grant` → `NeedsLogin`. |
| OAuth | `Auth/GoogleAuthService.cs`, `LoopbackCodeReceiver.cs`, `ITokenStore.cs` | Authorization code + **PKCE S256** via Google.Apis.Auth's `PkceGoogleAuthorizationCodeFlow` (verified in tests: `code_challenge_method=S256`, challenge = base64url(SHA-256(verifier)), `code_verifier` + `client_secret` sent at exchange) + **state** added and checked by our loopback receiver (`http://127.0.0.1:<random port>/`, raw `TcpListener`, no URL ACL/admin). Tokens persist only through `ITokenStore` (Google's plaintext `FileDataStore` is never used). |
| Sync | `Sync/RemoteTree.cs`, `SyncPlanner.cs`, `SyncEngine.cs`, `PlaceholderIdentity.cs`, `HydrationMath.cs` | `RemoteTree` = snapshot of visible items + changes feed (folder-mode relevance filter). `SyncPlanner` = pure diff → `CreatePlaceholder / MovePlaceholder / UpdatePlaceholder / DeletePlaceholder / Upload / Hydrate / Dehydrate`. `SyncEngine` = initial listing, 30 s polling, reconcile, upload queue. `HydrationMath` = 4 KiB alignment rules for `TRANSFER_DATA`. |
| Logging | `Logging/LogRedactor.cs` | Masks bearer/access/refresh/ID tokens, auth codes, `upload_id`, client secret in every log line. |

### DriveSync.Windows (Cloud Files)

| File | Role |
|---|---|
| `NativeMethods.txt` | CsWin32 input: `CfCreatePlaceholders`, `CfExecute`, `CfUpdatePlaceholder`, `CfConvertToPlaceholder`, `CfSetInSyncState`, `CfGetPlaceholderInfo`, `CfHydratePlaceholder`, `CfDehydratePlaceholder`, `CfReportProviderProgress`, `CfRegisterSyncRoot`, `CfUnregisterSyncRoot`, `CfDisconnectSyncRoot`, structs, `STATUS_CLOUD_FILE_*`. |
| `CloudFiles/CloudFilesProvider.cs` | `CfConnectSyncRoot` with a callback table (`[UnmanagedCallersOnly]` stdcall function pointers). FETCH_DATA is copied and served on the thread pool; CANCEL_FETCH_DATA cancels the matching transfer key; NOTIFY_DELETE/NOTIFY_RENAME are acknowledged inline: allowed only for our own process, otherwise `STATUS_CLOUD_FILE_ACCESS_DENIED`; NOTIFY_FILE_CLOSE_COMPLETION from other processes triggers a local pass. Every callback that needs an answer always gets a `CfExecute`. |
| `CloudFiles/HydrationService.cs` | Range download → `CfExecute(TRANSFER_DATA)` in 1 MiB chunks, 4 KiB-aligned (last chunk may end at EOF), progress via `CfReportProviderProgress`, resume-on-error with the retry policy, MD5 check on full-file hydration (last chunk failed on mismatch), failures reported with `STATUS_CLOUD_FILE_*`. |
| `CloudFiles/CloudFilesPlaceholderSystem.cs` | `IPlaceholderSystem` on cfapi: scan (`CfGetPlaceholderInfo` → identity + in-sync), create (dehydrated, in-sync, `FILE_ATTRIBUTE_READONLY` for files, folders fully populated), move/rename, update (dehydrate on content change), delete, convert after upload, hydrate/dehydrate for pin state. |
| `Registration/SyncRootRegistrar.cs` | Registration and full unregistration (see decision below). |
| `Storage/DpapiTokenStore.cs` | `ProtectedData` CurrentUser + app entropy at `%LOCALAPPDATA%\WakeupMonster\DriveApp\token.bin`. |
| `WindowsSyncHost.cs`, `LocalChangeWatcher.cs` | Composition: sign-in → register → connect → initial sync → poll timer + debounced `FileSystemWatcher`. |

**Why CsWin32 (not Vanara):** `Microsoft.Windows.CsWin32` generates P/Invokes and struct layouts from Microsoft's
own Win32 metadata (the same source as `cfapi.h`), so unions such as `CF_CALLBACK_PARAMETERS` and
`CF_OPERATION_PARAMETERS` are exact. It is a compile-time generator with no runtime dependency, and it runs on
Linux, so CI can build the Windows projects. One manual piece: CsWin32 projects `CF_CALLBACK` as a marshalled
delegate, which makes `CF_CALLBACK_REGISTRATION` non-blittable. `CloudFilesProvider` therefore passes a blittable twin
with an unmanaged function pointer to a `LibraryImport` of `CfConnectSyncRoot`, and checks at runtime that its size
matches `Marshal.SizeOf<CF_CALLBACK_REGISTRATION>()`.

### DriveSync.App (tray)

`DriveSync.App.exe` (the AssemblyName is fixed; the installer and CI rely on it). The tray menu has:
- a status line: "Connected to WakeupMonster as <email>" or the current status
- Sign in with Google…
- Open folder
- Upload files… (picked files are copied into the root and then take the normal upload path)
- Sync now
- Start at login (HKCU `Run` value `DriveApp` = `"…\DriveSync.App.exe" --background`)
- Sign out…
- Quit

A single-instance mutex (`Local\<App:Id>.SingleInstance`) stops a second copy from starting. Settings are read
from `appsettings.json` next to the exe, then from `DRIVEAPP_*` environment variables (for example
`DRIVEAPP_Google__ClientId`). Logs go to `%LOCALAPPDATA%\WakeupMonster\DriveApp\logs\driveapp-YYYYMMDD.log`,
pass through redaction and are kept for 14 days. File names are logged only at Debug level (`DRIVEAPP_DEBUG=1`).

Command-line switches:
- `--background`: start in the tray without opening Explorer (used by Start at login).
- `--unregister`: **for the uninstaller**. Run it after `taskkill`. It shows no UI and always exits 0, even
  when nothing is registered. It removes WinRT sync roots whose ID starts with `<App:Id>!<SID>!` and runs
  `CfUnregisterSyncRoot` on the folder. It also removes the fallback nav-pane keys and the Run entry. Files in
  the folder are left in place: dehydrated placeholders there become unusable and can be deleted by hand.
  `CfUnregisterSyncRoot` fails while a provider is connected, which is why the app must be killed first.

Sign out (after a confirmation) does these steps in order:
1. Disconnects.
2. Moves files that were never uploaded to `Documents\WakeupMonster - not uploaded <timestamp>`.
3. Unregisters the sync root and the nav-pane entry.
4. Deletes `%USERPROFILE%\WakeupMonster`. Everything is still in Drive, and hydrated copies are discarded too.
5. Revokes the refresh token and deletes `token.bin`.

Quit only disconnects. The folder stays registered, and opening a dehydrated file while the app is not running
shows Windows' "cloud provider is not running" error.

## Registration decision: unpackaged app, `StorageProviderSyncRootManager` first, cfapi + nav-pane keys as fallback

The app ships **unpackaged**, with no MSIX.

1. **Primary:** `Windows.Storage.Provider.StorageProviderSyncRootManager.Register(StorageProviderSyncRootInfo)`.
   It is called from a plain desktop process through the C#/WinRT projection included in the
   `net10.0-windows10.0.19041.0` TFM. This is the documented, standard registration path, and one call also
   creates the branded Explorer nav-pane node.
   - The settings are: ID `<App:Id>!<user SID>!default`, `DisplayNameResource` = `WakeupMonster`, icon `DriveSync.App.exe,0`.
   - Hydration policy `Full` with `AutoDehydrationAllowed`. Population policy `AlwaysFull` (we create every placeholder ourselves).
   - In-sync policy `FileReadOnlyAttribute | FileLastWriteTime | PreserveInsyncForSyncEngine`, `AllowPinning`, and a fixed `ProviderId`.
2. **Fallback**, used if `Register` throws (for example, if a future Windows build demanded package identity):
   - `CfRegisterSyncRoot` with the same policies (`CF_REGISTER_FLAG_UPDATE | MARK_IN_SYNC_ON_ROOT`).
   - Plus the nav-pane namespace-extension keys from Microsoft's *Integrate a Cloud Storage Provider*, steps 1–12.
     They are written under **HKCU only**, so no admin rights are needed. The CLSID is derived deterministically from the sync-root ID so `--unregister` can find it.
   - The HKLM `SyncRootManager` keys from that page are not written, because they need admin rights and
     `CfRegisterSyncRoot` itself makes the cfapi side work.

Evidence and reasoning:
- The `StorageProviderSyncRootManager` reference lists the requirement "Windows Desktop Extension SDK (introduced in
  10.0.16299.0)". It does not mention package identity. *Build a Cloud Sync Engine that Supports Placeholder Files*
  says "Registering a sync root with the cloud files API causes that sync root … to appear in File Explorer's
  navigation pane" and that the Windows.Storage.Provider API "enable[s] applications to … register the sync root".
- The same page says cloud sync engines "are designed to use the Desktop Bridge as an implementation requirement".
  Microsoft's CloudMirror sample is packaged (CloudMirrorPackage). Its manifest declares the `cloudFiles` extension
  for shell COM handlers: custom state icons, thumbnails, context-menu verbs and status UI. We ship none of those in
  v1, so package identity is not needed for the features we use.
- Community evidence: a public spike (gkrost/unidrive-windows issue #38) reports that `Register` works without
  elevation or package identity and creates the nav-pane CLSID. The Nextcloud desktop client is an MSI install that
  ships unpackaged and uses `CfRegisterSyncRoot` plus explicitly written registry keys, which is the same shape as
  our fallback.
- `CfRegisterSyncRoot` needs only WRITE_DATA/WRITE_DAC on the folder ("or the registration will fail with
  ERROR_CLOUD_FILE_ACCESS_DENIED"). There is no identity requirement.
- **Not verified here:** whether unpackaged `Register` succeeds on the target Windows 11 builds, and which path
  ran. The log says either "Registered sync root with StorageProviderSyncRootManager" or "falling back to
  CfRegisterSyncRoot". If we later need custom state icons, thumbnails or context-menu verbs, the plan is an MSIX
  (or a sparse package with external location) that declares `cloudFiles:CloudFiles`.

## Key behaviours

- **Placeholders:** the app creates one for every non-hidden item. Workspace docs, shortcuts and trashed items are
  hidden. Each placeholder has the Drive size and created/modified times, and its display name comes from the
  shared algorithm. Each placeholder's FileIdentity holds a small JSON blob (`PlaceholderIdentity`) with the Drive
  file ID, md5, size and times. FETCH_DATA uses it to know what to download, and the planner uses it to detect
  remote changes without a local database.
- **Remote changes**, applied every 30 s from `changes.list`, or on Sync now:
  - New items get placeholders, and deleted items lose theirs.
  - Renames and moves move the placeholder, including display-name shifts of duplicate siblings. Swaps go through a temporary `~wm-move-<id>` name.
  - Content changes update the placeholder and dehydrate it. Metadata-only changes update it without dehydrating.
  - A folder that is removed remotely but still holds files that were never uploaded is kept, with a warning.
- **Read-only:**
  - User deletes and renames/moves arrive as NOTIFY_DELETE / NOTIFY_RENAME and are rejected with
    `STATUS_CLOUD_FILE_ACCESS_DENIED`, so Explorer refuses them. A balloon explains why, at most once every 10 s.
  - Files carry `FILE_ATTRIBUTE_READONLY`.
  - If something edits a file in place anyway (after clearing read-only), the placeholder drops out of in-sync.
    The planner emits `UpdatePlaceholder(DiscardLocalChanges)`, which restores the Drive version: it sets the file
    in-sync, then dehydrates it. If the file is pinned, it is deleted and re-created instead.
- **Uploads:**
  - A new non-placeholder file in the root or in a synced folder is uploaded once its size and mtime have been
    stable for 3 s and no other process has it open for writing. Lock and temp names (`~$*`, `*.tmp`, `*.crdownload`, …) are ignored.
  - Right before uploading, the app lists the folder again and picks a free name with `UniqueUploadName`, then does
    a resumable upload.
  - **The local file is then converted in place** with `CfConvertToPlaceholder(identity = Drive ID, MARK_IN_SYNC)`,
    followed by `CfUpdatePlaceholder` to set Drive's timestamps and then read-only. This was chosen over
    delete-and-recreate for these reasons:
    1. The bytes stay local, so there is no re-download, and Explorer shows "available on this device" right away.
    2. There is no window where the file disappears, and no in-flight data is lost if the delete happened to succeed while an app held the file.
    3. It works the same at any depth.
  - If the display name differs from the local name (a race with a phone upload of the same name), the next plan renames the placeholder.
  - If the conversion fails because the file is busy, the Drive item is remembered and only the conversion is
    retried. After a crash between upload and conversion, an identical Drive sibling (same size, md5 and name key)
    is adopted instead of being uploaded twice.
  - New folders are not uploaded in v1. The user gets a balloon.
- **Pinning:** "Always keep on this device" triggers `CfHydratePlaceholder` in the background, and "Free up space"
  triggers `CfDehydratePlaceholder`.
- **Folder mode** (`Drive:FolderId`): if the folder lives in a shared drive, list and changes use that drive's ID,
  because changes without `driveId` don't include shared-drive items. A folder in My Drive uses the user corpus,
  without `driveId`, as the contract says. `RemoteTree` keeps only changes whose parent is a known folder (or whose ID is already known).

## Build and test

```bash
cd windows
dotnet restore
dotnet build -c Release -p:EnableWindowsTargeting=true          # all four projects, zero warnings (warnings are errors)
dotnet test tests/DriveSync.Core.Tests -c Release
dotnet publish src/DriveSync.App -c Release -r win-x64 --self-contained \
  -p:EnableWindowsTargeting=true -p:PublishSingleFile=false -o <out-dir>
```

`EnableWindowsTargeting` is also set in `Directory.Build.props`, so the flag is optional. `appsettings.json` is
copied to the build and publish output (`CopyToPublishDirectory=PreserveNewest`). CI should overwrite
`Google:ClientId`, `Google:ClientSecret`, `Drive:SharedDriveName` and `Drive:FolderId` in the **published** copy.
The repository copy keeps empty placeholders. The app refuses to start, with a dialog listing the problems, while
`Google:ClientId` or `Google:ClientSecret` is empty.

Google Cloud setup: create a **Desktop app** OAuth client in the Workspace project, with an Internal consent screen
and the Drive API enabled. Desktop clients accept any `http://127.0.0.1:<port>/` redirect, so nothing needs to be
registered.

### NuGet packages (exact pins)

| Package | Version | Project |
|---|---|---|
| Google.Apis.Drive.v3 | 1.78.0.4327 | Core |
| Google.Apis.Auth (→ Google.Apis / Google.Apis.Core 1.78.0) | 1.78.0 | Core |
| Microsoft.Extensions.Configuration.Abstractions | 10.0.15 | Core |
| Microsoft.Extensions.Logging.Abstractions | 10.0.15 | Core |
| Microsoft.Windows.CsWin32 (build-time only) | 0.3.371 | Windows |
| System.Security.Cryptography.ProtectedData | 10.0.15 | Windows |
| Microsoft.Extensions.Configuration.Json | 10.0.15 | App, Tests |
| Microsoft.Extensions.Configuration.EnvironmentVariables | 10.0.15 | App |
| Microsoft.Extensions.Logging | 10.0.15 | App |
| xunit / xunit.runner.visualstudio / Microsoft.NET.Test.Sdk | 2.9.3 / 3.1.5 / 18.11.1 | Tests |

## What is verified and what is not

Verified on Linux with .NET SDK 10.0.115:
- restore, and a Release build of the whole solution with zero warnings and zero errors.
- `dotnet test`: every case in `spec/name-vectors.json` (sanitize, assign and uniqueUploadName, loaded from the
  current file at test time), plus tests for:
  - planner scenarios: new remote file and folder, remote rename with a sibling display-name shift, swap via temp name, case-only rename, move between folders, remote delete, folder delete protecting un-uploaded files, duplicates, hidden docs ignored, content vs metadata change, in-place edit revert, local new file → Upload, temp files, local folders, pin/unpin, race with a phone upload
  - remote tree and changes relevance
  - the sync engine end to end against fakes
  - config validation, using the shipped `appsettings.json`
  - retry delays and classification
  - exact Drive request parameters through the real Google client with a fake HTTP handler: `supportsAllDrives`, `includeItemsFromAllDrives`, `corpora`/`driveId`, `fields`, `q`, paging, `alt=media` + `Range`, resumable upload init, retry and `Retry-After`
  - PKCE S256, state checking and code decoding in the loopback receiver
  - 4 KiB transfer alignment
  - log redaction
- `dotnet publish` for win-x64, self-contained, which produces `DriveSync.App.exe` together with `appsettings.json`.

**Not run (needs Windows)**: everything that touches cfapi, WinRT, Explorer, DPAPI, the registry or WinForms. That
covers sync-root registration (WinRT or fallback), `CfConnectSyncRoot` and the callbacks, placeholder creation,
updates, conversion and hydration, status icons, the nav pane, delete and rename rejection, the tray UI and
`--unregister`. Also not run is the real Google OAuth and Drive traffic.

## Manual test plan (Windows 11, x64)

Prerequisites:
- A Workspace account that can see the `WakeupMonster` shared drive, with a few videos and images in it.
- At least two files with the same name, a Google Doc, a subfolder and a 1 GB+ video.
- A published build with real `Google:ClientId` and `Google:ClientSecret`.

1. **Launch and sign in:** run `DriveSync.App.exe`. A tray icon appears and the balloon says to sign in. Choose
   *Sign in with Google…*: the browser opens on accounts.google.com, the URL contains `code_challenge_method=S256`
   and `state=`, and the redirect goes to `127.0.0.1:<port>`, which shows the "Signed in" page. The status shows
   "Connected to WakeupMonster as <email>". `token.bin` exists, is not readable as text and has no
   plaintext tokens. The log contains no `ya29.` or `1//` strings.
2. **Registration:** Explorer's nav pane shows **WakeupMonster** with the app icon. The log says which registration
   path was used. The folder `%USERPROFILE%\WakeupMonster` exists.
3. **Placeholders:**
   - Every Drive item appears with its correct size and modified date, with the cloud status icon. Nothing is downloaded yet, and the disk use of the folder is about 0.
   - Duplicates appear as `name.ext`, `name (2).ext` in createdTime order. The Google Doc is not shown. Names with `:` or `?` appear with `_`.
   - Folders open without delay.
4. **Hydration:**
   - Open a small image: it opens, the icon turns into a green check, and the log shows the range download.
   - Open the 1 GB video in a player: playback starts after a progress indication, and the size on disk grows.
   - Cancel a large copy halfway (copy the file to the desktop, then press Cancel): the app logs no errors, and a later open resumes.
   - Disconnect the network and open a dehydrated file: Windows shows an error. It does not hang.
5. **Read-only:**
   - Deleting a file or a folder is refused by Explorer and the balloon appears.
   - Renaming is refused, and moving out of the folder (drag to the desktop with Shift) is refused.
   - Notepad *Save* on a hydrated `.txt` fails because the file is read-only.
   - Clear the read-only attribute in Properties, then edit and save: within about 30 s the file is restored to
     the Drive version and the balloon says local changes were discarded.
6. **Remote changes**, made from the phone or drive.google.com, each checked within about 30 s:
   - Upload a file: it appears.
   - Rename it: the name changes locally.
   - Rename the older of two duplicates: the newer one becomes `name.ext`.
   - Move a file between folders: it moves.
   - Delete or trash a file: it disappears.
   - Replace a file's content: the next open downloads the new version.
   - Add a Google Doc: nothing appears.
7. **Uploads:**
   - Drag a new video into the root, or into a subfolder. The cloud/sync icon shows, and after the copy finishes
     and about 3 s pass, the upload starts. When it is done, the file is a read-only, in-sync placeholder (green
     check) and appears on drive.google.com under the same name.
   - Drop a file whose name already exists remotely, with a different case, while a phone uploads the same name:
     the free-name logic gives `name (2).ext`.
   - Use *Upload files…* in the tray for several files.
   - Create a new folder in the root: a balloon says folders aren't uploaded.
   - Keep a file open for writing, for example a long copy: it is not uploaded until the file is closed.
8. **Pinning:** "Always keep on this device" on a folder hydrates its files in the background. "Free up space"
   dehydrates them.
9. **Lifecycle:**
   - Quit: the nav pane entry stays, and opening a dehydrated file shows "cloud provider not running".
   - Relaunch: there is no sign-in prompt and sync resumes.
   - Toggle *Start at login*, sign out of Windows and back in: the app starts in the tray.
   - Start a second instance: it exits at once.
10. **Sign out:**
    - Choose *Sign out…* and confirm. The folder and the nav-pane entry disappear, any un-uploaded file moves to
      `Documents\WakeupMonster - not uploaded …`, and `token.bin` is deleted.
    - Sign in again: everything is re-created.
11. **Uninstall path:** run `taskkill /im DriveSync.App.exe /f`, then `DriveSync.App.exe --unregister`.
    - The exit code is 0, no window appears, the nav-pane entry is gone, and the Run value is gone.
    - Running it a second time also exits with 0.
    - Check that `HKLM\…\Explorer\SyncRootManager` has no `WakeupMonster.DriveApp.Dev!<SID>!default` key.
12. **Misconfiguration:** with empty `Google:ClientId`, the app shows the configuration dialog and exits. With
    two shared drives named WakeupMonster, a balloon asks for `Drive:FolderId`.

## Known limitations (v1)

- The local scan opens a handle per item on each pass, which is fine for thousands of items. Very large drives
  would want a USN-journal or watcher-driven incremental scan.
- The change token is not persisted. Every start does a full listing.
- Resumable upload sessions are not resumed across app restarts. The same upload restarts, and duplicate detection
  avoids a second copy.
- There are no thumbnail or custom-state shell extensions, which would need package identity (see the registration decision).
- Explorer's exact wording for rejected deletes and renames depends on the `STATUS_CLOUD_FILE_*` code. We use
  `STATUS_CLOUD_FILE_ACCESS_DENIED`. Verify this on Windows.
