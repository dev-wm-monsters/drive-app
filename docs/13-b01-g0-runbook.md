# B01 / G0 runbook

Draft v0.1 | 16 November 2026 | Test procedure

How the founder or a tester runs the B01 feasibility spike on macOS 26 and decides gate G0. The steps are semi-automated by `scripts/b01-spike.sh`. The script saves evidence in the layout from [05 Test plan](05-test-plan.md#evidence-layout). The service/XPC decision is in [ADR03 detail](adr/ADR03-g0-service-xpc.md).

**Current G0 decision: BLOCKED. No macOS 26 run yet.**

## Safety

- Use a disposable macOS 26 machine or VM (options in [10 Repo, CI and test builds §4](10-repo-ci-and-test-builds.md#4-where-to-test-the-dmg)). Back up first. Upgrading a real Mac is the owner's decision.
- Do not connect a real cloud account. B01 serves only generated fixtures, with no network access.
- Never disable SIP. Never weaken entitlements, the sandbox or Gatekeeper. Never strip quarantine to make a step pass. A step that needs any of these is a G0 failure, and it is recorded as one.
- The scripts are read-only towards system settings. They change only `~/DriveAppSpike`, the installed `DriveApp.app` copy, and the spike's own volume and service. The restart test kills and pauses (SIGSTOP) the spike service only.
- Redaction of the saved logs is best-effort. Read the evidence before you commit it.

## What you need

| Item | Notes |
| --- | --- |
| Apple Silicon Mac or VM on macOS 26.x, SIP enabled | `scripts/validate-env.sh --role test` checks this |
| Xcode 26 or the Command Line Tools | Needed for `swift` (fixture-check, spoof client) and `python3` |
| A **team-signed** DriveApp DMG or app | Developer ID and notarised for a clean machine. An unsigned (ad-hoc) build can rehearse the procedure, but it fails G0-SIGN and G0-IPC-AUTH by design. |
| This repo, checked out at the build's commit | Scripts and `Packages/StorageCore` (fixture-check) |
| About 15 minutes | Most of it is the service-restart loop (about 2 minutes) and the manual approvals |

## Procedure

1. **Get the build.** Download the DMG and its `.sha256` from the draft pre-release `v<version>-b<build>` ([12 Pipeline usage §4–5](12-pipeline-usage.md#4-where-the-dmg-appears)), then run `shasum -a 256 -c DriveApp-<version>-<build>.dmg.sha256`. Or build it locally with `VERSION=0.0.1 BUILD_NUMBER=1 scripts/build-dmg.sh build`.
2. **Check the machine.** Run `scripts/validate-env.sh --role test`. Fix every `fail` before you go on (exit 0 = pass, 1 = fail, 2 = blocked). The script reports identity counts and team IDs only.
3. **Run the spike:**

   ```sh
   scripts/b01-spike.sh all ~/Downloads/DriveApp-0.0.1-1.dmg
   ```

   | Step | Test IDs | What happens; what you do |
   | --- | --- | --- |
   | `preflight` | G0-ENV | Runs validate-env, builds `fixture-check`, and generates `~/DriveAppSpike/reference` plus the manifest |
   | `install` | G0-SIGN | Copies the app to `/Applications` (or `~/Applications`), then runs `codesign --verify --deep --strict`, per-component checks and `codesign -d -r-`. Runs `spctl --assess` for the report only. |
   | `enable` | G0-EXT-ACTIVATE | Launches DriveApp and opens System Settings. **You:** allow DriveApp under Login Items › Allow in the Background. Then under Login Items & Extensions › File System Extensions, switch on DriveApp. Press Enter. The script checks `pluginkit` and `launchctl print`. |
   | `mount` | G0-MOUNT | `mount -F -t driveappspike driveappspike://spike ~/DriveAppSpike/mnt`. The resource is the generic URL that DriveAppFS declares. Override it with `SPIKE_RESOURCE`, or set `SPIKE_RESOURCE=ramdisk` to pass a RAM-disk `diskN`. |
   | `test` | G0-LIST, G0-READ-RANGE, G0-EOF, G0-READONLY, G0-CANCEL, G0-IPC-AUTH, G0-SERVICE-RESTART, G0-UNMOUNT | Automatic. Do not touch the volume while it runs. |
   | `collect` | all | Saves redacted `log show` output for each test, then writes `g0-summary.json` and prints the decision |

   You can run each step on its own (`scripts/b01-spike.sh mount`, and so on). A rerun overwrites the evidence for the same BUILD and OS. `scripts/b01-spike.sh --help` lists the overrides.
4. **Review the evidence** in `validation/<BUILD>/<OS>/`. BUILD is `<CFBundleShortVersionString>-<CFBundleVersion>`. OS is `macos-<productVersion>-<buildVersion>`. For each test, read `result.json` (status, expected, observed, command) and the `logs/`. Search for anything private (`grep -rn "$USER" validation/`) before committing.
5. **Record the decision.** Fill in the table below and update the ADR03 Evidence section. Commit only `validation/…`, never the DMG.

## G0 decision table

G0 criteria come from [02 SRD](02-srd.md#nonfunctional-requirements-and-release-gates): *signing, extension activation, mounting and authenticated IPC proven on macOS 26.* G0 passes only when every test below passes on the same build and OS. A blocked test keeps G0 blocked.

| G0 criterion | TEST_ID | Pass | Fail | Blocked |
| --- | --- | --- | --- | --- |
| Signing | G0-ENV | macOS 26+, arm64, SIP on, tools present | Older OS, SIP off, Rosetta | Not run on macOS |
| Signing | G0-SIGN | Deep strict verify; one team; hardened runtime; Mach name `<TEAM>.<APP_BUNDLE_ID>.storage` | Ad-hoc or unsigned, mixed teams, missing appex/service | Not run on macOS |
| Extension activation | G0-EXT-ACTIVATE | pluginkit shows `+ <APP_BUNDLE_ID>.fsext` | Not registered | Awaiting approval; VM limitation |
| Mounting | G0-MOUNT | Mount exits 0 and appears in 10 s | Mount error | Extension not enabled |
| Mounting | G0-LIST | Exact files, directories and sizes | Missing or extra entry, wrong size | Not mounted |
| Mounting | G0-READ-RANGE | fixture-check pass; all SHA-256 match; cross-check pass | Any byte mismatch | No fixture-check |
| Mounting | G0-EOF | 0 bytes at or after EOF; 1 byte at size−1 | Extra or short bytes | Not mounted |
| Mounting | G0-READONLY | Every write fails with EROFS (EPERM noted) | Any write succeeds or the fixture changes | Not mounted |
| Mounting | G0-CANCEL | Killed reader exits and the volume answers within 5 s | Stuck reader or slow probe | Not mounted |
| Mounting | G0-UNMOUNT | Unmounted and mountpoint removed | Still mounted | Nothing mounted |
| Authenticated IPC | G0-IPC-AUTH | Both spoof clients get no reply; no `Accepted` line for their PIDs; genuine path works | A spoof gets a reply; the service runs without signing checks | Inconclusive outcome, or the service is not registered |
| Authenticated IPC | G0-SERVICE-RESTART | New PID after kickstart; reads fail within 35 s while stopped, with no wrong bytes; recovery within 30 s | Hang, wrong bytes, no recovery, unexpected errno | Service not running |

If G0-IPC-AUTH or G0-SERVICE-RESTART can pass only by weakening the sandbox or entitlements, follow the ADR03 decision rule: adopt the extension-owned engine and record the evidence.

### Current results

| Run | G0-ENV | G0-SIGN | G0-EXT-ACTIVATE | G0-MOUNT…G0-UNMOUNT | G0-IPC-AUTH | G0-SERVICE-RESTART | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Linux cloud session, 16 Nov 2026 (`validation/linux-cloud-session/linux-ubuntu-24.04/`) | blocked | blocked | blocked | blocked | blocked | blocked | **BLOCKED** |

## Verified in the Linux cloud session (16 Nov 2026)

| Verified | Not verified (needs macOS 26) |
| --- | --- |
| `shellcheck -x` is clean for both scripts | Any codesign, spctl, stapler, pluginkit, launchctl, `mount -F`, FSKit, XPC or `log show` behaviour |
| `validate-env.sh` reports 8 native checks blocked and exits 2. `b01-spike.sh preflight` and `all` record every G0 test as blocked. | Running under macOS `/bin/bash` 3.2 (it is written for 3.2 but was run only with bash 5.2) |
| The 12 Linux `result.json` files validate against `validation/result.schema.json` (Draft 2020-12) | Compiling the spoof client (`NSXPCConnection` is not available on Linux) |
| `fixture-check manifest` runs on Linux, and its output is saved as `fixture-manifest.json` | Every G0-VERIFY item below |
| Python checks (listing, hashes and ranges, EOF, probe, restart analysis, redaction) were dry-run against a fixture tree on local disk. This is not a mount. A writable directory correctly fails the read-only check. | Behaviour of the FSKit volume, the extension and the service |

## G0-VERIFY items

Assumptions the first macOS 26 run must confirm. Correct the script or this runbook if any is wrong.

1. The settings URL `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` opens Login Items & Extensions. No direct URL for the File System Extensions sub-pane is known.
2. `pluginkit -m -v -p com.apple.fskit.fsmodule` lists FSKit modules, and `+` marks an enabled one.
3. The syntax `mount -F -t driveappspike driveappspike://spike <mountpoint>`: mount(8) builds an `FSGenericURLResource` from the module's `FSSupportsGenericURLResources`/`FSSupportedSchemes` and reaches `loadResource`. Also check whether `sudo` is needed (`SPIKE_MOUNT_SUDO=1`).
4. Whether FSKit extension enablement works inside a macOS 26 VM.
5. `F_NOCACHE` makes reads reach the extension (check the service log for read requests during G0-READ-RANGE and G0-SERVICE-RESTART).
6. Kernel cancellation reaches the extension (look for `cancel` in the G0-CANCEL logs).
7. The sandboxed extension can look up `<TEAM>.<APP_BUNDLE_ID>.storage` because of the app-group prefix (ADR03 fact 4).
8. The listener-level code-signing requirement rejects the spoof before `shouldAcceptNewConnection` runs, so no rejection line from the service is expected. Check `com.apple.xpc` logs. The spoof selector `send:withReply:` must match `Shared/StorageServiceXPC.swift`.
9. `launchctl kickstart -k gui/$UID/<label>` works on an SMAppService-registered agent. Neither the kernel nor FSKit imposes its own timeout that differs from the 30 s service deadline.
10. Whether the FSKit entitlement and app group need a provisioning profile under Developer ID.
