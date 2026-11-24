# DriveCore

Swift package shared by the Mac app (`DriveApp`) and its File Provider extension (`DriveAppFileProvider`).
It talks to Google Drive v3 and Google OAuth. It uses Foundation only (plus FoundationNetworking on Linux)
and has no external dependencies. Swift 6 language mode, strict concurrency, macOS 14+. It also builds and
tests on Linux.

The API is fixed by Contract v2 ("DriveCore public API"). Shared rules: `docs/14-shared-drive-sync.md`.

## API overview

| Type | Purpose |
| --- | --- |
| `DriveConfig`, `RootSelector` | Client ID, optional secret, redirect URI, scopes (`drive openid email`), root, 30 s poll interval. `fromInfoDictionary` reads `GoogleClientID`, `DriveRootFolderID` (wins if non-empty) and `DriveRootSharedDriveName`. Empty or unexpanded `$(...)` values count as missing. `iOSClientRedirectURI(reversedClientID:)` builds `<reversed id>:/oauth2redirect`. |
| `PKCE` | S256 pair with a 64-character verifier. `PKCE(verifier:)` is for test vectors. |
| `OAuthClient` | `authorizationURL(pkce:state:)` (with `access_type=offline` and `prompt=consent`), `exchange`, `refresh`. Form-encoded token requests; `client_secret` is sent only when it is non-nil. The email comes from the id_token payload without a signature check (see below). `invalid_grant` → `.needsLogin`. |
| `AuthSession` (actor) | `accessToken()` refreshes when fewer than 60 s remain. Concurrent callers share one in-flight refresh. Before it refreshes, it re-reads the `TokenStore`, because the other process may have refreshed already. Also has `signIn(_:)`, `signOut()`, `isSignedIn`, `email` and `forceRefresh(rejecting:)`, which `DriveClient` uses after a 401. |
| `TokenStore`, `InMemoryTokenStore` | Token persistence. The app supplies a Keychain store. The in-memory store is for tests and previews. |
| `HTTPTransport`, `URLSessionTransport` | The only network seam. Non-2xx responses are returned, not thrown. |
| `DriveClient` (actor) | `resolveRoot`, `listChildren`, `file`, `download`, `downloadRange`, `startPageToken`, `changes`, `upload`. Conveniences: `allChanges`, `folderIndexSnapshot`, `restoreFolderIndex`. |
| `RetryPolicy` | Up to 5 attempts in total. Delay is `random(0 … min(32 s, 1 s · 2^(n-1)))` (full jitter). `Retry-After` replaces the computed delay (capped at 300 s). Retries 429, 5xx, rate-limit 403s and transport errors. `jitter` and `sleep` can be injected. |
| `DisplayNames` | `sanitize`, `assign`, `uniqueUploadName`: the shared algorithm, checked against `spec/name-vectors.json`. |
| `FolderIndex` | Folder-mode membership (known folders and items) that filters the changes feed. |
| `Hashing` | Pure-Swift MD5 (file streamed in 1 MiB chunks) and SHA-256 (`sha256Base64URL` for PKCE). |
| `DriveFile`, `DriveRoot`, `DriveChange`, `ChangeBatch`, `DriveError` | Models. `DriveFile.isHidden` = trashed, shortcut or Workspace doc. `Codable` on `DriveFile` is DriveCore's own flat form, not Google JSON. |

### Behaviour notes

- **Request parameters.** Every Drive call sends `supportsAllDrives=true`. List and changes calls also send `includeItemsFromAllDrives=true`.
  Shared-drive mode adds `corpora=drive&driveId=…` to list calls and `driveId=…` to changes calls. `drives.list` and `drives.get` are not
  file methods, so they do not get `supportsAllDrives`.
- **Root.** `.sharedDriveNamed` pages through `drives.list?q=name = '…'` and keeps exact name matches. 0 matches → `rootNotFound(name)`.
  More than 1 → `rootAmbiguous(ids)`. `.folderID` must be a folder that is not trashed; otherwise → `rootNotFound(id)`.
- **Errors.** 401 → one forced refresh and one retry, then `.needsLogin`. 404 → `notFound`, with no retry. 403 with
  `rateLimitExceeded`/`userRateLimitExceeded` (or `RESOURCE_EXHAUSTED`) → `rateLimited`. 403 with
  `storageQuotaExceeded`/`quotaExceeded` → `quotaExceeded`. Any other 403 → `forbidden(reason)`. 5xx → `server(code)`.
