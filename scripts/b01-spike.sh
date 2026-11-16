#!/usr/bin/env bash
# b01-spike.sh - semi-automated B01 / gate G0 procedure for a macOS 26 test machine.
#
# Usage: scripts/b01-spike.sh <command> [args]
#   preflight [APP|DMG]   G0-ENV: scripts/validate-env.sh --role test, then build
#                         fixture-check and generate the reference fixture + manifest
#   install APP|DMG       G0-SIGN: copy DriveApp.app to /Applications (or ~/Applications),
#                         verify signatures, report Gatekeeper, print code requirements
#   enable                G0-EXT-ACTIVATE: launch the app, guide the manual approvals,
#                         check pluginkit and the LaunchAgent registration
#   mount                 G0-MOUNT: mount -F -t driveappspike <resource> <mountpoint>
#   test                  G0-LIST G0-READ-RANGE G0-EOF G0-READONLY G0-CANCEL
#                         G0-IPC-AUTH G0-SERVICE-RESTART, then G0-UNMOUNT
#   unmount               G0-UNMOUNT only
#   collect               redacted unified logs per test, fixture manifests, g0-summary.json
#   all APP|DMG           preflight, install, enable, mount, test, collect
#
# Evidence: validation/<BUILD>/<OS>/<TEST_ID>/result.json (+ fixture-manifest.json,
# logs/, artifacts) per docs/05-test-plan.md "Evidence layout" and
# validation/result.schema.json. BUILD = CFBundleShortVersionString-CFBundleVersion,
# OS = macos-<productVersion>-<buildVersion>.
#
# Environment (all optional):
#   SPIKE_HOME          work dir (default ~/DriveAppSpike; temp dir off macOS)
#   SPIKE_MOUNTPOINT    default $SPIKE_HOME/mnt (must stay under $SPIKE_HOME)
#   SPIKE_RESOURCE      mount resource (default driveappspike://spike, the FSGenericURLResource
#                       the DriveAppFS module declares); "ramdisk" attaches a 1 MiB RAM disk and
#                       passes its diskN name instead. G0-VERIFY the resource kind.
#   SPIKE_MOUNT_OPTS    extra mount(8) options, e.g. "-o rdonly" (default none, so write
#                       attempts reach the extension and G0-READONLY tests its errors)
#   SPIKE_FS_NAME       FSKit short name (default driveappspike)
#   SPIKE_MOUNT_SUDO=1  prefix mount/umount with sudo (only if G0 shows it is required)
#   SPIKE_BUILD         override BUILD id;  SPIKE_EVIDENCE_ROOT  default <repo>/validation
#   SPIKE_RANDOM_READS  default 500;  SPIKE_SEED  default 1
#   SPIKE_RESTART_SECONDS  safety cap on the G0-SERVICE-RESTART read loop (default 300)
#   SPIKE_HANG_TEST=0   skip the SIGSTOP (hung service) phase of G0-SERVICE-RESTART
#   SPIKE_NONINTERACTIVE=1  never wait for Enter;  FIXTURE_CHECK  path to fixture-check
#   SPIKE_SPOOF_APP_ARGS  args that make the app binary act as an XPC client (variant C)
#
# Safety: never changes SIP, entitlements, Gatekeeper or quarantine. Only touches
# $SPIKE_HOME, the installed DriveApp.app copy and the spike's own service/volume.
# Exit: 0 pass, 1 fail, 2 blocked (for the steps that ran).
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_VERSION="b01-spike/1"
APP_NAME="DriveApp"
EXPECTED_ID_PREFIX="com.wakeupmonster.driveapp"
FSKIT_EXTENSION_POINT="com.apple.fskit.fsmodule"
LOG_PREDICATE='subsystem BEGINSWITH "com.wakeupmonster.driveapp"'
FSKIT_LOG_PREDICATE='process == "fskitd" OR subsystem BEGINSWITH "com.apple.FSKit"'
SETTINGS_URL="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
LINUX_REASON="Linux cloud session: no macOS 26/Xcode; FSKit/XPC/codesign unavailable"
ALL_TESTS="G0-ENV G0-SIGN G0-EXT-ACTIVATE G0-MOUNT G0-LIST G0-READ-RANGE G0-EOF G0-CANCEL G0-READONLY G0-IPC-AUTH G0-SERVICE-RESTART G0-UNMOUNT"

FS_SHORT_NAME="${SPIKE_FS_NAME:-driveappspike}"
SPIKE_RESOURCE="${SPIKE_RESOURCE:-driveappspike://spike}"
MOUNT_OPTS="${SPIKE_MOUNT_OPTS:-}"
RANDOM_READS="${SPIKE_RANDOM_READS:-500}"
SEED="${SPIKE_SEED:-1}"
RESTART_SECONDS="${SPIKE_RESTART_SECONDS:-300}"
HANG_TEST="${SPIKE_HANG_TEST:-1}"
EVIDENCE_ROOT="${SPIKE_EVIDENCE_ROOT:-$REPO_ROOT/validation}"

IS_MAC=0
if [ "$(uname -s)" = "Darwin" ] && command -v sw_vers >/dev/null 2>&1; then IS_MAC=1; fi

TEMP_HOME=""
if [ -n "${SPIKE_HOME:-}" ]; then :
elif [ "$IS_MAC" = 1 ]; then SPIKE_HOME="$HOME/DriveAppSpike"
else TEMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/driveappspike.XXXXXX")"; SPIKE_HOME="$TEMP_HOME"; fi
MOUNTPOINT="${SPIKE_MOUNTPOINT:-$SPIKE_HOME/mnt}"
WORK="$SPIKE_HOME/work"
REF_DIR="$SPIKE_HOME/reference"
MANIFEST_CACHE="$SPIKE_HOME/fixture-manifest.json"
STATE_FILE="$SPIKE_HOME/state.env"
HELPER="$WORK/b01_spike_helper.py"
mkdir -p "$WORK"

OVERALL_RC=0          # worst of: 0 pass, 2 blocked, 1 fail
STOPPED_PID=""        # service pid we SIGSTOPped (always SIGCONT on exit)
BG_PIDS=""            # background readers to kill on exit
DMG_MOUNT=""          # read-only DMG attach point to detach on exit
SOURCE_APP=""         # app bundle being installed (inside a DMG or on disk)

# ------------------------------------------------------------------ basics

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }
die()  { say "b01-spike: $*"; exit 1; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
have() { command -v "$1" >/dev/null 2>&1; }

json_str() {
  local s="${1-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}
json_str_or_null() { if [ -n "${1-}" ]; then json_str "$1"; else printf 'null'; fi; }

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  local p
  if [ -n "$STOPPED_PID" ]; then kill -CONT "$STOPPED_PID" 2>/dev/null || true; fi
  for p in $BG_PIDS; do pkill -KILL -P "$p" 2>/dev/null || true; kill -KILL "$p" 2>/dev/null || true; done
  if [ -n "$DMG_MOUNT" ]; then hdiutil detach -quiet "$DMG_MOUNT" 2>/dev/null || true; fi
  if [ -n "$TEMP_HOME" ]; then rm -rf "$TEMP_HOME"; fi
}
trap cleanup EXIT

# with_timeout SECS CMD... -> rc of CMD, or 124 after SIGKILL (never waits on a stuck process)
with_timeout() {
  local secs="$1" pid ticks=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((secs * 10)) ]; then
      kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

note_rc() { # fold a step status into OVERALL_RC
  case "$1" in
    fail) OVERALL_RC=1 ;;
    blocked) if [ "$OVERALL_RC" = 0 ]; then OVERALL_RC=2; fi ;;
  esac
}

