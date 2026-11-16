# Technical requirements and design

Draft v0.1 | 16 November 2026 | Proposed product design

TRD means Technical Requirements Document. This design is proposed for our product. It deliberately does not reproduce Feather Drive’s unrecovered private backend, algorithms or binary format.

## Implementation stack

Use Swift and Swift concurrency; SwiftUI with AppKit for native surfaces; FSKit for the Finder volume; URLSession for Drive REST; SQLite with GRDB for metadata and durable work. Keychain stores OAuth secrets. Xcode, XCTest, Instruments, codesign and notarytool support development and release.

## Process ownership

StorageService is the sole owner of token refresh, database mutations, cache admission and upload workers. Run it as an app-managed background service. The FSKit extension forwards directory and range requests over authenticated XPC; the UI submits imports and observes progress. Shared Swift types define requests and errors, not shared mutable ownership.

G0 must prove the exact service registration, XPC reachability, signing/entitlements and FSKit lifecycle on macOS 26. If it fails, do not assume a published Mach service is available: record an architecture decision for an extension-owned engine before implementing the rest.

## Local IPC contract

Expose listItems(cursor, limit), stat(itemID), readRange(itemID, revision, offset, length), cancel(requestID), beginImport(sourceBookmark), jobs(), clearReadCache() and status(). Authorize callers using code-sign identity/audit tokens. Cap read replies to 4 MiB and control messages to 1 MiB; split larger requested reads internally. Reject negative offsets, overflow and unknown accounts.

## Initial provider contract

Implement listPage, stat, readRange, beginUpload, uploadPart, queryUpload, finishUpload and changePage. R1 requires only Google Drive. Retain stable remote IDs and revisions. Introduce additional adapter types when the second provider is implemented; do not build a generic provider framework first.

## Auth and privileges

Use a native public-client browser OAuth flow with state and PKCE. Register production redirect behavior and app identity. The initial scope is drive.file; no claim of access to all existing Drive files. Broader permissions and verification are a separate R2 decision. [S2, S3]


# Read path and local persistence

## Range algorithm

- Validate item ID, account, pinned remote revision, offset and length. Return zero bytes for a zero-length request or a valid read at EOF. Clamp only the final range at EOF.
- Map the read to 4 MiB cache segments. Serve available immutable entries; combine simultaneous missing-segment requests. Limit network reads to 8.
- Pin a blob headRevisionId and use revision-specific media reads where the provider permits them. Never silently substitute current bytes for an unavailable pinned revision. Validate returned status and bounds; reject an unexpected full-body response.
- On detected remote revision change, invalidate current cache entries and fail/reopen safely. Do not splice old and new bytes. Revalidate metadata before starting a handle; test mutation during range responses.
- Return only the requested bytes. Cancel unused requests. Begin with one-segment sequential read-ahead; throttle it behind foreground requests and disable it during seek storms.

Drive binary blobs support byte ranges; Workspace exports follow another path and are excluded from R1. A 4 MiB cache segment is a proposed local unit, not evidence of the target app’s exact unencrypted format. [S4]

## Database records

| Table | Minimum fields |
| --- | --- |
| accounts | id, provider, remote_root_id, scope_mode, status |
| items | id, account_id, remote_id, parent_id, name, size, remote_revision, sync_state |
| uploads | job_id, account_id, staged_path, source_bookmark, state, session_secret_ref, acknowledged_offset, remote_id, digest |
| segments | account_id, item_id, revision, segment_index, cache_path, byte_count, last_access |
| change_cursors | account_id, remote_cursor, last_success_at |

## Persistence rules

Use migrations and foreign keys. Keep database transactions short and never perform network calls while holding a transaction. Cache files are immutable, atomically published and validated against their index. If metadata and cache disagree after a crash, discard the disposable cache entry, never an upload stage.

Staging lives in protected Application Support, outside the evictable read cache. Session URLs are bearer capabilities: store protected references and never log them. Core storage access is owned by the service; filesystem permissions and App Group configuration must match the tested deployment model.


# Upload state machine and recovery

## Import states

selected -> staging -> queued -> uploading -> verifying -> committed. Side states: waiting_network, needs_login, needs_space, retrying, cancelling and cancelled. Each transition is durable before it is presented as complete. A selected source is not yet an accepted job.

## Admission and transport

Resolve the security-scoped source; copy a stable snapshot into staging and compute its digest. If the source changes during staging, reject and restage. Enforce the free-space reserve. Flush staged content and persist the queue before showing queued. Release the original bookmark only when no longer needed.

Attach a unique job ID to remote app metadata. Start a resumable upload, persist the session secret reference, and advance progress only to acknowledged server offsets. Use 8 MiB transport chunks in R1; the final chunk may be shorter. The part size and encryption segment size are separate concepts. [S5]

## Commit and ambiguous completion

After completion, verify remote size and provider checksum when available. If the provider checksum cannot be compared with the local digest, retain staging and verify through a controlled read-back before marking committed. Reconcile job-ID metadata after a lost final response so retries do not produce duplicate visible items. Show the file in Finder only after verification.

## Cancellation and cleanup

Cancel further requests, query possible completion and resolve the race. If committed, retain the remote file and report completion. If incomplete, preserve a resumable/discardable staged job. Clear cache never touches staging. Remove staging only after verified commit and a crash-safe record transition, or an explicit recoverable user discard.

## Failure policy

Refresh authentication once when appropriate; surface revoked consent as needs_login. Retry transient network/429/5xx failures with jittered exponential backoff, respecting provider guidance. Treat quota and permissions as user-action states. A foreground read has a 30-second deadline including retries; uploads have durable background retry state.

## Later encryption boundary

Before enabling encryption, freeze and independently review a versioned authenticated segment format, key hierarchy, recovery and migration plan. Define nonce uniqueness across rewrites and bind file identity, index and finality. Encrypt staging/cache according to the threat model. Do not add an unreviewed cipher format inside an upload task.