- **Download.** The body streams to a hidden temp file in the destination's directory. If an MD5 is given, it is checked
  (case-insensitive). Then the temp file is atomically `rename(2)`d over the destination. On failure the temp file is
  removed and the destination is left as it was.
- **downloadRange.** Requires `206`. A `200` (the server ignored `Range`) → `invalidResponse`. A short body is accepted only
  when `Content-Range` shows end of file. Extra bytes are trimmed. `416` → empty data.
- **changes.** Returns one page. The caller loops on `nextPageToken` and stores `newStartPageToken`. A change that is removed,
  trashed or hidden → `.removed(fileID:)`.
  - **Folder mode.** The feed covers the whole account, so `DriveClient` keeps a `FolderIndex`. It is filled from `listChildren`
    (the listed folder and every visible child) and from processed changes. A change is kept if its parents include a known
    folder or its ID is already known. A known item whose parents leave the tree is reported as removed.
  - **Folder mode, `removed: true`.** These entries carry no parents, so they are always reported.
  - **Folder mode, restarts.** After a process restart, re-seed the index with `restoreFolderIndex` (persist `folderIndexSnapshot()`).
    Otherwise list the tree again. Removing a folder from the index does not remove its descendants.
- **Upload.**
  - **Name.** The parent's visible children are listed. The new name must not clash with their raw names or their display
    names (`DisplayNames.uniqueUploadName`).
  - **Session.** A resumable session is started (`X-Upload-Content-Length`/`-Type`, JSON `{name, parents}`, `fields` = `DriveClient.fields`).
  - **Chunks.** `PUT` 8 MiB chunks with `Content-Range`. A `308` resumes from the server's `Range`.
  - **Interruptions.** A network error, 5xx or rate limit leads to backoff, then a status query (`Content-Range: bytes */total`), then a resume.
  - **Expired session.** A 404/410 on the session restarts the upload once.
  - **MIME type.** Comes from a small extension table; unknown extensions use `application/octet-stream`.
- **id_token.** The email is decoded from the payload without signature verification. This is acceptable because the token came
  straight from Google's token endpoint over TLS (OIDC Core §3.1.3.7), and the email is used only for display.
- **Logging.** DriveCore does not log. Error payloads never contain tokens, auth codes or upload session URLs. Transport errors
  are reduced to `URLError <code>`, because `URLError` descriptions can contain the request URL.

## Testing

```sh
cd Packages/DriveCore
swift build -Xswiftc -warnings-as-errors
swift test
```

The XCTest suite (`Tests/DriveCoreTests`) uses a `FakeTransport` that records requests and replays scripted or dynamic
responses. A fake resumable-upload server is included. Retry sleeps are recorded, not slept. It covers:

- MD5 vectors (RFC 1321), SHA-256 vectors (NIST) and the PKCE example (RFC 7636 App. B)
- auth URL, exchange, refresh, `invalid_grant`, and coalesced concurrent refresh
- config parsing and root resolution
- listing: pagination, hidden filtering and exact query parameters
- the error mapping table, retry/backoff and 401 handling
- download with MD5 check; `downloadRange` 206 / 200 / EOF / 416
- changes: paging, mapping and folder-mode filtering
- upload: name collision, 20 MiB + 1 chunk boundaries, 308 partial resume, interruption → status query → resume, 5xx, expired session, zero bytes
- every case in `spec/name-vectors.json`, loaded relative to `#filePath`

## Not covered

- Real Google endpoints (no live credentials in CI).
- Darwin-only code paths: `URLSessionTransport.download` uses `URLSession.download(for:)` on macOS, but on Linux it buffers
  through `data(for:)`. The package has not been compiled on macOS from this Linux box. Xcode builds are **not run** here.
- Persisting a resumable upload session across process restarts, and cancelling the session on the server.
- Keychain `TokenStore` (lives in the app), token revocation on sign-out.
- Unicode casing beyond what the vectors cover. Collision keys follow .NET `ToLowerInvariant`: per-scalar lowercase mapping,
  except that U+0130 is left unchanged.