state_get() { if [ -f "$STATE_FILE" ]; then grep "^$1=" "$STATE_FILE" | tail -n 1 | cut -d= -f2- || true; fi; }
state_set() {
  local tmp="$STATE_FILE.tmp"
  { if [ -f "$STATE_FILE" ]; then grep -v "^$1=" "$STATE_FILE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

py() { python3 -I "$HELPER" "$@"; }
redact() { if have python3; then py redact; else cat; fi; }

# ------------------------------------------------------------------ identity

OS_ID=""; OS_PV=""; OS_BV=""; OS_MODEL=""
init_os() {
  if [ "$IS_MAC" = 1 ]; then
    OS_PV="$(sw_vers -productVersion)"; OS_BV="$(sw_vers -buildVersion)"
    OS_MODEL="$(sysctl -n hw.model 2>/dev/null || true)"
    OS_ID="macos-$OS_PV-$OS_BV"
  elif [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    OS_PV="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    # shellcheck disable=SC1091
    OS_ID="linux-$(. /etc/os-release && printf '%s-%s' "${ID:-unknown}" "${VERSION_ID:-unknown}")"
  else
    OS_ID="$(uname -s | tr '[:upper:]' '[:lower:]')-unknown"
  fi
}

plist_get() { # plist_get FILE KEY -> raw value or empty
  if [ "$IS_MAC" = 1 ] && [ -f "$1" ]; then plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; fi
}

APP=""; APP_ID=""; APP_SHORT=""; APP_BUILD=""; BUILD_ID=""; EXT_ID=""; SERVICE_LABEL=""; MACH_SERVICE=""
set_app() { # set_app PATH -> identity globals from the bundle
  APP="$1"
  APP_ID="$(plist_get "$APP/Contents/Info.plist" CFBundleIdentifier)"
  APP_SHORT="$(plist_get "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  APP_BUILD="$(plist_get "$APP/Contents/Info.plist" CFBundleVersion)"
  MACH_SERVICE="$(plist_get "$APP/Contents/Info.plist" DriveAppStorageMachService)"
  EXT_ID="${APP_ID:+$APP_ID.fsext}"
  SERVICE_LABEL=""
  local agent
  for agent in "$APP"/Contents/Library/LaunchAgents/*.plist; do
    [ -f "$agent" ] || continue
    SERVICE_LABEL="$(plist_get "$agent" Label)"
    break
  done
  [ -n "$SERVICE_LABEL" ] || SERVICE_LABEL="${APP_ID:+$APP_ID.storageservice}"
  if [ -z "${SPIKE_BUILD:-}" ] && [ -n "$APP_SHORT" ]; then
    BUILD_ID="$(printf '%s-%s' "$APP_SHORT" "${APP_BUILD:-0}" | tr -c 'A-Za-z0-9._-' '_')"
  fi
}

init_build() {
  if [ -n "${SPIKE_BUILD:-}" ]; then BUILD_ID="$SPIKE_BUILD"; fi
  if [ -z "$APP" ] && [ "$IS_MAC" = 1 ]; then
    local cand
    for cand in "$(state_get APP_PATH)" "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
      if [ -n "$cand" ] && [ -d "$cand" ]; then set_app "$cand"; break; fi
    done
  fi
  if [ -z "$BUILD_ID" ] && [ "$IS_MAC" = 0 ]; then BUILD_ID="linux-cloud-session"; fi
  [ -n "$BUILD_ID" ] || BUILD_ID="unknown-build"
}

evidence_dir() { printf '%s/%s/%s/%s' "$EVIDENCE_ROOT" "$BUILD_ID" "$OS_ID" "$1"; }

# ------------------------------------------------------------------ test metadata

meta() { # meta TEST_ID field(title|reqs|expected|command|verify)
  case "$1:$2" in
    G0-ENV:title) echo "Test machine, OS and SDK validated" ;;
    G0-ENV:reqs) echo '["NFR08","NFR10"]' ;;
    G0-ENV:expected) echo "validate-env --role test passes: macOS >= 26.0 on arm64, SIP enabled, >= 10 GiB free, swift and python3 present; fixture-check builds and generates the reference fixture and manifest" ;;
    G0-ENV:command) echo "scripts/b01-spike.sh preflight  (runs scripts/validate-env.sh --role test; fixture-check generate <dir>; fixture-check manifest)" ;;
    G0-ENV:verify) echo '[]' ;;
    G0-SIGN:title) echo "App, FSKit extension and service signatures verify" ;;
    G0-SIGN:reqs) echo '["FR16","NFR05","NFR08"]' ;;
    G0-SIGN:expected) echo "codesign --verify --deep --strict passes; app, .fsext and StorageService each verify, share one TeamIdentifier, have hardened runtime; Info.plist/LaunchAgent Mach service = <TEAM>.<APP_BUNDLE_ID>.storage; spctl assessment reported (accepted for a notarised Developer ID build)" ;;
    G0-SIGN:command) echo "scripts/b01-spike.sh install <DriveApp.app|DriveApp.dmg>  (ditto; codesign --verify --deep --strict --verbose=2; codesign -d -r-; spctl --assess --type execute -vv)" ;;
    G0-SIGN:verify) echo '["Whether the FSKit entitlement and app group need a provisioning profile for Developer ID distribution"]' ;;
    G0-EXT-ACTIVATE:title) echo "FSKit extension registered and enabled" ;;
    G0-EXT-ACTIVATE:reqs) echo '["FR03"]' ;;
    G0-EXT-ACTIVATE:expected) echo "pluginkit lists <APP_BUNDLE_ID>.fsext under com.apple.fskit.fsmodule with '+' (enabled) after the user enables it in System Settings; LaunchAgent label registered with launchd" ;;
    G0-EXT-ACTIVATE:command) echo "scripts/b01-spike.sh enable  (open app; approve Login Item; System Settings > General > Login Items & Extensions > File System Extensions; pluginkit -m -v -p com.apple.fskit.fsmodule)" ;;
    G0-EXT-ACTIVATE:verify) echo '["Settings URL x-apple.systempreferences:com.apple.LoginItems-Settings.extension opens Login Items & Extensions; File System Extensions sub-pane has no known direct URL","pluginkit extension point id com.apple.fskit.fsmodule and the + (enabled) marker for FSKit modules","Whether extension enablement works inside a macOS 26 VM (docs/10 section 4)"]' ;;
    G0-MOUNT:title) echo "Read-only test volume mounts" ;;
    G0-MOUNT:reqs) echo '["FR03"]' ;;
    G0-MOUNT:expected) echo "mount -F -t driveappspike <resource> <mountpoint> exits 0 and the mountpoint appears in the mount table within 10 s" ;;
    G0-MOUNT:command) echo "scripts/b01-spike.sh mount  (mkdir -p ~/DriveAppSpike/mnt; mount -F -t driveappspike driveappspike://spike ~/DriveAppSpike/mnt; resource from SPIKE_RESOURCE)" ;;
    G0-MOUNT:verify) echo '["mount -F -t <shortname> <resource> <mountpoint> syntax for FSKit modules on macOS 26","mount(8) turns driveappspike://spike into an FSGenericURLResource (FSSupportsGenericURLResources/FSSupportedSchemes) and reaches loadResource; whether sudo is required"]' ;;
    G0-LIST:title) echo "Directory listing matches the fixture manifest" ;;
    G0-LIST:reqs) echo '["FR04"]' ;;
    G0-LIST:expected) echo "Recursive listing has exactly the manifest files and directories with matching sizes; Unicode name resolves (NFC/NFD recorded); no extra entries apart from ignored system dot-files" ;;
    G0-LIST:command) echo "scripts/b01-spike.sh test  (ls -laR <mountpoint>; compare with fixture-check manifest)" ;;
    G0-LIST:verify) echo '[]' ;;
    G0-READ-RANGE:title) echo "Random byte ranges match the deterministic fixture" ;;
    G0-READ-RANGE:reqs) echo '["FR05","NFR01"]' ;;
    G0-READ-RANGE:expected) echo "fixture-check verify --random-reads 500 --seed 1 reports pass; every file SHA-256 matches the manifest; independent seeded uncached range reads match the generated reference copy" ;;
    G0-READ-RANGE:command) echo "fixture-check verify <mountpoint> --random-reads 500 --seed 1  (plus helper hash + range cross-check via scripts/b01-spike.sh test)" ;;
    G0-READ-RANGE:verify) echo '["F_NOCACHE bypasses the unified buffer cache on an FSKit volume so reads reach the extension"]' ;;
    G0-EOF:title) echo "Reads at or after EOF and zero-length reads" ;;
    G0-EOF:reqs) echo '["FR05"]' ;;
    G0-EOF:expected) echo "Read at EOF and past EOF returns 0 bytes; read at size-1 returns exactly 1 byte; zero-length read returns 0 bytes; lseek(SEEK_END) = manifest size; dd past EOF copies 0 bytes" ;;
    G0-EOF:command) echo "scripts/b01-spike.sh test  (python pread at size, size+1000, size-1, length 0; dd if=<mnt>/seg-plus-1.bin bs=1 skip=4194304 count=10)" ;;
    G0-EOF:verify) echo '[]' ;;
    G0-CANCEL:title) echo "Reader killed mid-read; volume stays responsive" ;;
    G0-CANCEL:reqs) echo '["FR05"]' ;;
    G0-CANCEL:expected) echo "A cat loop and a slow uncached reader of seg-plus-1.bin are SIGKILLed mid-read, exit within 5 s, and a stat/list/read probe of the volume succeeds with correct bytes within 5 s" ;;
    G0-CANCEL:command) echo "scripts/b01-spike.sh test  (cat loop + slow reader on seg-plus-1.bin, kill -KILL, probe with 5 s timeout)" ;;
    G0-CANCEL:verify) echo '["Whether FSKit delivers kernel-side cancellation to the extension (look for cancel(RequestID) in the redacted log)"]' ;;
    G0-READONLY:title) echo "Writes rejected with read-only errors" ;;
    G0-READONLY:reqs) echo '["FR12"]' ;;
    G0-READONLY:expected) echo "touch, mkdir, rm, mv, append, O_CREAT, O_RDWR, truncate, chmod, symlink and utime inside the volume all fail with EROFS (EPERM accepted, noted); fixture files unchanged afterwards" ;;
    G0-READONLY:command) echo "scripts/b01-spike.sh test  (touch/mkdir/rm -f/mv/append in the volume + python errno probes)" ;;
    G0-READONLY:verify) echo '[]' ;;
    G0-IPC-AUTH:title) echo "Unauthorised XPC client rejected by StorageService" ;;
    G0-IPC-AUTH:reqs) echo '["NFR05"]' ;;
    G0-IPC-AUTH:expected) echo "With the Mach service registered and the genuine extension reading correctly, an unsigned swift-interpreter client and an ad-hoc-signed compiled client that send a well-formed status request (send:withReply:) to <TEAM>.<APP_BUNDLE_ID>.storage get no reply and see the connection invalidated; the service log has no 'Accepted XPC client pid <spoof pid>' line and no 'WITHOUT code-signing checks' fault" ;;
    G0-IPC-AUTH:command) echo "scripts/b01-spike.sh test  (xcrun swift spoof-client.swift <mach-service>; xcrun swiftc + codesign -s - spoof-client; optional ad-hoc re-signed app copy with SPIKE_SPOOF_APP_ARGS)" ;;
    G0-IPC-AUTH:verify) echo '["Sandboxed FSKit extension can mach-lookup a service named with its app-group prefix (<TEAM>.<APP_BUNDLE_ID>.storage)","Listener-level setConnectionCodeSigningRequirement rejects the spoof before shouldAcceptNewConnection runs (so no service-side reject line is expected; check com.apple.xpc logs)","Spoof selector send:withReply: still matches Shared/StorageServiceXPC.swift"]' ;;
    G0-SERVICE-RESTART:title) echo "Service restart: reads fail clearly, never hang or return wrong bytes, then recover" ;;
    G0-SERVICE-RESTART:reqs) echo '["FR03","NFR06","NFR01"]' ;;
    G0-SERVICE-RESTART:expected) echo "During an uncached read loop: launchctl kickstart -k restarts the service (new pid); a SIGSTOPped service makes reads fail within 30 s (+5 s margin); errors are specific errnos (ENOTCONN/ETIMEDOUT/EIO/ECANCELED...); zero wrong bytes; reads recover within 30 s of restart/resume" ;;
    G0-SERVICE-RESTART:command) echo "scripts/b01-spike.sh test  (read loop; launchctl kickstart -k gui/\$UID/<label> (kill -9 fallback); kill -STOP/-CONT <pid>)" ;;
    G0-SERVICE-RESTART:verify) echo '["launchctl kickstart -k works on an SMAppService-registered LaunchAgent label","Kernel/FSKit does not impose its own shorter or longer timeout on a stalled extension read"]' ;;
    G0-UNMOUNT:title) echo "Clean unmount" ;;
    G0-UNMOUNT:reqs) echo '["FR03"]' ;;
    G0-UNMOUNT:expected) echo "umount <mountpoint> (diskutil unmount fallback) succeeds within 10 s, the mountpoint leaves the mount table and the empty directory is removed" ;;
    G0-UNMOUNT:command) echo "scripts/b01-spike.sh unmount  (umount <mountpoint> || diskutil unmount <mountpoint>)" ;;
    G0-UNMOUNT:verify) echo '[]' ;;
    *) echo "" ;;
  esac
}

# write_result TEST_ID STATUS REASON OBSERVED_JSON STARTED [EXIT_CODE] [ARTIFACTS_JSON]
write_result() {
  local tid="$1" status="$2" reason="$3" observed="${4:-}" started="$5" rc="${6:-}" artifacts="${7:-[]}"
  local dir fm="null" bundle_id
  dir="$(evidence_dir "$tid")"
  mkdir -p "$dir"
  if [ -s "$MANIFEST_CACHE" ]; then cp "$MANIFEST_CACHE" "$dir/fixture-manifest.json"; fm='"fixture-manifest.json"'; fi
  [ -n "$observed" ] || observed=null
  [ -n "$rc" ] || rc=null
  bundle_id="$APP_ID"
  cat >"$dir/result.json" <<EOF
{
  "schemaVersion": 1,
  "testId": $(json_str "$tid"),
  "gate": "G0",
  "title": $(json_str "$(meta "$tid" title)"),
  "requirements": $(meta "$tid" reqs),
  "status": $(json_str "$status"),
  "reason": $(json_str_or_null "$reason"),
  "expected": $(json_str "$(meta "$tid" expected)"),
  "observed": $observed,
  "command": $(json_str "$(meta "$tid" command)"),
  "build": {"id": $(json_str "$BUILD_ID"), "shortVersion": $(json_str_or_null "$APP_SHORT"), "bundleVersion": $(json_str_or_null "$APP_BUILD"), "bundleId": $(json_str_or_null "$bundle_id")},
  "os": {"id": $(json_str "$OS_ID"), "productVersion": $(json_str_or_null "$OS_PV"), "buildVersion": $(json_str_or_null "$OS_BV"), "model": $(json_str_or_null "$OS_MODEL")},
  "startedAt": $(json_str "$started"),
  "finishedAt": $(json_str "$(now_utc)"),
  "exitCode": $rc,
  "artifacts": $artifacts,
  "fixtureManifest": $fm,
  "g0Verify": $(meta "$tid" verify),
  "recordedBy": $(json_str "scripts/b01-spike.sh ($TOOL_VERSION)")
}
EOF
  note_rc "$status"
  printf '  %-20s %-8s %s\n' "$tid" "$status" "${reason:-}" >&2
}

record_blocked() { # record_blocked REASON TEST_ID...
  local reason="$1" t started
  shift
  started="$(now_utc)"
  for t in "$@"; do write_result "$t" blocked "$reason" null "$started"; done
}

# obs_result TEST_ID OBS_FILE STARTED [RC] [ARTIFACTS_JSON]: write a result from a helper observation file
obs_result() {
  local tid="$1" obs="$2" started="$3" rc="${4:-}" arts="${5:-[]}" st rs ob
  if [ -s "$obs" ]; then
    st="$(py get "$obs" status)"; rs="$(py get "$obs" reason)"; ob="$(py getjson "$obs" observed)"
  else
    st=fail; rs="helper produced no observation (see stderr)"; ob=null
  fi
  write_result "$tid" "$st" "$rs" "$ob" "$started" "$rc" "$arts"
}

# ------------------------------------------------------------------ helper (python)

write_helper() {
  have python3 || return 0
  cat >"$HELPER" <<'PY'
"""Helper for scripts/b01-spike.sh (generated at run time; edit the script, not this file)."""
import datetime, errno, glob, hashlib, json, os, plistlib, random, re, stat, sys, time, unicodedata

MIB = 1024 * 1024
RO_ERRNOS = {"EROFS", "EPERM"}
SERVICE_ERRNOS = {"ENOTCONN", "ETIMEDOUT", "EIO", "ECANCELED", "ESTALE", "ENXIO", "EAGAIN",
                  "EINTR", "ENODEV", "EPIPE", "ECONNRESET", "ECONNREFUSED", "EDEADLK"}
HIDDEN = re.compile(r"^(\.DS_Store|\._.*|\.fseventsd|\.Spotlight-V100|\.Trashes|\.TemporaryItems|\.metadata_never_index.*)$")
TESTS = ["G0-ENV", "G0-SIGN", "G0-EXT-ACTIVATE", "G0-MOUNT", "G0-LIST", "G0-READ-RANGE", "G0-EOF",
         "G0-CANCEL", "G0-READONLY", "G0-IPC-AUTH", "G0-SERVICE-RESTART", "G0-UNMOUNT"]
CRITERIA = [("Signing", ["G0-ENV", "G0-SIGN"]),
            ("Extension activation", ["G0-EXT-ACTIVATE"]),
            ("Mounting and reads", ["G0-MOUNT", "G0-LIST", "G0-READ-RANGE", "G0-EOF", "G0-CANCEL", "G0-READONLY", "G0-UNMOUNT"]),
            ("Authenticated IPC", ["G0-IPC-AUTH", "G0-SERVICE-RESTART"])]


def nfc(s):
    return unicodedata.normalize("NFC", s)


def ename(code):
    return errno.errorcode.get(code, str(code))


def emit(out, status, reason, observed):
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"status": status, "reason": reason, "observed": observed}, f, indent=2, ensure_ascii=False)
        f.write("\n")


def load_manifest(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    files = d.get("files", []) if isinstance(d, dict) else d
    dirs = d.get("directories", []) if isinstance(d, dict) else []
    out = [{"path": nfc(e.get("path") or e.get("name")), "size": int(e["size"]),
            "sha256": (e.get("sha256") or "").lower()} for e in files]
    return out, sorted(nfc(x) for x in dirs)


def open_nocache(path):
    fd = os.open(path, os.O_RDONLY)
    if sys.platform == "darwin":
        import fcntl
        try:
            fcntl.fcntl(fd, getattr(fcntl, "F_NOCACHE", 48), 1)
        except OSError:
            pass
    return fd


def pread_full(fd, length, offset):
    parts, got = [], 0
    while got < length:
        b = os.pread(fd, min(length - got, 4 * MIB), offset + got)
        if not b:
            break
        parts.append(b)
        got += len(b)
    return b"".join(parts)


def walk(root):
    files, dirs, hidden, nonnfc = {}, set(), [], []
    for dp, dns, fns in os.walk(root):
        for n in list(dns):
            rel = os.path.relpath(os.path.join(dp, n), root)
            if HIDDEN.match(n):
                hidden.append(nfc(rel))
                dns.remove(n)
                continue
            if nfc(n) != n:
                nonnfc.append(nfc(rel))
            dirs.add(nfc(rel))
        for n in fns:
            full = os.path.join(dp, n)
            rel = os.path.relpath(full, root)
            if HIDDEN.match(n):
                hidden.append(nfc(rel))
                continue
            if nfc(n) != n:
                nonnfc.append(nfc(rel))
            files[nfc(rel)] = (full, os.lstat(full))
    return files, dirs, hidden, nonnfc


def ref_bytes(refdir, rel, offset, length):
    with open(os.path.join(refdir, *rel.split("/")), "rb") as f:
        f.seek(offset)
        return f.read(length)


def cmd_list(mount, manifest, out):
    t0 = time.monotonic()
    files, dirs, hidden, nonnfc = walk(mount)
    ms = round((time.monotonic() - t0) * 1000, 1)
    exp, expdirs = load_manifest(manifest)
    expmap = {e["path"]: e for e in exp}
    missing = sorted(set(expmap) - set(files))
    extra = sorted(set(files) - set(expmap))
    size_mm, type_mm = [], []
    for p, e in expmap.items():
        if p in files:
            st = files[p][1]
            if not stat.S_ISREG(st.st_mode):
                type_mm.append(p)
            elif st.st_size != e["size"]:
                size_mm.append({"path": p, "expected": e["size"], "observed": st.st_size})
    missing_dirs = sorted(set(expdirs) - dirs)
    extra_dirs = sorted(dirs - set(expdirs))
    ok = not (missing or extra or size_mm or type_mm or missing_dirs or extra_dirs)
    observed = {"files": [{"path": p, "size": files[p][1].st_size, "mode": oct(files[p][1].st_mode)} for p in sorted(files)],
                "directories": sorted(dirs), "missing": missing, "extra": extra, "sizeMismatch": size_mm,
                "notRegular": type_mm, "missingDirectories": missing_dirs, "extraDirectories": extra_dirs,
                "ignoredSystemEntries": hidden, "namesNotNFC": nonnfc, "walkMs": ms}
    emit(out, "pass" if ok else "fail", None if ok else "listing differs from fixture manifest", observed)


def cmd_hashes(mount, manifest, refdir, out, seed, n):
    seed, n = int(seed), int(n)
    exp, _ = load_manifest(manifest)
    files, _, _, _ = walk(mount)
    hashes, problems = [], []
    for e in exp:
        if e["path"] not in files:
            problems.append({"path": e["path"], "problem": "missing"})
            continue
        t0 = time.monotonic()
        h, off = hashlib.sha256(), 0
        fd = open_nocache(files[e["path"]][0])
        try:
            while True:
                b = os.pread(fd, MIB, off)
                if not b:
                    break
                h.update(b)
                off += len(b)
        finally:
            os.close(fd)
        match = h.hexdigest() == e["sha256"] and off == e["size"]
        hashes.append({"path": e["path"], "bytes": off, "sha256": h.hexdigest(), "match": match,
                       "ms": round((time.monotonic() - t0) * 1000, 1)})
        if not match:
            problems.append({"path": e["path"], "problem": "sha256 or size mismatch"})
    rng = random.Random(seed)
    cands = [e for e in exp if e["path"] in files]
    bounds = [0, 1, 4095, 4096, 65535, 65536, 4 * MIB - 2, 4 * MIB - 1, 4 * MIB, 4 * MIB + 1]
    fails, total = [], 0
    for _ in range(n if cands else 0):
        e = rng.choice(cands)
        size = e["size"]
        r = rng.random()
        if r < 0.3:
            off = rng.choice([b for b in bounds if b <= size + 1] or [0])
        elif r < 0.4:
            off = size
        else:
            off = rng.randint(0, max(size - 1, 0))
        length = rng.choice([0, 1, 7, 4096, 65536, rng.randint(0, 256 * 1024), 4 * MIB + 2])
        want = ref_bytes(refdir, e["path"], off, length)
        fd = open_nocache(files[e["path"]][0])
        try:
            got = pread_full(fd, length, off)
        finally:
            os.close(fd)
        total += len(got)
        if got != want:
            fails.append({"path": e["path"], "offset": off, "length": length,
                          "expectedBytes": len(want), "observedBytes": len(got)})
    ok = not problems and not fails
    observed = {"fileHashes": hashes, "hashProblems": problems,
                "rangeReads": {"count": n, "seed": seed, "bytesRead": total, "failures": fails[:20],
                               "failureCount": len(fails)}}
    emit(out, "pass" if ok else "fail", None if ok else "byte mismatch against manifest/reference", observed)


def cmd_eof(mount, manifest, out):
    exp, _ = load_manifest(manifest)
    files, _, _, _ = walk(mount)
    rows, ok = [], True
    for e in exp:
        if e["path"] not in files:
            rows.append({"path": e["path"], "pass": False, "problem": "missing"})
            ok = False
            continue
        size, row = e["size"], {"path": e["path"], "size": e["size"]}
        fd = open_nocache(files[e["path"]][0])
        try:
            row["seekEnd"] = os.lseek(fd, 0, os.SEEK_END)
            row["atEOF"] = len(os.pread(fd, 10, size))
            row["pastEOF"] = len(os.pread(fd, 10, size + 1000))
            row["zeroLength"] = len(os.pread(fd, 0, 0))
            row["lastByte"] = len(os.pread(fd, 10, size - 1)) if size > 0 else None
            try:
                row["hugeOffset"] = len(os.pread(fd, 10, 1 << 62))
            except OSError as exc:
                row["hugeOffset"] = ename(exc.errno)
        except OSError as exc:
            row["error"] = ename(exc.errno)
        finally:
            os.close(fd)
        good = ("error" not in row and row["seekEnd"] == size and row["atEOF"] == 0 and row["pastEOF"] == 0
                and row["zeroLength"] == 0 and (size == 0 or row["lastByte"] == 1)
                and row["hugeOffset"] in (0, "EINVAL", "EFBIG", "EOVERFLOW"))
        row["pass"] = good
        ok = ok and good
        rows.append(row)
    emit(out, "pass" if ok else "fail", None if ok else "EOF/zero-length behaviour differs", {"files": rows})


def cmd_readonly(mount, shell_tsv, manifest, out):
    j = lambda n: os.path.join(mount, n)
    target = j("one.bin")
    ops = [
        ("create", lambda: os.close(os.open(j("ro-probe-create.txt"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)),
         lambda: os.unlink(j("ro-probe-create.txt"))),
        ("mkdir", lambda: os.mkdir(j("ro-probe-dir")), lambda: os.rmdir(j("ro-probe-dir"))),
        ("open-append", lambda: os.close(os.open(target, os.O_WRONLY | os.O_APPEND)), None),
        ("open-rdwr", lambda: os.close(os.open(target, os.O_RDWR)), None),
        ("truncate", lambda: os.truncate(target, 0), None),
        ("chmod", lambda: os.chmod(target, 0o777), None),
        ("symlink", lambda: os.symlink("one.bin", j("ro-probe-link")), lambda: os.unlink(j("ro-probe-link"))),
        ("utime", lambda: os.utime(target, None), None),
        ("rename", lambda: os.rename(target, j("one-renamed.bin")), lambda: os.rename(j("one-renamed.bin"), target)),
        ("unlink", lambda: os.unlink(target), None),
    ]
    probes, ok, eperm = [], True, False
    for name, fn, undo in ops:
        try:
            fn()
            res = "succeeded"
            if undo:
                try:
                    undo()
                    res = "succeeded (undone)"
                except OSError:
                    pass
        except OSError as exc:
            res = ename(exc.errno)
        good = res in RO_ERRNOS
        eperm = eperm or res == "EPERM"
        ok = ok and good
        probes.append({"op": name, "result": res, "pass": good})
    shell = []
    if os.path.exists(shell_tsv):
        with open(shell_tsv, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t", 2)
                if len(parts) < 3:
                    continue
                name, rc, err = parts[0], int(parts[1]), parts[2]
                good = rc != 0 and bool(re.search(r"Read-only file system|Operation not permitted", err))
                ok = ok and good
                shell.append({"command": name, "exitCode": rc, "stderr": err, "pass": good})
    exp, _ = load_manifest(manifest)
    files, _, _, _ = walk(mount)
    leftovers = sorted(p for p in files if p.startswith("ro-probe") or p == "one-renamed.bin")
    one = next((e for e in exp if e["path"] == "one.bin"), None)
    intact = bool(one) and "one.bin" in files and files["one.bin"][1].st_size == one["size"]
    if intact:
        with open(files["one.bin"][0], "rb") as f:
            intact = hashlib.sha256(f.read()).hexdigest() == one["sha256"]
    ok = ok and intact and not leftovers
    reason = None
    if not ok:
        reason = "a write-type operation did not fail with EROFS/EPERM or the fixture changed"
    elif eperm:
        reason = "EPERM accepted; FR12 prefers EROFS"
    emit(out, "pass" if ok else "fail", reason,
         {"syscalls": probes, "shell": shell, "fixtureIntact": intact, "leftovers": leftovers})


def cmd_slowread(path, progress):
    fd, off, total = open_nocache(path), 0, 0
    while True:
        b = os.pread(fd, 65536, off)
        if not b:
            off = 0
            continue
        off += len(b)
        total += len(b)
        with open(progress, "w") as f:
            f.write(str(total))
        time.sleep(0.005)


def cmd_probe(mount, refdir, out):
    t0 = time.monotonic()
    obs = {}
    try:
        os.stat(mount)
        obs["rootEntries"] = len(os.listdir(mount))
        checks = []
        for rel, off, ln in (("one.bin", 0, 1), ("64k.bin", 0, 4096), ("seg-plus-1.bin", 4 * MIB - 8, 9)):
            fd = open_nocache(os.path.join(mount, rel))
            try:
                got = pread_full(fd, ln, off)
            finally:
                os.close(fd)
            checks.append({"path": rel, "offset": off, "length": ln, "match": got == ref_bytes(refdir, rel, off, ln)})
        obs["reads"] = checks
        ok = all(c["match"] for c in checks)
    except OSError as exc:
        obs["error"] = ename(exc.errno)
        ok = False
    obs["elapsedMs"] = round((time.monotonic() - t0) * 1000, 1)
    emit(out, "pass" if ok else "fail", None if ok else "probe failed", obs)


def cmd_readloop(mount, refdir, manifest, log, duration, seed, stopfile):
    exp, _ = load_manifest(manifest)
    cands = [e for e in exp if e["size"] >= 65536]
    rng = random.Random(int(seed))
    end = time.time() + float(duration)
    i = 0
    with open(log, "a", buffering=1) as lf:
        while time.time() < end and not os.path.exists(stopfile):
            e = rng.choice(cands)
            off = rng.randint(0, e["size"] - 1)
            ln = rng.choice([4096, 65536, 262144])
            t0 = time.time()
            lf.write(json.dumps({"ev": "begin", "i": i, "t": t0}) + "\n")
            rec = {"ev": "end", "i": i, "t": t0, "path": e["path"], "offset": off, "length": ln}
            try:
                fd = open_nocache(os.path.join(mount, *e["path"].split("/")))
                try:
                    got = pread_full(fd, ln, off)
                finally:
                    os.close(fd)
                want = ref_bytes(refdir, e["path"], off, ln)
                rec["result"] = "ok" if got == want else ("short" if want.startswith(got) else "mismatch")
            except OSError as exc:
                rec["result"] = "error"
                rec["errno"] = ename(exc.errno)
            rec["dt"] = round(time.time() - t0, 3)
            lf.write(json.dumps(rec) + "\n")
            i += 1
            time.sleep(0.05)


def cmd_analyze_restart(readlog, events, out, hang_limit="35", recover_limit="30"):
    hang_limit, recover_limit = float(hang_limit), float(recover_limit)
    begins, ends, ev = {}, {}, {}
    with open(readlog) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            (begins if r["ev"] == "begin" else ends)[r["i"]] = r
    with open(events) as f:
        for line in f:
            r = json.loads(line)
            ev[r["ev"]] = r
    unfinished = sorted(set(begins) - set(ends))
    reads = [ends[i] for i in sorted(ends)]
    mism = [r for r in reads if r["result"] in ("mismatch", "short")]
    errs = [r for r in reads if r["result"] == "error"]
    unclear = sorted({r["errno"] for r in errs} - SERVICE_ERRNOS)
    max_dt = max([r["dt"] for r in reads] or [0])
    problems = []

    def first_ok_after(t):
        oks = [r for r in reads if r["result"] == "ok" and r["t"] >= t]
        return round(oks[0]["t"] + oks[0]["dt"] - t, 3) if oks else None

    def errs_between(a, b):
        return [r for r in errs if a <= r["t"] <= b]

    obs = {"reads": len(reads), "ok": sum(1 for r in reads if r["result"] == "ok"), "errors": len(errs),
           "errnoCounts": {k: sum(1 for r in errs if r["errno"] == k) for k in sorted({r["errno"] for r in errs})},
           "mismatches": len(mism), "mismatchSamples": mism[:10], "unfinishedReads": len(unfinished),
           "maxReadSeconds": max_dt, "events": ev}
    if not reads:
        problems.append("no reads completed")
    if mism:
        problems.append("wrong bytes returned")
    if unfinished:
        problems.append("a read never returned (hang)")
    if max_dt > hang_limit:
        problems.append("a read took %.1f s (> %.0f s)" % (max_dt, hang_limit))
    if unclear:
        problems.append("unexpected errno(s): " + ",".join(unclear))
    a = ev.get("restart")
    if a:
        pa = {"method": a.get("method"), "pidBefore": a.get("pidBefore"), "pidAfter": ev.get("restarted", {}).get("pid"),
              "errorsWithin40s": len(errs_between(a["t"], a["t"] + 40)), "recoverySeconds": first_ok_after(a["t"])}
        obs["phaseRestart"] = pa
        if not pa["pidBefore"] or not pa["pidAfter"] or pa["pidBefore"] == pa["pidAfter"]:
            problems.append("service pid did not change after restart")
        if pa["recoverySeconds"] is None or pa["recoverySeconds"] > recover_limit:
            problems.append("reads did not recover within %.0f s of restart" % recover_limit)
    else:
        problems.append("restart phase did not run")
    s, c = ev.get("stop"), ev.get("cont")
    if s and c:
        stalled = [r for r in reads if s["t"] <= r["t"] <= c["t"]]
        pb = {"stopSeconds": round(c["t"] - s["t"], 1), "readsStarted": len(stalled),
              "errorsWhileStopped": len(errs_between(s["t"], c["t"])),
              "maxReadSecondsWhileStopped": max([r["dt"] for r in stalled] or [0]),
              "recoverySeconds": first_ok_after(c["t"])}
        obs["phaseHang"] = pb
        if pb["errorsWhileStopped"] == 0:
            problems.append("no read failed while the service was stopped (cache or no timeout?)")
        if pb["recoverySeconds"] is None or pb["recoverySeconds"] > recover_limit:
            problems.append("reads did not recover within %.0f s of SIGCONT" % recover_limit)
    tail = reads[-5:]
    if len(tail) < 5 or any(r["result"] != "ok" for r in tail):
        problems.append("last 5 reads were not all ok")
    emit(out, "fail" if problems else "pass", "; ".join(problems) or None, obs)


def cmd_redact():
    home = os.environ.get("HOME", "")
    user = os.environ.get("USER", "")
    subs = [
        (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
        (re.compile(r"(?i)\b(access_token|refresh_token|id_token|client_secret|auth_code|authorization_code|"
                    r"token|secret|password|passwd|api[_-]?key|upload_id)(\s*[=:]\s*\"?)[^\s\"&,;]+"), r"\1\2<redacted>"),
        (re.compile(r"\bya29\.[A-Za-z0-9._-]+"), "<redacted-token>"),
        (re.compile(r"\b1//[A-Za-z0-9._-]{20,}"), "<redacted-token>"),
        (re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"), "<redacted-jwt>"),
        (re.compile(r"https?://[^\s\"']*[?&][^\s\"']*"), "<redacted-url-with-query>"),
        (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<redacted-email>"),
        (re.compile(r"(Developer ID Application|Apple Development|Apple Distribution|Developer ID Installer): [^(\n]*\("),
         r"\1: <redacted> ("),
        (re.compile(r"\b[A-Fa-f0-9]{40,}\b"), "<redacted-hex>"),
        (re.compile(r"(?<![A-Za-z0-9/+])[A-Za-z0-9+/]{48,}={0,2}"), "<redacted-b64>"),
        (re.compile(r"/private/var/folders/[^\s\"']+"), "<tmp>"),
        (re.compile(r"/var/folders/[^\s\"']+"), "<tmp>"),
    ]
    for line in sys.stdin:
        if home and len(home) > 1:
            line = line.replace(home, "~")
        line = re.sub(r"/Users/(?!Shared/)[^/\s\"']+", "/Users/<user>", line)
        line = re.sub(r"/home/[^/\s\"']+", "/home/<user>", line)
        for rx, rep in subs:
            line = rx.sub(rep, line)
        if user and len(user) >= 3:
            line = re.sub(r"\b%s\b" % re.escape(user), "<user>", line)
        sys.stdout.write(line)


def cmd_plist2json():
    raw = sys.stdin.buffer.read()
    if not raw.strip():
        print("null")
        return
    try:
        val = plistlib.loads(raw)
    except Exception:
        print("null")
        return

    def conv(v):
        if isinstance(v, dict):
            return {k: conv(x) for k, x in v.items()}
        if isinstance(v, list):
            return [conv(x) for x in v]
        if isinstance(v, bytes):
            return "<data %d bytes>" % len(v)
        if isinstance(v, datetime.datetime):
            return v.isoformat()
        return v
    print(json.dumps(conv(val), ensure_ascii=False, sort_keys=True))


def _get(path, key):
    with open(path, encoding="utf-8") as f:
        v = json.load(f)
    for k in key.split("."):
        v = v.get(k) if isinstance(v, dict) else None
    return v


def cmd_get(path, key):
    v = _get(path, key)
    print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))


def cmd_getjson(path, key):
    print(json.dumps(_get(path, key), ensure_ascii=False))


def cmd_window(result, pad="5"):
    def local(s, delta):
        t = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return (t + datetime.timedelta(seconds=delta)).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    with open(result) as f:
        r = json.load(f)
    print(local(r["startedAt"], -int(pad)) + "|" + local(r["finishedAt"], int(pad)))


def cmd_add_artifacts(result, *paths):
    with open(result, encoding="utf-8") as f:
        r = json.load(f)
    arts = r.get("artifacts") or []
    for p in paths:
        if p not in arts:
            arts.append(p)
    r["artifacts"] = arts
    with open(result, "w", encoding="utf-8") as f:
        json.dump(r, f, indent=2, ensure_ascii=False)
        f.write("\n")


def cmd_summary(osdir, out):
    results = {}
    for t in TESTS:
        p = os.path.join(osdir, t, "result.json")
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                r = json.load(f)
            results[t] = {"status": r["status"], "reason": r.get("reason")}
        else:
            results[t] = {"status": "not-run", "reason": "no result.json"}

    def roll(ids):
        sts = [results[i]["status"] for i in ids]
        if "fail" in sts:
            return "fail"
        if all(s == "pass" for s in sts):
            return "pass"
        return "blocked"
    criteria = [{"criterion": c, "tests": ids, "status": roll(ids)} for c, ids in CRITERIA]
    decision = roll(TESTS)
    summary = {"schemaVersion": 1, "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "evidenceDir": os.path.relpath(osdir), "g0Decision": decision, "criteria": criteria, "results": results}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("G0 decision: %s" % decision.upper())
    for c in criteria:
        print("  %-22s %s" % (c["criterion"], c["status"]))
    for t in TESTS:
        print("    %-20s %-8s %s" % (t, results[t]["status"], results[t]["reason"] or ""))


def cmd_now():
    print("%.3f" % time.time())


CMDS = {"list": cmd_list, "hashes": cmd_hashes, "eof": cmd_eof, "readonly": cmd_readonly,
        "slowread": cmd_slowread, "probe": cmd_probe, "readloop": cmd_readloop,
        "analyze-restart": cmd_analyze_restart, "redact": cmd_redact, "plist2json": cmd_plist2json,
        "get": cmd_get, "getjson": cmd_getjson, "window": cmd_window, "add-artifacts": cmd_add_artifacts,
        "summary": cmd_summary, "now": cmd_now}

if __name__ == "__main__":
    CMDS[sys.argv[1]](*sys.argv[2:])
PY
}

# ------------------------------------------------------------------ fixtures

FIXTURE_CHECK_BIN=""
find_fixture_check() {
  local pkg="$REPO_ROOT/Packages/StorageCore" cand
  for cand in "${FIXTURE_CHECK:-}" "$pkg/.build/release/fixture-check" "$(command -v fixture-check 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then FIXTURE_CHECK_BIN="$cand"; return 0; fi
  done
  if [ -f "$pkg/Package.swift" ] && have swift; then
    say "Building fixture-check (swift build -c release --product fixture-check) ..."
    if (cd "$pkg" && swift build -c release --product fixture-check) >"$WORK/fixture-check-build.log" 2>&1 \
       && [ -x "$pkg/.build/release/fixture-check" ]; then
      FIXTURE_CHECK_BIN="$pkg/.build/release/fixture-check"; return 0
    fi
    say "fixture-check build failed; see $WORK/fixture-check-build.log"
  fi
  return 1
}

prepare_fixtures() { # -> 0 when reference dir and manifest are ready
  if [ -s "$MANIFEST_CACHE" ] && [ -d "$REF_DIR" ] && [ -n "$FIXTURE_CHECK_BIN" ]; then return 0; fi
  find_fixture_check || return 1
  "$FIXTURE_CHECK_BIN" manifest >"$MANIFEST_CACHE.tmp" && mv "$MANIFEST_CACHE.tmp" "$MANIFEST_CACHE" || return 1
  "$FIXTURE_CHECK_BIN" generate "$REF_DIR" >"$WORK/fixture-generate.log" 2>&1 || return 1
}

# ------------------------------------------------------------------ preflight (G0-ENV)

cmd_preflight() {
  step "preflight: G0-ENV"
  local started rc=0 report="$WORK/validate-env.json" st reason fx=false fxpath="" ve
  started="$(now_utc)"
  bash "$SCRIPT_DIR/validate-env.sh" --role test --out "$report" || rc=$?
  if [ "${SPIKE_SKIP_FIXTURES:-0}" != 1 ] && prepare_fixtures; then fx=true; fxpath="$FIXTURE_CHECK_BIN"; fi
  case "$rc" in
    0) st=pass; reason="" ;;
    1) st=fail; reason="validate-env: a required check failed" ;;
    *) st=blocked; reason="validate-env: required checks blocked" ;;
  esac
  if [ "$IS_MAC" = 0 ]; then reason="$LINUX_REASON"; fi
  if [ "$st" = pass ] && [ "$fx" = false ]; then st=blocked; reason="fixture-check could not be built or run"; fi
  ve="$(cat "$report" 2>/dev/null || echo null)"
  [ -n "$ve" ] || ve=null
  fxpath="${fxpath/#$REPO_ROOT\//}"
  write_result G0-ENV "$st" "$reason" \
    "{\"validateEnv\":$ve,\"fixtures\":{\"ready\":$fx,\"fixtureCheck\":$(json_str_or_null "$fxpath"),\"manifestSaved\":$([ -s "$MANIFEST_CACHE" ] && echo true || echo false)}}" \
    "$started" "$rc"
}

# ------------------------------------------------------------------ install (G0-SIGN)

stage_source() { # stage_source APP|DMG -> sets SOURCE_APP (attaches a DMG read-only)
  local src="$1"
  case "$src" in
    *.dmg)
      DMG_MOUNT="$(mktemp -d "$WORK/dmg.XXXXXX")"
      hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$DMG_MOUNT" "$src" >/dev/null || die "cannot attach $src"
      SOURCE_APP="$(find "$DMG_MOUNT" -maxdepth 2 -name "$APP_NAME.app" -type d | head -n 1)"
      [ -n "$SOURCE_APP" ] || die "no $APP_NAME.app inside $src"
      ;;
    *) SOURCE_APP="${src%/}" ;;
  esac
  [ -d "$SOURCE_APP/Contents" ] || die "not an app bundle: $SOURCE_APP"
}

SIGN_JSON=""; SIGN_OK=1; SIGN_TEAMS=""
sign_component() { # sign_component ROLE PATH
  local role="$1" p="$2" vrc=0 vout dr info ident team flags runtime ents rel="."
  [ "$p" = "$APP" ] || rel="${p#"$APP"/}"
  vout="$(codesign --verify --strict --verbose=2 "$p" 2>&1)" || vrc=$?
  dr="$(codesign -d -r- "$p" 2>&1 | sed -n 's/^designated => //p' | head -n 1)"
  info="$(codesign -dv --verbose=2 "$p" 2>&1 || true)"
  ident="$(printf '%s\n' "$info" | sed -n 's/^Identifier=//p' | head -n 1)"
  team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  flags="$(printf '%s\n' "$info" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | head -n 1)"
  case "$flags" in *runtime*) runtime=true ;; *) runtime=false ;; esac
  ents="$(codesign -d --entitlements - --xml "$p" 2>/dev/null | py plist2json || echo null)"
  [ -n "$ents" ] || ents=null
  if [ "$vrc" != 0 ] || [ "$runtime" != true ] || [ -z "$team" ] || [ "$team" = "not set" ]; then SIGN_OK=0; fi
  case " $SIGN_TEAMS " in *" $team "*) ;; *) SIGN_TEAMS="${SIGN_TEAMS:+$SIGN_TEAMS }$team" ;; esac
  say "  $role: $ident team=$team runtime=$runtime verify_rc=$vrc"
  say "    designated requirement: $dr"
  SIGN_JSON="${SIGN_JSON:+$SIGN_JSON,}{\"role\":$(json_str "$role"),\"path\":$(json_str "$rel"),\"identifier\":$(json_str "$ident"),\"teamIdentifier\":$(json_str "$team"),\"hardenedRuntime\":$runtime,\"verifyExit\":$vrc,\"verifyOutput\":$(json_str "$(printf '%s' "$vout" | redact)"),\"designatedRequirement\":$(json_str "$dr"),\"entitlements\":$ents}"
}

cmd_install() {
  local src="${1:-${SPIKE_APP:-}}"
  step "install: G0-SIGN"
  if [ "$IS_MAC" = 0 ]; then record_blocked "$LINUX_REASON" G0-SIGN; return 0; fi
  [ -n "$src" ] || die "usage: b01-spike.sh install <DriveApp.app|DriveApp.dmg>"
  local started dest_dir dest src_id
  started="$(now_utc)"
  stage_source "$src"
  src_id="$(plist_get "$SOURCE_APP/Contents/Info.plist" CFBundleIdentifier)"
  case "$src_id" in "$EXPECTED_ID_PREFIX"*) ;; *) die "unexpected bundle id '$src_id' (want $EXPECTED_ID_PREFIX*)" ;; esac
  if [ -w /Applications ]; then dest_dir=/Applications; else dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; fi
  dest="$dest_dir/$APP_NAME.app"
  if [ "$SOURCE_APP" != "$dest" ]; then
    if [ -d "$dest" ]; then
      [ "$(plist_get "$dest/Contents/Info.plist" CFBundleIdentifier)" = "$src_id" ] || die "$dest exists with another bundle id; not replacing it"
      if pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1; then die "$APP_NAME is running from $dest; quit it (and unmount the spike volume) first"; fi
      rm -rf "$dest"
    fi
    ditto "$SOURCE_APP" "$dest"
  fi
  if [ -n "$DMG_MOUNT" ]; then hdiutil detach -quiet "$DMG_MOUNT" || true; DMG_MOUNT=""; fi
  state_set APP_PATH "$dest"
  set_app "$dest"
  init_build

  local deep_rc=0 deep_out spctl_rc=0 spctl_out staple_rc=null c agent_json="null" ext_found=false svc_found=false ext_mach="" ok_reason=""
  deep_out="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" || deep_rc=$?
  say "codesign --verify --deep --strict: rc=$deep_rc"
  SIGN_JSON=""; SIGN_OK=1; SIGN_TEAMS=""
  sign_component app "$APP"
  for c in "$APP"/Contents/Extensions/*.appex "$APP"/Contents/PlugIns/*.appex; do
    [ -d "$c" ] || continue
    sign_component extension "$c"
    if [ "$(plist_get "$c/Contents/Info.plist" CFBundleIdentifier)" = "$EXT_ID" ]; then
      ext_found=true; ext_mach="$(plist_get "$c/Contents/Info.plist" DriveAppStorageMachService)"
    fi
  done
  if [ -f "$APP/Contents/MacOS/DriveAppStorageService" ]; then
    svc_found=true; sign_component service "$APP/Contents/MacOS/DriveAppStorageService"
  fi
  for c in "$APP"/Contents/Library/LaunchAgents/*.plist; do
    [ -f "$c" ] || continue
    agent_json="$(plutil -convert xml1 -o - "$c" | py plist2json || echo null)"
    break
  done
  spctl_out="$(spctl --assess --type execute -vv "$APP" 2>&1)" || spctl_rc=$?
  say "spctl --assess (report only): rc=$spctl_rc"
  if xcrun --find stapler >/dev/null 2>&1; then staple_rc=0; xcrun stapler validate "$APP" >/dev/null 2>&1 || staple_rc=$?; fi

  local team_count expected_mach st=pass
  team_count="$(printf '%s\n' "$SIGN_TEAMS" | wc -w | tr -d ' ')"
  expected_mach="${SIGN_TEAMS%% *}.$APP_ID.storage"
  if [ "$deep_rc" != 0 ]; then st=fail; ok_reason="codesign --deep --strict failed"; fi
  if [ "$SIGN_OK" != 1 ]; then st=fail; ok_reason="${ok_reason:+$ok_reason; }a component failed verification, lacks hardened runtime or has no TeamIdentifier (ad-hoc build?)"; fi
  if [ "$team_count" != 1 ]; then st=fail; ok_reason="${ok_reason:+$ok_reason; }components are not signed by exactly one team"; fi
  if [ "$ext_found" != true ]; then st=fail; ok_reason="${ok_reason:+$ok_reason; }extension $EXT_ID not found in Contents/Extensions or PlugIns"; fi
  if [ "$svc_found" != true ]; then st=fail; ok_reason="${ok_reason:+$ok_reason; }Contents/MacOS/DriveAppStorageService not found"; fi
  if [ "$MACH_SERVICE" != "$expected_mach" ] || { [ -n "$ext_mach" ] && [ "$ext_mach" != "$expected_mach" ]; }; then
    st=fail; ok_reason="${ok_reason:+$ok_reason; }DriveAppStorageMachService is not <TEAM>.<APP_BUNDLE_ID>.storage in app/extension Info.plist"
  fi
  if [ "$st" = pass ] && [ "$spctl_rc" != 0 ]; then ok_reason="signatures valid; Gatekeeper rejected (report only - expected for a non-notarised build)"; fi

  local obs
  obs="{\"installedTo\":$(json_str "$(printf '%s' "$APP" | redact)"),\"deepVerify\":{\"exitCode\":$deep_rc,\"output\":$(json_str "$(printf '%s' "$deep_out" | redact)")},\"components\":[${SIGN_JSON}],\"teamIdentifiers\":$(json_str "$SIGN_TEAMS"),\"machService\":{\"app\":$(json_str "$MACH_SERVICE"),\"extension\":$(json_str "$ext_mach"),\"expected\":$(json_str "$expected_mach")},\"launchAgent\":$agent_json,\"gatekeeper\":{\"exitCode\":$spctl_rc,\"output\":$(json_str "$(printf '%s' "$spctl_out" | redact)")},\"staplerValidateExit\":$staple_rc}"
  write_result G0-SIGN "$st" "$ok_reason" "$obs" "$started" "$deep_rc"
}

# ------------------------------------------------------------------ enable (G0-EXT-ACTIVATE)

ext_line() { pluginkit -m -v -p "$FSKIT_EXTENSION_POINT" 2>/dev/null | grep -F "$EXT_ID" | head -n 1 || true; }
service_print() { launchctl print "gui/$(id -u)/$SERVICE_LABEL" 2>/dev/null || true; }
service_pid() { service_print | awk '/^[[:space:]]*pid = / {print $3; exit}'; }

cmd_enable() {
  step "enable: G0-EXT-ACTIVATE"
  if [ "$IS_MAC" = 0 ]; then record_blocked "$LINUX_REASON" G0-EXT-ACTIVATE; return 0; fi
  [ -n "$APP" ] || { record_blocked "DriveApp.app not installed (run install first)" G0-EXT-ACTIVATE; return 0; }
  local started line="" waited=0 limit st reason sp
  started="$(now_utc)"
  open "$APP" || true
  cat >&2 <<EOF
Manual steps (record anything unexpected in the runbook notes):
  1. $APP_NAME is launching (menu bar only). If macOS asks to allow a background
     item / Login Item for $APP_NAME, approve it (System Settings > General >
     Login Items & Extensions > Allow in the Background).
  2. In System Settings > General > Login Items & Extensions, open
     "File System Extensions" (the (i) button) and switch on $APP_NAME ($EXT_ID).
  3. Do not change any other security setting. Never disable SIP.
Opening: $SETTINGS_URL   (G0-VERIFY: exact pane URL)
EOF
  open "$SETTINGS_URL" || say "could not open System Settings; open it manually"
  if [ -t 0 ] && [ "${SPIKE_NONINTERACTIVE:-0}" != 1 ]; then
    printf 'Press Enter once the extension is enabled (or to give up waiting)... ' >&2
    read -r _ || true
    limit=30
  else
    limit="${SPIKE_ENABLE_TIMEOUT:-120}"
  fi
  while [ "$waited" -lt "$limit" ]; do
    line="$(ext_line)"
    case "$line" in +*) break ;; esac
    sleep 2; waited=$((waited + 2))
  done
  pluginkit -m -v -p "$FSKIT_EXTENSION_POINT" 2>&1 | redact >"$WORK/pluginkit.txt" || true
  sp="$(service_print)"
  case "$line" in
    +*) st=pass; reason="" ;;
    "") st=fail; reason="$EXT_ID is not registered with pluginkit ($FSKIT_EXTENSION_POINT)" ;;
    *) st=blocked; reason="extension registered but not enabled (awaiting the user's approval in System Settings)" ;;
  esac
  local dir; dir="$(evidence_dir G0-EXT-ACTIVATE)"; mkdir -p "$dir"
  cp "$WORK/pluginkit.txt" "$dir/pluginkit.txt"
  printf '%s\n' "$sp" | redact >"$dir/launchctl-print.txt"
  write_result G0-EXT-ACTIVATE "$st" "$reason" \
    "{\"extensionId\":$(json_str "$EXT_ID"),\"pluginkitLine\":$(json_str "$(printf '%s' "$line" | redact)"),\"enabled\":$(case "$line" in +*) echo true ;; *) echo false ;; esac),\"waitedSeconds\":$waited,\"serviceLabel\":$(json_str "$SERVICE_LABEL"),\"serviceRegistered\":$([ -n "$sp" ] && echo true || echo false),\"servicePid\":$(json_str_or_null "$(printf '%s\n' "$sp" | awk '/^[[:space:]]*pid = / {print $3; exit}')")}" \
    "$started" "" '["pluginkit.txt","launchctl-print.txt"]'
}

# ------------------------------------------------------------------ mount (G0-MOUNT)

is_mounted() { mount | grep -F " on $MOUNTPOINT (" >/dev/null 2>&1; }
sudo_prefix() { if [ "${SPIKE_MOUNT_SUDO:-0}" = 1 ]; then echo sudo; fi; }

check_mountpoint_safe() {
  case "$MOUNTPOINT" in "$SPIKE_HOME"/*) ;; *) die "SPIKE_MOUNTPOINT must be under $SPIKE_HOME" ;; esac
}

cmd_mount() {
  step "mount: G0-MOUNT"
  if [ "$IS_MAC" = 0 ]; then record_blocked "$LINUX_REASON" G0-MOUNT; return 0; fi
  check_mountpoint_safe
  local started rc=0 out resource="$SPIKE_RESOURCE" dev="" waited=0 mline st reason sp
  started="$(now_utc)"
  if is_mounted; then record_blocked "already mounted at $MOUNTPOINT; run unmount first" G0-MOUNT; return 0; fi
  mkdir -p "$MOUNTPOINT"
  if [ "$resource" = ramdisk ]; then
    dev="$(hdiutil attach -nomount ram://2048 | awk '{print $1; exit}')"
    state_set RAMDISK_DEV "$dev"
    resource="${dev#/dev/}"
  fi
  sp="$(sudo_prefix)"
  say "running: ${sp:+$sp }mount -F ${MOUNT_OPTS:+$MOUNT_OPTS }-t $FS_SHORT_NAME $resource $MOUNTPOINT   (G0-VERIFY syntax)"
  # shellcheck disable=SC2086  # MOUNT_OPTS is a word list on purpose
  out="$(${sp:+$sp} mount -F $MOUNT_OPTS -t "$FS_SHORT_NAME" "$resource" "$MOUNTPOINT" 2>&1)" || rc=$?
  while ! is_mounted && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
  mline="$(mount | grep -F " on $MOUNTPOINT (" || true)"
  if [ "$rc" = 0 ] && [ -n "$mline" ]; then st=pass; reason=""
  else st=fail; reason="mount exit $rc; mounted=$([ -n "$mline" ] && echo yes || echo no)"; fi
  case "$mline" in *read-only*|*rdonly*) ;; *) if [ "$st" = pass ]; then reason="mounted without a read-only flag (writes must still fail; see G0-READONLY)"; fi ;; esac
  write_result G0-MOUNT "$st" "$reason" \
    "{\"resource\":$(json_str "$resource"),\"ramDisk\":$(json_str_or_null "$dev"),\"mountExit\":$rc,\"mountOutput\":$(json_str "$(printf '%s' "$out" | redact)"),\"mountTableLine\":$(json_str "$(printf '%s' "$mline" | redact)"),\"secondsToAppear\":$waited,\"sudo\":$([ -n "$sp" ] && echo true || echo false)}" \
    "$started" "$rc"
}

# ------------------------------------------------------------------ unmount (G0-UNMOUNT)

cmd_unmount() {
  step "unmount: G0-UNMOUNT"
  if [ "$IS_MAC" = 0 ]; then record_blocked "$LINUX_REASON" G0-UNMOUNT; return 0; fi
  check_mountpoint_safe
  local started rc=0 out drc=null dout="" waited=0 st reason dev sp gone
  started="$(now_utc)"
  if ! is_mounted; then record_blocked "nothing mounted at $MOUNTPOINT" G0-UNMOUNT; return 0; fi
  sp="$(sudo_prefix)"
  out="$(with_timeout 15 ${sp:+$sp} umount "$MOUNTPOINT" 2>&1)" || rc=$?
  if is_mounted; then
    drc=0; dout="$(with_timeout 15 diskutil unmount "$MOUNTPOINT" 2>&1)" || drc=$?
  fi
  while is_mounted && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
  if is_mounted; then gone=false; else gone=true; rmdir "$MOUNTPOINT" 2>/dev/null || true; fi
  dev="$(state_get RAMDISK_DEV)"
  if [ -n "$dev" ] && [ "$gone" = true ]; then hdiutil detach -quiet "$dev" 2>/dev/null || true; state_set RAMDISK_DEV ""; fi
  if [ "$gone" = true ] && [ ! -e "$MOUNTPOINT" ]; then st=pass; reason=""
    if [ "$rc" != 0 ]; then reason="umount failed (exit $rc); diskutil unmount fallback worked"; fi
  else st=fail; reason="still mounted or mountpoint left behind"; fi
  write_result G0-UNMOUNT "$st" "$reason" \
    "{\"umountExit\":$rc,\"umountOutput\":$(json_str "$(printf '%s' "$out" | redact)"),\"diskutilExit\":$drc,\"diskutilOutput\":$(json_str "$(printf '%s' "$dout" | redact)"),\"unmounted\":$gone,\"mountpointRemoved\":$([ ! -e "$MOUNTPOINT" ] && echo true || echo false),\"extraSecondsWaited\":$waited}" \
    "$started" "$rc"
}

# ------------------------------------------------------------------ test

test_list() {
  local started dir rc=0
  started="$(now_utc)"; dir="$(evidence_dir G0-LIST)"; mkdir -p "$dir"
  # shellcheck disable=SC2012  # the human-readable listing itself is the evidence
  ls -laR "$MOUNTPOINT" 2>&1 | redact >"$dir/ls-laR.txt" || rc=$?
  py list "$MOUNTPOINT" "$MANIFEST_CACHE" "$WORK/list.obs.json" || true
  obs_result G0-LIST "$WORK/list.obs.json" "$started" "$rc" '["ls-laR.txt"]'
}

test_read_range() {
  local started dir rc=0 st rs fc hx
  started="$(now_utc)"; dir="$(evidence_dir G0-READ-RANGE)"; mkdir -p "$dir"
  "$FIXTURE_CHECK_BIN" verify "$MOUNTPOINT" --random-reads "$RANDOM_READS" --seed "$SEED" >"$dir/fixture-check-verify.json" 2>"$WORK/fixture-check-verify.err" || rc=$?
  py hashes "$MOUNTPOINT" "$MANIFEST_CACHE" "$REF_DIR" "$WORK/hashes.obs.json" "$SEED" 200 || true
  fc="$(py get "$dir/fixture-check-verify.json" pass 2>/dev/null || echo false)"
  hx="$(py get "$WORK/hashes.obs.json" status 2>/dev/null || echo fail)"
  if [ "$rc" = 0 ] && [ "$fc" = true ] && [ "$hx" = pass ]; then st=pass; rs=""
  else st=fail; rs="fixture-check exit=$rc pass=$fc; helper cross-check=$hx"; fi
  write_result G0-READ-RANGE "$st" "$rs" \
    "{\"fixtureCheck\":{\"exitCode\":$rc,\"pass\":${fc:-false},\"report\":\"fixture-check-verify.json\"},\"crossCheck\":$(py getjson "$WORK/hashes.obs.json" observed 2>/dev/null || echo null)}" \
    "$started" "$rc" '["fixture-check-verify.json"]'
}

test_eof() {
  local started n
  started="$(now_utc)"
  py eof "$MOUNTPOINT" "$MANIFEST_CACHE" "$WORK/eof.obs.json" || true
  n="$(dd if="$MOUNTPOINT/seg-plus-1.bin" bs=1 skip=4194304 count=10 2>/dev/null | wc -c | tr -d ' ')"
  local n2
  n2="$(dd if="$MOUNTPOINT/seg-plus-1.bin" bs=1 skip=4194305 count=10 2>/dev/null | wc -c | tr -d ' ')"
  local st rs ob
  st="$(py get "$WORK/eof.obs.json" status)"; rs="$(py get "$WORK/eof.obs.json" reason)"
  ob="$(py getjson "$WORK/eof.obs.json" observed)"
  if [ "$n" != 1 ] || [ "$n2" != 0 ]; then st=fail; rs="${rs:+$rs; }dd: last byte copied $n (want 1), past EOF copied $n2 (want 0)"; fi
  write_result G0-EOF "$st" "$rs" "{\"python\":$ob,\"dd\":{\"lastByteCopied\":$n,\"pastEOFCopied\":$n2}}" "$started"
}

test_readonly() {
  local started tsv="$WORK/readonly-shell.tsv" rc err name
  started="$(now_utc)"
  check_mountpoint_safe
  is_mounted || { record_blocked "volume not mounted" G0-READONLY; return 0; }
  : >"$tsv"
  for name in touch-new mkdir rm mv touch-existing append; do
    rc=0
    case "$name" in
      touch-new) err="$(touch "$MOUNTPOINT/ro-probe-touch.txt" 2>&1)" || rc=$? ;;
      mkdir) err="$(mkdir "$MOUNTPOINT/ro-probe-mkdir" 2>&1)" || rc=$? ;;
      rm) err="$(rm -f "$MOUNTPOINT/one.bin" 2>&1)" || rc=$? ;;
      mv) err="$(mv "$MOUNTPOINT/one.bin" "$MOUNTPOINT/one-renamed.bin" 2>&1)" || rc=$? ;;
      touch-existing) err="$(touch "$MOUNTPOINT/one.bin" 2>&1)" || rc=$? ;;
      append) err="$(sh -c 'printf x >> "$1"' sh "$MOUNTPOINT/one.bin" 2>&1)" || rc=$? ;;
    esac
    err="$(printf '%s' "$err" | tr '\t\n' '  ' | redact)"
    printf '%s\t%s\t%s\n' "$name" "$rc" "$err" >>"$tsv"
  done
  py readonly "$MOUNTPOINT" "$tsv" "$MANIFEST_CACHE" "$WORK/readonly.obs.json" || true
  obs_result G0-READONLY "$WORK/readonly.obs.json" "$started"
}

test_cancel() {
  local started f="$MOUNTPOINT/seg-plus-1.bin" loop slow kids="" prog="$WORK/slowread.progress" bytes=0 waited=0 rc=0 gone=true p st rs ob
  started="$(now_utc)"
  : >"$prog"
  bash -c 'while :; do cat "$1" >/dev/null; done' _ "$f" &
  loop=$!
  python3 -I "$HELPER" slowread "$f" "$prog" &
  slow=$!
  BG_PIDS="$BG_PIDS $loop $slow"
  while [ "$waited" -lt 50 ]; do
    bytes="$(cat "$prog" 2>/dev/null || true)"; bytes="${bytes:-0}"
    if [ "$bytes" -gt 0 ] && [ "$waited" -ge 10 ]; then break; fi
    sleep 0.1; waited=$((waited + 1))
  done
  kill -STOP "$loop" 2>/dev/null || true
  kids="$(pgrep -P "$loop" 2>/dev/null | tr '\n' ' ' || true)"
  # shellcheck disable=SC2086
  kill -KILL $kids "$slow" 2>/dev/null || true
  kill -KILL "$loop" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 50 ]; do
    gone=true
    for p in $loop $slow $kids; do if ps -p "$p" >/dev/null 2>&1 && [ "$(ps -o stat= -p "$p" | tr -d ' ')" != Z ]; then gone=false; fi; done
    [ "$gone" = true ] && break
    sleep 0.1; waited=$((waited + 1))
  done
  rm -f "$WORK/probe.obs.json"
  with_timeout 5 python3 -I "$HELPER" probe "$MOUNTPOINT" "$REF_DIR" "$WORK/probe.obs.json" || rc=$?
  if [ "$rc" = 0 ] && [ -s "$WORK/probe.obs.json" ]; then ob="$(py getjson "$WORK/probe.obs.json" observed)"; st="$(py get "$WORK/probe.obs.json" status)"
  else ob=null; st=fail; fi
  rs=""
  if [ "$bytes" = 0 ]; then st=fail; rs="reader never started reading"; fi
  if [ "$gone" != true ]; then st=fail; rs="${rs:+$rs; }killed reader did not exit within 5 s (stuck in read?)"; fi
  if [ "$rc" = 124 ]; then st=fail; rs="${rs:+$rs; }volume did not answer the probe within 5 s"; fi
  if [ "$st" = fail ] && [ -z "$rs" ]; then rs="probe after cancellation failed"; fi
  write_result G0-CANCEL "$st" "$rs" \
    "{\"bytesReadBeforeKill\":$bytes,\"killedReadersExited\":$gone,\"exitWaitDeciseconds\":$waited,\"probeExit\":$rc,\"probe\":$ob}" "$started" "$rc"
}

write_spoof_source() {
  cat >"$WORK/spoof-client.swift" <<'SWIFT'
// Spoofed client for G0-IPC-AUTH (generated by scripts/b01-spike.sh).
// Connects to the StorageService Mach service without DriveApp's signature and sends a
// well-formed IPCRequest.status envelope. Expected: no reply; connection invalidated.
// The selector send:withReply: mirrors Shared/StorageServiceXPC.swift (StorageServiceXPC), and
// the service replies to every message it receives, even malformed ones, so an ACCEPTED peer
// always gets a reply. Keep this in sync if the Shared protocol changes.
import Foundation

@objc protocol SpoofStorageProtocol {
    func send(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (String, String)?
    let done = DispatchSemaphore(value: 0)
    func set(_ outcome: String, _ detail: String) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = (outcome, detail)
        done.signal()
    }
    func get() -> (String, String)? { lock.lock(); defer { lock.unlock() }; return value }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("{\"outcome\":\"usage\"}"); exit(64) }
let machName = args[1]
let envelope: [String: Any] = ["v": 1, "m": ["status": [String: Any]()]]
let payload = (try? PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)) ?? Data()
let outcome = Outcome()
let connection = NSXPCConnection(machServiceName: machName, options: [])
connection.remoteObjectInterface = NSXPCInterface(with: SpoofStorageProtocol.self)
connection.invalidationHandler = { outcome.set("rejected", "connection invalidated") }
connection.interruptionHandler = { outcome.set("rejected", "connection interrupted") }
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    let e = error as NSError
    outcome.set("rejected", "\(e.domain) code \(e.code)")
}
if let p = proxy as? SpoofStorageProtocol {
    p.send(payload) { reply in outcome.set("accepted", "reply of \(reply.count) bytes") }
} else {
    outcome.set("error", "proxy does not conform")
}
let waited = outcome.done.wait(timeout: .now() + .seconds(10))
let result = outcome.get() ?? ("timeout", "no reply and no invalidation within 10 s")
connection.invalidate()
let obj: [String: Any] = ["outcome": result.0, "detail": result.1, "machService": machName,
                          "pid": Int(ProcessInfo.processInfo.processIdentifier), "timedOut": waited == .timedOut]
let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
print(String(decoding: data, as: UTF8.self))
exit(result.0 == "accepted" ? 1 : 0)
SWIFT
}

spoof_json() { # spoof_json VARIANT CMD... -> one JSON object
  local variant="$1" rc=0 out
  shift
  out="$(with_timeout 120 "$@" 2>"$WORK/spoof-$variant.err" | tail -n 1)" || rc=$?
  case "$out" in "{"*) ;; *) out="{\"outcome\":\"error\",\"detail\":$(json_str "$(tail -n 3 "$WORK/spoof-$variant.err" 2>/dev/null | redact)")}" ;; esac
  printf '{"variant":%s,"exitCode":%s,"result":%s}' "$(json_str "$variant")" "$rc" "$out"
}

test_ipc_auth() {
  local started sp registered=false a b c="null" outcomes genuine=false st rs t0 p spoof_pids accepted_lines debug_noauth genuine_accepts
  started="$(now_utc)"
  if [ -z "$MACH_SERVICE" ]; then record_blocked "DriveAppStorageMachService missing from Info.plist" G0-IPC-AUTH; return 0; fi
  sp="$(service_print)"
  if printf '%s\n' "$sp" | grep -F "$MACH_SERVICE" >/dev/null 2>&1; then registered=true; fi
  if ! have xcrun || ! xcrun --find swift >/dev/null 2>&1; then record_blocked "swift unavailable for the spoof client" G0-IPC-AUTH; return 0; fi
  write_spoof_source
  t0="$(date '+%Y-%m-%d %H:%M:%S')"
  a="$(spoof_json swift-interpreter xcrun swift "$WORK/spoof-client.swift" "$MACH_SERVICE")"
  b="null"
  if xcrun swiftc -O -o "$WORK/spoof-client" "$WORK/spoof-client.swift" >"$WORK/spoof-build.log" 2>&1 \
     && codesign -s - -f "$WORK/spoof-client" >/dev/null 2>&1; then
    b="$(spoof_json adhoc-signed-binary "$WORK/spoof-client" "$MACH_SERVICE")"
  fi
  if [ -n "${SPIKE_SPOOF_APP_ARGS:-}" ]; then
    # Variant C: an ad-hoc re-signed COPY of the real app (the installed app is untouched).
    rm -rf "$WORK/spoof-app"; mkdir -p "$WORK/spoof-app"
    ditto "$APP" "$WORK/spoof-app/$APP_NAME.app"
    codesign --force --deep -s - "$WORK/spoof-app/$APP_NAME.app" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    c="$(spoof_json adhoc-app-copy "$WORK/spoof-app/$APP_NAME.app/Contents/MacOS/$APP_NAME" $SPIKE_SPOOF_APP_ARGS)"
  fi
  # Positive control: the genuine extension path still works.
  if [ -s "$WORK/hashes.obs.json" ] && [ "$(py get "$WORK/hashes.obs.json" status)" = pass ]; then genuine=true; fi
  sleep 2
  # Evidence from the service log (StorageService/ServiceDelegate.swift wording):
  # "Accepted XPC client pid N" for a spoof pid = accepted; "DEBUG BUILD WITHOUT TEAM ID" = no auth.
  log show --style compact --info --start "$t0" --predicate "$LOG_PREDICATE" 2>/dev/null | redact >"$WORK/ipc-auth-service.log" || true
  spoof_pids="$(printf '%s %s %s' "$a" "$b" "$c" | grep -o '"pid":[0-9]*' | cut -d: -f2 | tr '\n' ' ')"
  accepted_lines=0
  for p in $spoof_pids; do
    if grep -E "Accepted XPC client pid $p([^0-9]|$)" "$WORK/ipc-auth-service.log" >/dev/null 2>&1; then accepted_lines=$((accepted_lines + 1)); fi
  done
  debug_noauth="$(grep -c 'WITHOUT code-signing checks' "$WORK/ipc-auth-service.log" || true)"
  genuine_accepts="$(grep -c 'Accepted XPC client pid' "$WORK/ipc-auth-service.log" || true)"
  outcomes="$(printf '%s %s %s' "$a" "$b" "$c" | grep -o '"outcome":"[a-z]*"' | cut -d'"' -f4 | tr '\n' ' ')"
  st=pass; rs=""
  case " $outcomes " in
    *" accepted "*) st=fail; rs="a spoofed client got a reply (service accepted an unauthorised peer)" ;;
    *" timeout "*|*" error "*) st=blocked; rs="inconclusive spoof outcome ($outcomes); see spoof-*.err" ;;
  esac
  if [ "$accepted_lines" -gt 0 ]; then st=fail; rs="${rs:+$rs; }service logged 'Accepted XPC client' for a spoof pid"; fi
  if [ "${debug_noauth:-0}" -gt 0 ]; then st=fail; rs="${rs:+$rs; }service runs WITHOUT code-signing checks (ad-hoc/no-team build)"; fi
  if [ "$st" = pass ] && [ "$b" = null ]; then st=blocked; rs="ad-hoc-signed spoof binary could not be built (see spoof-build.log)"; fi
  if [ "$st" = pass ] && [ "$registered" != true ]; then st=blocked; rs="Mach service $MACH_SERVICE not visible in launchctl print; a rejection would be indistinguishable from lookup failure"; fi
  if [ "$st" = pass ] && [ "$genuine" != true ]; then st=blocked; rs="genuine extension path not proven in this run (G0-READ-RANGE cross-check)"; fi
  local dir; dir="$(evidence_dir G0-IPC-AUTH)"; mkdir -p "$dir"
  cp "$WORK/spoof-client.swift" "$dir/spoof-client.swift"
  cp "$WORK/ipc-auth-service.log" "$dir/service-log-during-spoof.txt"
  write_result G0-IPC-AUTH "$st" "$rs" \
    "{\"machService\":$(json_str "$MACH_SERVICE"),\"serviceRegistered\":$registered,\"genuinePathOk\":$genuine,\"spoofs\":[$a,$b,$c],\"serviceAcceptedSpoofPids\":$accepted_lines,\"serviceNoAuthWarnings\":${debug_noauth:-0},\"serviceAcceptLinesInWindow\":${genuine_accepts:-0}}" \
    "$started" "" '["spoof-client.swift","service-log-during-spoof.txt"]'
}

ev() { printf '{"ev":"%s","t":%s%s}\n' "$1" "$(py now)" "${2:-}" >>"$WORK/restart-events.jsonl"; }

test_service_restart() {
  local started log="$WORK/restart-reads.jsonl" reader pid0 pid1="" krc=0 method=kickstart waited=0 dir
  started="$(now_utc)"
  if [ -z "$SERVICE_LABEL" ]; then record_blocked "LaunchAgent label unknown" G0-SERVICE-RESTART; return 0; fi
  : >"$log"; : >"$WORK/restart-events.jsonl"
  head -c 1 "$MOUNTPOINT/one.bin" >/dev/null 2>&1 || true
  pid0="$(service_pid)"
  if [ -z "$pid0" ]; then record_blocked "service $SERVICE_LABEL not running (launchctl print shows no pid)" G0-SERVICE-RESTART; return 0; fi
  rm -f "$WORK/readloop.stop"
  python3 -I "$HELPER" readloop "$MOUNTPOINT" "$REF_DIR" "$MANIFEST_CACHE" "$log" "$RESTART_SECONDS" "$SEED" "$WORK/readloop.stop" &
  reader=$!
  BG_PIDS="$BG_PIDS $reader"
  sleep 5
  say "  kickstart -k gui/$(id -u)/$SERVICE_LABEL (pid $pid0)"
  ev restart ",\"method\":\"kickstart\",\"pidBefore\":\"$pid0\""
  launchctl kickstart -k "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 || krc=$?
  if [ "$krc" != 0 ]; then method=kill9; kill -KILL "$pid0" 2>/dev/null || true; fi
  while [ "$waited" -lt 30 ]; do
    pid1="$(service_pid)"
    if [ -n "$pid1" ] && [ "$pid1" != "$pid0" ]; then break; fi
    head -c 1 "$MOUNTPOINT/one.bin" >/dev/null 2>&1 || true
    sleep 1; waited=$((waited + 1))
  done
  ev restarted ",\"pid\":\"${pid1}\",\"method\":\"$method\",\"kickstartExit\":$krc"
  if [ "$HANG_TEST" = 1 ] && [ -n "$pid1" ]; then
    sleep 10
    say "  SIGSTOP service pid $pid1 for 40 s (hung-service phase)"
    STOPPED_PID="$pid1"; ev stop ",\"pid\":\"$pid1\""
    kill -STOP "$pid1" 2>/dev/null || true
    sleep 40
    kill -CONT "$pid1" 2>/dev/null || true
    ev cont ",\"pid\":\"$pid1\""; STOPPED_PID=""
  fi
  # Observe recovery for 20 s, then stop the loop; a read stuck > 40 s more counts as a hang
  # (analyze-restart reports it as an unfinished read).
  sleep 20
  touch "$WORK/readloop.stop"
  waited=0
  while kill -0 "$reader" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 1; waited=$((waited + 1)); done
  kill -KILL "$reader" 2>/dev/null || true
  dir="$(evidence_dir G0-SERVICE-RESTART)"; mkdir -p "$dir"
  cp "$log" "$dir/read-loop.jsonl"; cp "$WORK/restart-events.jsonl" "$dir/events.jsonl"
  py analyze-restart "$log" "$WORK/restart-events.jsonl" "$WORK/restart.obs.json" || true
  obs_result G0-SERVICE-RESTART "$WORK/restart.obs.json" "$started" "$krc" '["read-loop.jsonl","events.jsonl"]'
}

cmd_test() {
  step "test: G0-LIST G0-READ-RANGE G0-EOF G0-READONLY G0-CANCEL G0-IPC-AUTH G0-SERVICE-RESTART G0-UNMOUNT"
  local tests="G0-LIST G0-READ-RANGE G0-EOF G0-READONLY G0-CANCEL G0-IPC-AUTH G0-SERVICE-RESTART"
  if [ "$IS_MAC" = 0 ]; then
    # shellcheck disable=SC2086
    record_blocked "$LINUX_REASON" $tests G0-UNMOUNT; return 0
  fi
  check_mountpoint_safe
  if ! is_mounted; then
    # shellcheck disable=SC2086
    record_blocked "volume not mounted at ~/DriveAppSpike/mnt (see G0-MOUNT)" $tests G0-UNMOUNT; return 0
  fi
  if ! have python3 || ! prepare_fixtures; then
    # shellcheck disable=SC2086
    record_blocked "fixture-check or python3 unavailable (see G0-ENV)" $tests
    cmd_unmount; return 0
  fi
  test_list
  test_read_range
  test_eof
  test_readonly
  test_cancel
  test_ipc_auth
  test_service_restart
  cmd_unmount
}

# ------------------------------------------------------------------ collect

cmd_collect() {
  step "collect: logs, manifests, summary"
  local osdir t r win s e dir
  osdir="$EVIDENCE_ROOT/$BUILD_ID/$OS_ID"
  [ -d "$osdir" ] || die "no evidence at $osdir"
  for t in $ALL_TESTS; do
    r="$osdir/$t/result.json"
    [ -f "$r" ] || continue
    dir="$osdir/$t"
    if [ "$IS_MAC" = 1 ] && have python3 && [ "$(py get "$r" status)" != blocked ]; then
      mkdir -p "$dir/logs"
      win="$(py window "$r" 5)"; s="${win%%|*}"; e="${win##*|}"
      log show --style compact --info --debug --start "$s" --end "$e" --predicate "$LOG_PREDICATE" 2>&1 | redact >"$dir/logs/driveapp.log.txt" || true
      log show --style compact --info --start "$s" --end "$e" --predicate "$FSKIT_LOG_PREDICATE" 2>&1 | redact >"$dir/logs/fskit.log.txt" || true
      py add-artifacts "$r" logs/driveapp.log.txt logs/fskit.log.txt
    fi
  done
  if [ "$IS_MAC" = 1 ] && have python3; then
    log show --style compact --info --debug --predicate "$LOG_PREDICATE" --last "${SPIKE_LOG_LAST:-15m}" 2>&1 | redact >"$osdir/driveapp-last-15m.log.txt" || true
  fi
  if have python3; then
    py summary "$osdir" "$osdir/g0-summary.json" >&2
  fi
}

# ------------------------------------------------------------------ all

cmd_all() {
  local src="${1:-${SPIKE_APP:-}}"
  if [ "$IS_MAC" = 1 ]; then
    [ -n "$src" ] || die "usage: b01-spike.sh all <DriveApp.app|DriveApp.dmg>"
    stage_source "$src"
    set_app "$SOURCE_APP"
  fi
  init_build
  cmd_preflight
  cmd_install "$SOURCE_APP"
  cmd_enable
  cmd_mount
  cmd_test
  cmd_collect
}

# ------------------------------------------------------------------ main

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  init_os
  write_helper
  case "$cmd" in
    preflight)
      if [ -n "${1:-}" ] && [ "$IS_MAC" = 1 ]; then stage_source "$1"; set_app "$SOURCE_APP"; fi
      init_build; cmd_preflight ;;
    install) init_build; cmd_install "$@" ;;
    enable) init_build; cmd_enable ;;
    mount) init_build; cmd_mount ;;
    test) init_build; cmd_test ;;
    unmount) init_build; cmd_unmount ;;
    collect) init_build; cmd_collect ;;
    all) cmd_all "$@" ;;
    -h|--help|help|"") sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; [ -n "$cmd" ] || exit 64; exit 0 ;;
    *) die "unknown command '$cmd' (try --help)" ;;
  esac
  say ""
  say "Evidence: ${EVIDENCE_ROOT#"$REPO_ROOT"/}/$BUILD_ID/$OS_ID/"
  exit "$OVERALL_RC"
}

main "$@"
