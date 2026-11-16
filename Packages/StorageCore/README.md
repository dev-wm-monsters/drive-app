# StorageCore

Pure-Swift, Foundation-only core for the B01 feasibility spike. It is linked into the macOS
app, the FSKit extension (`DriveAppFS`) and the `DriveAppStorageService` LaunchAgent. It
builds and tests on Linux, so range, fixture, codec and failure-policy logic can be verified
without a Mac.

- `swift-tools-version: 6.0`, Swift 6 language mode, strict concurrency. All public types are `Sendable`.
- No external dependencies, CryptoKit, `os`, XPC or FSKit.
- Products: library `StorageCore`, executable `fixture-check`.

## API overview

| Type | Purpose |
| --- | --- |
| `ItemID`, `ItemKind`, `ItemAttributes`, `ListPage`, `ByteRange`, `RequestID` | Value types shared by the service and the extension. `ItemID.root` is 1. |
| `StorageError` | Every cross-boundary failure. `posixErrorCode` maps each case to an errno: EINVAL, ENOENT, ENOTDIR, EISDIR, ESTALE, ECANCELED, ENOTCONN, ETIMEDOUT, EROFS or EMSGSIZE. |
| `Limits` | 4 MiB read replies, 1 MiB control messages, 4 MiB segments, 8 network reads, list limit 1000. |
| `RangeMath` | `clamp` rejects a negative offset or length and any Int64 overflow. It clamps only the final range at EOF. A zero-length read, or a read at or after EOF, gives an empty range and no error. `segmentIndexes` and `split` are also here; `split` aligns chunks to multiples of `maxChunk`. |
| `FixtureFile` | Deterministic random-access generator. Byte `i` is `LE(splitmix64(seed ^ (i/8)))[i % 8]`, and the seed is FNV-1a 64 of the UTF-8 name. A 4 MiB slice takes about 2 ms in release builds (about 9 ms in debug builds) on the Linux CI box. |
| `FixtureCatalog.spike` | The spike volume: `empty.bin` (0 B), `one.bin` (1 B), `64k.bin`, `seg-minus-1.bin` (4 MiB − 1), `seg.bin` (4 MiB), `seg-plus-1.bin` (4 MiB + 1), `Ünïcødé name.bin` (12 345 B, NFC) and `nested/deep.bin` (100 000 B). IDs are stable: root 1, then 2 to 10 in that order, with `nested` as 9. Every item is at revision `r1`. `list` pages with an opaque cursor. `lookup` uses canonical-equivalent name matching. `read` checks the item, then that it is a file, then the revision, then the range, and returns **at most `Limits.maxReadReply` bytes**: callers loop or use `RangeMath.split`. |
| `SHA256Digest` | Pure-Swift SHA-256 with a streaming `Hasher`, checked against the NIST vectors. |
| `IPCRequest`, `IPCResponse`, `ServiceStatus`, `IPCCodec` | The XPC payload is opaque `Data`, encoded as a binary property list with envelope `{v: 1, m: …}`. Size limits apply on encode and on decode: `Data.count` is checked before parsing, and a too-big message gives `.messageTooLarge`. Garbage input gives `.invalidArgument` and never traps (fuzz-tested). A `.bytes` reply may be up to 4 MiB + 64 KiB. Every other message may be up to 1 MiB. |
| `SpikeEngine` | Server-side request handler. `handle(_:)` is `nonisolated`, so reads run concurrently and a `.cancel` is never queued behind a read. |
| `CancellationRegistry` | Tracks in-flight request IDs. A duplicate in-flight ID gives `.invalidArgument`. A cancel for an unknown ID records a tombstone, capped at 1024 with the oldest evicted first, so a read that arrives after its cancel is still cancelled. |
| `ServiceHealth`, `ServiceConnectionEvent` | Client failure policy, described below. |

### Cancellation semantics

- `.cancel(id)` always answers `.cancelled(id)`. That reply is an acknowledgement.
- A read whose ID is cancelled answers `.failure(.cancelled)` (ECANCELED). The engine checks
  for cancellation after it registers the read and again after it produces the bytes.
  Cancelling the Swift task that runs `handle` has the same effect.
- Request IDs must be unique per client connection and should increase monotonically. A tombstone for an ID that
  is reused later would cancel the new read.

### Service failure policy (`ServiceHealth`)

- `connected` and `replyReceived` move the state to `.healthy`. `interrupted`, `invalidated` and
  `replyTimedOut` move it to `.unavailable`. The initial state, `.unknown`, allows requests.
- When the connection is interrupted or invalidated, reads in flight fail at once with
  `.serviceUnavailable` (ENOTCONN). A reply timeout gives `.timedOut` (ETIMEDOUT); see
  `ServiceHealth.failure(for:)`. Nothing returns stale success (FR03).
- The next request reconnects. If `needsReconnect` is true, the client creates or reuses its
  connection and records `.connected`, then calls `gate()` just before it sends. While the
  state is `.unavailable`, `gate()` throws `.serviceUnavailable`.
- Foreground requests use `ServiceHealth.foregroundDeadline`, which is 30 s (NFR06).

## fixture-check

```
fixture-check generate <dir>                                        # write the spike catalog as real files
fixture-check verify <mountpoint> [--random-reads N] [--seed S]     # default N=200, S=1
fixture-check manifest                                              # JSON for validation/fixture-manifest.json
```

`verify` walks the expected catalog and checks the following:

- the exact name set in each directory, and each item's kind;
- each file's size and its whole-file SHA-256, streamed in 1 MiB chunks;
- boundary reads at 0, EOF−1, EOF, past EOF and 4 MiB ± 1, using `FileHandle` seek and read;
- N seeded random range reads, compared with the generator output;
- zero-length reads.

It prints `{"pass": bool, "checks": [...], ...}` and exits with 0 on pass, 1 on failure and 2 on a usage error. All the logic is in the
`FixtureCheckKit` target, so the tests drive it without starting a process.

## Testing

Linux, or macOS with the Swift 6 toolchain or Xcode 26:

```sh
cd Packages/StorageCore
swift build -c release
swift test --parallel
swift build -Xswiftc -warnings-as-errors --build-tests
.build/release/fixture-check generate /tmp/fixtures && .build/release/fixture-check verify /tmp/fixtures
```

On macOS, to check the mounted FSKit volume against the same expectations, run
`fixture-check verify /Volumes/<spike volume> --random-reads 1000`.

## Not covered here

FSKit, XPC, code-signing and audit-token caller authentication, SMAppService/LaunchAgent
registration and the App Group are not here. They are macOS-only glue in `FileSystemExtension/`,
`StorageService/` and `Shared/`, and no test in this package proves them. Passing these tests
does not mean any native G0 check passed.
