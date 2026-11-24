# ADR03 Single storage service: G0 service and XPC arrangement

Draft v0.1 | 16 November 2026 | Status: **Superseded by [ADR09](ADR09-file-provider-and-cloud-files.md) on branch `claude/shared-drive-sync`** (was: Proposed — pending G0 evidence)

Detail record for ADR03 in [04 Architecture](../04-architecture.md). It does not change ADR03; it states exactly what B01 must prove before the single-service design is accepted. No part of this arrangement has run on macOS 26 yet.

## Context

- The TRD makes StorageService the only owner of tokens, database, cache and uploads. The FSKit extension and the host app call it over authenticated local IPC.
- The FSKit module is a sandboxed app extension. Its lifecycle belongs to FSKit, not to our app. Apple does not document that it can reach a Mach service published by a LaunchAgent.
- R1 targets Developer ID distribution on macOS 26+, Apple Silicon only. Entitlements, SIP and the sandbox must not be weakened to make the IPC work (04 Architecture, AI-HANDOFF).

## Proposed arrangement (B01)

| Part | Identity (from `project.yml`) | Location in DriveApp.app | Role |
| --- | --- | --- | --- |
| Host app | `$(APP_BUNDLE_ID)` | `Contents/MacOS/DriveApp` | Sandboxed. Registers the agent with `SMAppService.agent(plistName:)`. Shows status. |
| FSKit module | `$(APP_BUNDLE_ID).fsext`, short name `driveappspike` | `Contents/Extensions/` | Sandboxed. Kernel-facing semantics and cancellation. XPC client. |
| StorageService | `$(APP_BUNDLE_ID).storageservice` | `Contents/MacOS/DriveAppStorageService` + `Contents/Library/LaunchAgents/$(APP_BUNDLE_ID).storageservice.plist` | LaunchAgent, started on demand by launchd. `NSXPCListener(machServiceName:)`. Wraps StorageCore `SpikeEngine`. Not sandboxed in B01, hardened runtime on. |

- **Mach service:** `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID).storage`. Every target reads it from Info.plist key `DriveAppStorageMachService`.
- **App group:** `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID)` on all three targets. Assumption: the macOS sandbox allows `mach-lookup` of names that start with an app group the process belongs to. This is the main thing G0 must prove.
- **Service-side authentication:** `NSXPCListener.setConnectionCodeSigningRequirement` and a per-connection `setCodeSigningRequirement`: `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and (identifier "<app>" or identifier "<app>.fsext")`. The peer must also have the same user ID. A build without a team ID logs a fault and accepts any client. G0 rejects such a build.
- **Client-side authentication:** clients require the service to have identifier `<app>.storageservice` and the same team.
- **Messages:** opaque `Data`. StorageCore `IPCCodec` owns the encoding and the limits: control messages up to 1 MiB, read replies up to 4 MiB.
- **Failure policy:** StorageCore `ServiceHealth`. On interruption the client reconnects. A reply that takes more than 30 s fails with a specific errno. A read never returns stale data as success.

## Alternatives

| Option | Description | Consequences |
| --- | --- | --- |
| A. LaunchAgent + app-group Mach service (proposed) | As above | One data owner across app and extension. Survives volume remounts. Depends on unproven sandbox lookup and SMAppService approval. Adds a Login Item the user must allow. |
| B. Extension-owned engine | StorageCore runs inside the FSKit module. The app talks to the extension, or to shared app-group storage. | No custom Mach service. Lifecycle follows FSKit, so the engine stops when the volume unmounts or the extension is killed. Uploads and token refresh need a second owner or must run only while mounted. Single-writer database access then needs a lock between app and extension. |
| C. XPC service bundled inside the extension | `.xpc` bundle in the appex, launched per client | Sandboxed and simple to look up. Only the extension can reach it. A new instance per client means no single owner for the app's imports. Same lifecycle limits as B. |
| D. App-hosted listener | The host app publishes the Mach service, which is prefixed by the app group | Reads fail whenever the user quits the menu-bar app, and nothing relaunches it on demand. Lookup has the same sandbox assumption as A, with a weaker lifecycle. Use it only as a diagnostic to separate a lookup failure from an SMAppService failure. |

## Facts G0 must prove on macOS 26

| # | Fact | TEST_ID |
| --- | --- | --- |
| 1 | The app, appex and service are signed with one team and hardened runtime. App group and FSKit entitlements are accepted with Developer ID (provisioning profile needs are recorded). Mach service name = `<TEAM>.<APP_BUNDLE_ID>.storage` everywhere. | G0-SIGN |
| 2 | The user can enable the FSKit module in System Settings, and pluginkit shows it enabled. The LaunchAgent is registered after Login Item approval. | G0-EXT-ACTIVATE |
| 3 | `mount -F -t driveappspike` mounts the volume. Listing, ranges, EOF and read-only errors behave correctly through the extension → XPC → service path. | G0-MOUNT, G0-LIST, G0-READ-RANGE, G0-EOF, G0-READONLY |
| 4 | The sandboxed extension can look up the app-group-prefixed Mach service in the user's launchd domain, and the service accepts it. G0-READ-RANGE passing proves this, because every byte comes from the service. | G0-READ-RANGE (positive control in G0-IPC-AUTH) |
| 5 | A client signed differently (unsigned interpreter, ad-hoc binary) gets no reply. The service never logs `Accepted XPC client` for it. | G0-IPC-AUTH |
| 6 | Kernel cancellation reaches the extension, and a killed reader does not wedge the volume. | G0-CANCEL |
| 7 | If the service is killed or restarted, launchd relaunches it and reads recover. If it hangs, reads fail within 30 s with a specific errno. No wrong bytes are returned. | G0-SERVICE-RESTART |
| 8 | Unmount is clean, with no leftover mount or stuck process. | G0-UNMOUNT |

The procedure is in [13 B01 G0 runbook](../13-b01-g0-runbook.md). Evidence goes in `validation/<BUILD>/<OS>/<TEST_ID>/`.

## Decision rule

- If every test in the table passes on a SIP-enabled macOS 26 machine with a Developer ID or team-signed build, mark this record **Accepted** and link the evidence directory.
- If **G0-IPC-AUTH or G0-SERVICE-RESTART cannot pass without weakening the sandbox or entitlements**, adopt **option B (extension-owned engine)**. Examples of weakening: a temporary-exception mach-lookup entitlement, an unsandboxed extension, or dropping the code-signing requirement. Record the failing evidence here, mark A **Rejected**, and write the lifecycle design for B before B02 continues.
- If fact 4 fails (the lookup is denied) but options A and B are both still possible, try C only as a stepping stone to B. Do not add broader entitlements.
- If a test is **blocked** (no macOS 26 machine, no Developer ID, VM limitation), G0 stays blocked. Blocked never counts as pass.

## Evidence

| Run | Result |
| --- | --- |
| Linux cloud session, 16 Nov 2026 | All G0 tests blocked: no macOS 26, Xcode, FSKit, XPC or codesign. See `validation/linux-cloud-session/linux-ubuntu-24.04/`. |
