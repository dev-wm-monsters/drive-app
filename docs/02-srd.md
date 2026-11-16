# Software requirements specification

Draft v0.1 | 16 November 2026 | Proposed product design

SRD means Software Requirements Document in this pack. It defines observable behavior, not internal implementation. All requirements below are proposed R1 acceptance criteria unless marked as roadmap work.

| ID | Capability | Required behavior |
| --- | --- | --- |
| FR01 | Account connection | Use browser-based Google OAuth with PKCE and state validation. Create or reuse one app-managed root with drive.file access. A cancelled consent creates no mounted account. |
| FR02 | Session lifecycle | Store refresh tokens in Keychain; restore a permitted session; revoke/disconnect safely. Stop new jobs and unmount before deleting credentials. Pending uploads require a clear retain or export choice. |
| FR03 | Volume lifecycle | Mount only after account and extension readiness. Cleanly unmount on explicit disconnect. If the engine is unavailable, return a controlled filesystem error rather than stale success. |
| FR04 | Directory metadata | Expose stable item IDs, names, sizes and hierarchy from an index; page remote listings. Exclude unsupported Workspace documents in R1 and explain the limitation. |
| FR05 | Byte reads | Return exactly the requested bytes up to EOF; support zero-length reads, seeks and cancellation. Never return bytes from an earlier remote revision as current. |
| FR06 | Bounded read cache | Default disk payload cap 1 GiB, adjustable 256 MiB to 8 GiB. Account and revision scope every entry. Cache clearing does not touch upload staging. |
| FR07 | Import admission | Accept a job only after a complete stable staged snapshot and durable queue record exist. Check free space and show progress before the job becomes queued. |
| FR08 | Resumable upload | Persist session references and server-acknowledged offsets. On restart query server status, then resume or restart an expired session without losing staged bytes. |
| FR09 | Commit visibility | Create new remote objects only. Keep them hidden from the volume until verified. Reconcile ambiguous completion against job ID metadata before creating a replacement upload. |

Traceability: each ID maps to one or more tests in the test plan. A requirement marked blocked is not silently treated as implemented. FR01 scope details follow official Google guidance. [S2, S3]


# Functional requirements and edge behavior

| ID | Capability | Required behavior |
| --- | --- | --- |
| FR10 | Progress and cancellation | Report progress from server-confirmed bytes. Stop future upload requests on cancel, reconcile a commit race, and retain staged data until the user chooses a recoverable discard. |
| FR11 | Offline operation | Serve validated cached data when available. Return a clear error for missing ranges. Newly accepted staged jobs wait locally until connectivity returns. |
| FR12 | Read-only Finder beta | Deny Finder create, write, rename and delete with correct read-only errors. Direct the user to menu-bar import. Do not claim general editing compatibility. |
| FR13 | Filename search | Search the local metadata index case-insensitively. Open or reveal committed results. Never advertise content search or access to the entire cloud account. |
| FR14 | Storage controls | Display cache, staging and metadata separately. Permit safe cache clearing and queue inspection. Do not represent Finder allocation as total app disk use. |
| FR15 | Errors and diagnostics | Map revoked access, quota, timeout, low disk and remote deletion to actionable states. Diagnostics require opt-in and remove tokens, session URLs, filenames and content. |
| FR16 | Distribution | Release an appropriately signed and notarized beta with a verified update path or a documented manual-update path. A failed update must preserve the previous working app and user state. |
| FR17 | Original preservation | Never automatically delete or move the selected source file. The UI says uploaded only after remote verification. A user may later remove originals outside the product. |
| FR18 | Remote changes | Refresh remote metadata incrementally, invalidate changed revisions and remove externally trashed entries from listings. Already-open handles stay revision-pinned or fail explicitly. |

## Boundaries

R1 supports one user and one account on one active Mac installation. Same-name imports receive a visible suffix; they never replace a remote object. Multiple devices are tested for external changes but collaborative writes are R2 work.

Read permissions and file format support are different. A mounted PDF may require a PDF parser for AI analysis. Reading a complete remote file can transfer the complete file. Optional AI access is a later opt-in feature, not automatic visibility.


# Nonfunctional requirements and release gates

| ID | Area | Acceptance target |
| --- | --- | --- |
| NFR01 | Integrity | Byte-for-byte SHA-256 match for all fixtures. Zero lost accepted jobs in the defined crash matrix; no silent truncation. |
| NFR02 | Latency target | p95 first video frame at most 3 s in 20 cold trials: mounted account, valid token, healthy provider, 100 Mbps down, 80 ms RTT, 1080p H.264 fast-start MP4. This is a target, not a guarantee. |
| NFR03 | Storage bound | Read-cache payload stays within configured cap plus at most 32 MiB transient writes. Staging and metadata are separately measured. Leave 2 GiB free-space reserve when admitting a staged import. |
| NFR04 | Memory target | Combined host, service and extension RSS at most 512 MiB in a 30-minute sequential-play and seek fixture. Bound outstanding foreground reads to 8 and in-memory payload cache to 128 MiB. |
| NFR05 | Security | Keychain secrets; TLS validation on; validated OAuth state/PKCE; authenticated local IPC; no public sharing or broad cloud scope by default. |
| NFR06 | Recovery | Restart reconstructs jobs and checks remote state before resuming. Foreground missing-data reads fail within 30 s; background retries use bounded backoff and provider Retry-After. |
| NFR07 | Usability | Keyboard-accessible setup and queue, VoiceOver labels, selectable error text. For an indexed 10,000-item fixture, proposed p95 filename-search latency at most 300 ms. |
| NFR08 | Compatibility | R1 Apple Silicon on macOS 26 and a supported newer OS. Validate all executable architectures; Intel is a separately gated expansion, not implied support. |
| NFR09 | Privacy | No file-content relay through product servers. No content or names in telemetry. Beta analytics off; manually exported diagnostics are redacted. |
| NFR10 | Reproducibility | Record build, OS, fixture hashes, cache state, network shaping, provider errors and raw observations for every acceptance run. |

All numeric bounds are proposed engineering budgets. If the spike disproves one, record measurements and update the requirement before release; do not weaken it silently.

| Gate | Required evidence |
| --- | --- |
| G0 feasibility | Signing, extension activation, mounting and authenticated IPC proven on macOS 26 |
| G1 reads | FR03 to FR06 and FR12 pass with checksummed range fixtures |
| G2 imports | FR07 to FR11 and FR17 survive crash and network fault cases |
| G3 beta | All R1 requirements traced; security checks, usability pilot and update/install tests pass |

