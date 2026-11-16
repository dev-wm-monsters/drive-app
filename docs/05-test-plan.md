# Testing and verification plan

Draft v0.1 | 16 November 2026 | Proposed product design

This is a test specification. No product test below has run. Use disposable cloud accounts and fixture files. Every result records build, OS, fixture digest, cache state, network conditions and logs with secrets removed.

| Test | Requirements | Scenario | Pass evidence |
| --- | --- | --- | --- |
| T01 | FR01 FR02 NFR05 | Consent cancel, invalid state, revoked refresh token, reconnect | No false connection; no token leakage; clean recovery |
| T02 | FR03 FR04 FR12 | Mount, restart, disconnect, Finder attempted write | Correct listing; unsupported writes rejected; no hung volume |
| T03 | FR05 NFR01 | Random ranges, boundaries, EOF, zero length, concurrent reads | All bytes match fixture; no wrong revision data |
| T04 | FR06 FR14 NFR03 | Cache eviction, cap, clear during playback and queued upload | Cap respected; stages intact; later reads refetch correctly |
| T05 | FR05 NFR02 | 20 cold video opens on fixed network fixture | Save raw latency data; p95 at most proposed target |
| T06 | FR07 FR17 NFR01 | Source changes, low disk, crash at every staging boundary | Original untouched; accepted jobs recover; incomplete stage not accepted |
| T07 | FR08 FR09 NFR06 | Network loss, sleep, process kill, expired session, lost final reply | Resume from confirmed offset; no duplicate visible completion |
| T08 | FR10 NFR01 | Cancel while uploading and while commit reply is lost | No lost original; committed file preserved; honest state |

## Fixture set

Use 0 B, 1 B, 64 KiB, 4 MiB minus one, exactly 4 MiB, 4 MiB plus one, 1 GiB random content and a 50 GiB generated fixture with known hashes. Add Unicode names, deep folders, duplicate names, 10,000 indexed items, a fast-start H.264 MP4 and an MP4 whose metadata is near the end.

## Tools

XCTest for pure range/cache/state logic; URLProtocol or a deterministic fake provider for errors; XCUITest for onboarding and queue actions; real Finder and native apps on compatible hardware for filesystem acceptance. Use Instruments for memory and stalls; use controlled network shaping for latency/loss.


# Release evidence and operational readiness

| Test | Requirements | Scenario | Pass evidence |
| --- | --- | --- | --- |
| T09 | FR11 FR15 NFR06 | Offline, timeout, 429, 5xx, quota and permission failure | Cached reads work; missing ranges fail clearly; jobs remain recoverable |
| T10 | FR18 FR05 NFR01 | Remote object edited, renamed or trashed during a read | No old/new byte splice; index invalidates; explicit reopen/error |
| T11 | FR13 NFR07 | 10,000 names, Unicode queries, keyboard and VoiceOver | Search target measured; open/reveal accurate; accessible labels |
| T12 | FR14 FR15 NFR05 NFR09 | Diagnostics export, cache clear, secret scanning, spoofed IPC | No tokens/content/names; unauthorized client rejected; stages intact |
| T13 | FR16 NFR08 | Clean install, tampered update, failed upgrade and relaunch | Signing verified; bad update rejected; user state retained |
| T14 | NFR04 NFR10 | 30-minute playback, thumbnails and random seek storm | RSS and concurrency budgets measured; no unbounded growth |
| T15 | FR04 FR05 | Google Docs item and ignored/malformed Range response | Unsupported item explained; no accidental huge full download |
| T16 | FR05 NFR08 | QuickTime, Preview and one additional media player | Each app passes its declared fixture list; no universal compatibility claim |

## Release checklist

- G0 to G3 pass with saved results; no known data-loss or credential-disclosure defect remains open.
- All executables match advertised architectures; clean install, extension activation and disconnect work on minimum and newer supported OS.
- Remote checksums or controlled read-back confirm imported bytes; staging survives the documented fault matrix.
- Uncached offline behavior, app-created-file scope, staging space and unsupported file types are explained in onboarding.
- Update recovery, redacted support bundle, issue severity process and manual recovery instructions are documented.

## Evidence layout

Store results under validation/BUILD/OS/TEST_ID with result.json, fixture-manifest.json, redacted logs and any UI recording. result.json records pass/fail/blocked, observed values, expected values and a reproducible command or manual procedure.

## Later feature gates

R2 adds Finder save/flush/rename/trash and concurrent revision tests. R3 adds key recovery/tamper/migration cases; SFTP host-key change and quota cases; share revocation/CORS cases; MCP symlink/path containment and architecture checks. Never reuse R1 pass results as proof of those new features.

