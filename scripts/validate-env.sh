#!/usr/bin/env bash
# validate-env.sh - "Validate the current machine and SDK first" (AI-HANDOFF, B01/G0).
#
# Read-only. Checks the host for the B01 feasibility spike and prints a JSON
# report. It never changes system settings, never triggers a developer-tools
# install dialog and never prints certificate details (only counts and team IDs).
#
# Usage: scripts/validate-env.sh [--role all|build|test] [--out FILE] [--quiet]
#   --role all    (default) every check is required; macOS >= 26.0.
#   --role build  machine that builds and signs (macOS >= 15.6 is enough, e.g. the
#                 founder's macOS 15 Mac with Xcode 26); SIP is informational.
#   --role test   machine that installs and runs the signed spike (macOS >= 26.0,
#                 SIP enabled, Swift + python3 for fixture-check and probes);
#                 Xcode, SDK, xcodegen and identities are informational.
#   --out FILE    write the JSON report to FILE instead of stdout.
#   --quiet       no human-readable summary on stderr.
#
# Exit codes: 0 all required checks pass; 1 a required check failed;
#             2 nothing failed but a required check is blocked (e.g. on Linux).
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

ROLE="all"
OUT=""
QUIET=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

need_value() { # need_value FLAG ARGC: `shift 2` past the end would exit 1 silently under set -e
  if [ "$2" -lt 2 ]; then echo "validate-env: $1 needs a value" >&2; usage >&2; exit 64; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --role) need_value "$1" $#; ROLE="$2"; shift 2 ;;
    --role=*) ROLE="${1#*=}"; shift ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "validate-env: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
case "$ROLE" in all|build|test) ;; *) echo "validate-env: --role must be all, build or test" >&2; exit 64 ;; esac

MIN_MACOS_RUN="26.0"
MIN_MACOS_BUILD="15.6"
MIN_XCODE="26"
MIN_SDK="26.0"
MIN_FREE_GIB=10

# ---------- helpers ----------

json_str() {
  # Prints a JSON string literal for $1 (null when $1 is the literal __NULL__).
  local s="${1-}"
  if [ "$s" = "__NULL__" ]; then printf 'null'; return; fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ver_ge A B: true when dotted version A >= B (numeric components, max 4).
ver_ge() {
  local a="$1" b="$2" i x y
  local -a av bv
  IFS=. read -r -a av <<<"$a"
  IFS=. read -r -a bv <<<"$b"
  for i in 0 1 2 3; do
    x="${av[$i]:-0}"; y="${bv[$i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then return 0; fi
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then return 1; fi
  done
  return 0
}

CHECKS_JSON=""
N_PASS=0; N_FAIL=0; N_BLOCKED=0
REQ_FAIL=0; REQ_BLOCKED=0
SUMMARY_LINES=""

# add_check ID TITLE REQUIRED(true|false) STATUS EXPECTED OBSERVED REASON
add_check() {
  local id="$1" title="$2" req="$3" status="$4" expected="$5" observed="$6" reason="$7" entry
  entry="{\"id\":$(json_str "$id"),\"title\":$(json_str "$title"),\"required\":$req,\"status\":$(json_str "$status"),\"expected\":$(json_str "$expected"),\"observed\":$(json_str "$observed"),\"reason\":$(json_str "$reason")}"
  if [ -n "$CHECKS_JSON" ]; then CHECKS_JSON="$CHECKS_JSON,$entry"; else CHECKS_JSON="$entry"; fi
  case "$status" in
    pass) N_PASS=$((N_PASS + 1)) ;;
    fail) N_FAIL=$((N_FAIL + 1)); if [ "$req" = true ]; then REQ_FAIL=$((REQ_FAIL + 1)); fi ;;
    blocked) N_BLOCKED=$((N_BLOCKED + 1)); if [ "$req" = true ]; then REQ_BLOCKED=$((REQ_BLOCKED + 1)); fi ;;
  esac
  local tag="required" shown="$observed"
  [ "$req" = true ] || tag="info"
  [ "$shown" != "__NULL__" ] || shown="-"
  SUMMARY_LINES="${SUMMARY_LINES}$(printf '  %-8s %-9s %-20s %s' "$status" "$tag" "$id" "$shown")"$'\n'
}

# required ID -> true|false for the current role
required() {
  local id="$1"
  case "$ROLE" in
    all) echo true ;;
    build) case "$id" in sip|python3) echo false ;; *) echo true ;; esac ;;
    test) case "$id" in xcode|macos_sdk|fskit_sdk|xcodegen|signing_identities) echo false ;; *) echo true ;; esac ;;
  esac
}

# ---------- host facts ----------

KERNEL="$(uname -s)"
MACHINE="$(uname -m)"
PLATFORM_ID=""
MODEL="__NULL__"
IS_VM="__NULL__"
IS_MAC=0
DEVTOOLS=0
DEVDIR=""

if [ "$KERNEL" = "Darwin" ] && command -v sw_vers >/dev/null 2>&1; then
  IS_MAC=1
  PV="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  BV="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  PLATFORM_ID="macos-$PV-$BV"
  MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
  case "$MODEL" in VirtualMac*) IS_VM="true" ;; *) IS_VM="false" ;; esac
  # Guard: the /usr/bin shims (swift, python3, xcrun) open an install dialog when
  # no developer directory exists. Only call them when xcode-select resolves one.
  if DEVDIR="$(xcode-select -p 2>/dev/null)" && [ -d "$DEVDIR" ]; then DEVTOOLS=1; fi
else
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    PLATFORM_ID="linux-$(. /etc/os-release && printf '%s-%s' "${ID:-unknown}" "${VERSION_ID:-unknown}")"
  else
    PLATFORM_ID="$(printf '%s' "$KERNEL" | tr '[:upper:]' '[:lower:]')-unknown"
  fi
fi

NOT_MAC_REASON="Not macOS ($KERNEL $(uname -r)); this check needs macOS $MIN_MACOS_RUN+ with Xcode $MIN_XCODE (Linux cloud session: no macOS/Xcode; FSKit/XPC/codesign unavailable)"
NO_DEVTOOLS_REASON="No developer directory (xcode-select -p failed); install Xcode $MIN_XCODE yourself - this script never triggers an install"

# ---------- checks ----------

# os
if [ "$IS_MAC" = 1 ]; then
  if [ "$ROLE" = build ]; then min="$MIN_MACOS_BUILD"; else min="$MIN_MACOS_RUN"; fi
  if ver_ge "$PV" "$min"; then
    add_check os "macOS version" "$(required os)" pass "macOS >= $min" "macOS $PV ($BV)" ""
  else
    add_check os "macOS version" "$(required os)" fail "macOS >= $min" "macOS $PV ($BV)" "FSKit spike needs macOS $MIN_MACOS_RUN+ to run; do not upgrade this machine without the owner's decision (docs/10 §4)"
  fi
else
  add_check os "macOS version" "$(required os)" blocked "macOS >= $MIN_MACOS_RUN" "$KERNEL $(uname -r) ($PLATFORM_ID)" "$NOT_MAC_REASON"
fi

# arch
if [ "$IS_MAC" = 1 ]; then
  hw_arm="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  obs="uname -m=$MACHINE hw.optional.arm64=$hw_arm proc_translated=$translated"
  if [ "$hw_arm" = 1 ] && [ "$translated" != 1 ]; then
    add_check arch "Apple Silicon (arm64)" "$(required arch)" pass "arm64, not under Rosetta" "$obs" ""
  elif [ "$hw_arm" = 1 ]; then
    add_check arch "Apple Silicon (arm64)" "$(required arch)" fail "arm64, not under Rosetta" "$obs" "Shell runs under Rosetta; open a native arm64 terminal"
  else
    add_check arch "Apple Silicon (arm64)" "$(required arch)" fail "arm64, not under Rosetta" "$obs" "R1 is Apple Silicon only (ADR08)"
  fi
else
  add_check arch "Apple Silicon (arm64)" "$(required arch)" blocked "arm64 Mac" "$MACHINE" "$NOT_MAC_REASON"
fi

# xcode
if [ "$IS_MAC" = 1 ] && [ "$DEVTOOLS" = 1 ]; then
  if xv="$(xcodebuild -version 2>/dev/null)"; then
    xv1="$(printf '%s\n' "$xv" | sed -n '1p')"; xv2="$(printf '%s\n' "$xv" | sed -n '2p')"
    xnum="${xv1#Xcode }"
    if ver_ge "$xnum" "$MIN_XCODE"; then
      add_check xcode "Xcode version" "$(required xcode)" pass "Xcode >= $MIN_XCODE" "$xv1 ($xv2) at $DEVDIR" ""
    else
      add_check xcode "Xcode version" "$(required xcode)" fail "Xcode >= $MIN_XCODE" "$xv1 ($xv2) at $DEVDIR" "Select Xcode $MIN_XCODE with xcode-select (owner's action)"
    fi
  else
    add_check xcode "Xcode version" "$(required xcode)" fail "Xcode >= $MIN_XCODE" "xcodebuild -version failed (developer dir $DEVDIR)" "Only Command Line Tools selected, or Xcode's license/first-launch setup is not done; full Xcode $MIN_XCODE needed to build (owner's action)"
  fi
elif [ "$IS_MAC" = 1 ]; then
  add_check xcode "Xcode version" "$(required xcode)" fail "Xcode >= $MIN_XCODE" "no developer directory" "$NO_DEVTOOLS_REASON"
else
  add_check xcode "Xcode version" "$(required xcode)" blocked "Xcode >= $MIN_XCODE" "__NULL__" "$NOT_MAC_REASON"
fi

# macOS SDK + FSKit framework
if [ "$IS_MAC" = 1 ] && [ "$DEVTOOLS" = 1 ]; then
  sdkv="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  sdkp="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [ -n "$sdkv" ] && ver_ge "$sdkv" "$MIN_SDK"; then
    add_check macos_sdk "macOS SDK version" "$(required macos_sdk)" pass "SDK >= $MIN_SDK" "$sdkv" ""
  else
    add_check macos_sdk "macOS SDK version" "$(required macos_sdk)" fail "SDK >= $MIN_SDK" "${sdkv:-none}" "The FSKit spike targets the macOS $MIN_SDK SDK"
  fi
  fw="$sdkp/System/Library/Frameworks/FSKit.framework"
  if [ -n "$sdkp" ] && [ -d "$fw" ] && { [ -d "$fw/Headers" ] || [ -d "$fw/Modules" ]; }; then
    add_check fskit_sdk "FSKit.framework in SDK" "$(required fskit_sdk)" pass "FSKit.framework with Headers/Modules" "present in SDK $sdkv" ""
  else
    add_check fskit_sdk "FSKit.framework in SDK" "$(required fskit_sdk)" fail "FSKit.framework with Headers/Modules" "missing in SDK ${sdkv:-none}" "SDK has no FSKit; select Xcode $MIN_XCODE"
  fi
elif [ "$IS_MAC" = 1 ]; then
  add_check macos_sdk "macOS SDK version" "$(required macos_sdk)" fail "SDK >= $MIN_SDK" "no developer directory" "$NO_DEVTOOLS_REASON"
  add_check fskit_sdk "FSKit.framework in SDK" "$(required fskit_sdk)" fail "FSKit.framework with Headers/Modules" "no developer directory" "$NO_DEVTOOLS_REASON"
else
  add_check macos_sdk "macOS SDK version" "$(required macos_sdk)" blocked "SDK >= $MIN_SDK" "__NULL__" "$NOT_MAC_REASON"
  add_check fskit_sdk "FSKit.framework in SDK" "$(required fskit_sdk)" blocked "FSKit.framework with Headers/Modules" "__NULL__" "$NOT_MAC_REASON"
fi

# xcodegen
if [ "$IS_MAC" = 1 ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    add_check xcodegen "XcodeGen" "$(required xcodegen)" pass "xcodegen on PATH" "$(xcodegen --version 2>/dev/null | head -n 1 || echo present)" ""
  else
    add_check xcodegen "XcodeGen" "$(required xcodegen)" fail "xcodegen on PATH" "not found" "Install XcodeGen (e.g. brew install xcodegen) - owner's action"
  fi
else
  add_check xcodegen "XcodeGen" "$(required xcodegen)" blocked "xcodegen on PATH (macOS)" "__NULL__" "$NOT_MAC_REASON"
fi

# signing identities (counts and team IDs only)
if [ "$IS_MAC" = 1 ]; then
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  n_devid="$(printf '%s\n' "$ids" | grep -c '"Developer ID Application: ' || true)"
  n_dev="$(printf '%s\n' "$ids" | grep -c '"Apple Development: ' || true)"
  teams="$(printf '%s\n' "$ids" | grep -E '"(Developer ID Application|Apple Development): ' \
    | sed -nE 's/.*\(([A-Z0-9]{10})\)"[[:space:]]*$/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  obs="Developer ID Application=$n_devid Apple Development=$n_dev teams=[${teams}]"
  if [ "$n_devid" -gt 0 ]; then
    add_check signing_identities "Code-signing identities" "$(required signing_identities)" pass ">= 1 Developer ID Application (Apple Development acceptable for local spike)" "$obs" ""
  elif [ "$n_dev" -gt 0 ]; then
    add_check signing_identities "Code-signing identities" "$(required signing_identities)" pass ">= 1 Developer ID Application (Apple Development acceptable for local spike)" "$obs" "Apple Development only: fine for a local spike; a clean test machine needs a Developer ID + notarised DMG"
  else
    add_check signing_identities "Code-signing identities" "$(required signing_identities)" fail ">= 1 Developer ID Application (Apple Development acceptable for local spike)" "$obs" "No valid signing identity; join the Apple Developer Program (docs/07) or use the CI-signed DMG"
  fi
else
  add_check signing_identities "Code-signing identities" "$(required signing_identities)" blocked ">= 1 Developer ID Application (Apple Development acceptable for local spike)" "__NULL__" "$NOT_MAC_REASON"
fi

# SIP (read-only status; never changed)
if [ "$IS_MAC" = 1 ]; then
  sip="$(csrutil status 2>/dev/null | head -n 1 || true)"
  case "$sip" in
    *"status: enabled"*) add_check sip "System Integrity Protection" "$(required sip)" pass "enabled (never disable it for this project)" "$sip" "" ;;
    *"status: disabled"*|*"Custom Configuration"*) add_check sip "System Integrity Protection" "$(required sip)" fail "enabled (never disable it for this project)" "$sip" "G0 evidence is only valid with SIP fully enabled; re-enable it from recoveryOS (owner's action)" ;;
    *) add_check sip "System Integrity Protection" "$(required sip)" blocked "enabled (never disable it for this project)" "${sip:-csrutil gave no output}" "Could not read SIP status" ;;
  esac
else
  add_check sip "System Integrity Protection" "$(required sip)" blocked "enabled" "__NULL__" "$NOT_MAC_REASON"
fi

# free disk (works on any host)
free_kib="$(df -Pk "${HOME:-/}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "$free_kib" ]; then
  free_gib=$((free_kib / 1024 / 1024))
  if [ "$free_gib" -ge "$MIN_FREE_GIB" ]; then
    add_check disk_free "Free disk in \$HOME volume" "$(required disk_free)" pass ">= $MIN_FREE_GIB GiB" "$free_gib GiB" ""
  else
    add_check disk_free "Free disk in \$HOME volume" "$(required disk_free)" fail ">= $MIN_FREE_GIB GiB" "$free_gib GiB" "Free space before building or testing"
  fi
else
  add_check disk_free "Free disk in \$HOME volume" "$(required disk_free)" blocked ">= $MIN_FREE_GIB GiB" "__NULL__" "df gave no output"
fi

# swift
if [ "$IS_MAC" = 1 ] && [ "$DEVTOOLS" = 0 ]; then
  add_check swift "Swift toolchain" "$(required swift)" fail "swift 6.x" "no developer directory" "$NO_DEVTOOLS_REASON"
elif command -v swift >/dev/null 2>&1 && sv="$(swift --version 2>&1 | grep -m 1 -i 'swift version' || true)" && [ -n "$sv" ]; then
  add_check swift "Swift toolchain" "$(required swift)" pass "swift 6.x" "$sv" ""
elif [ "$IS_MAC" = 1 ]; then
  add_check swift "Swift toolchain" "$(required swift)" fail "swift 6.x" "not found" "Swift is needed for fixture-check and the IPC probes"
else
  add_check swift "Swift toolchain" "$(required swift)" blocked "swift 6.x" "not found" "No Swift toolchain on this Linux host (only needed for StorageCore tests)"
fi

# python3 (used by b01-spike.sh for byte checks, JSON and log redaction)
if [ "$IS_MAC" = 1 ] && [ "$DEVTOOLS" = 0 ]; then
  add_check python3 "python3" "$(required python3)" fail "python3 >= 3.9" "no developer directory" "$NO_DEVTOOLS_REASON"
elif command -v python3 >/dev/null 2>&1; then
  add_check python3 "python3" "$(required python3)" pass "python3 >= 3.9" "$(python3 --version 2>&1)" ""
else
  add_check python3 "python3" "$(required python3)" fail "python3 >= 3.9" "not found" "b01-spike.sh needs python3 for byte-level checks"
fi

# ---------- report ----------

if [ "$REQ_FAIL" -gt 0 ]; then OVERALL=fail; RC=1
elif [ "$REQ_BLOCKED" -gt 0 ]; then OVERALL=blocked; RC=2
else OVERALL=pass; RC=0; fi

if [ "$IS_VM" = "__NULL__" ]; then vm_json=null; else vm_json="$IS_VM"; fi

REPORT="{\"schema\":\"driveapp.validate-env.v1\",\"generatedAt\":$(json_str "$(now_utc)"),\"role\":$(json_str "$ROLE"),\"host\":{\"kernel\":$(json_str "$KERNEL"),\"machine\":$(json_str "$MACHINE"),\"platform\":$(json_str "$PLATFORM_ID"),\"model\":$(json_str "$MODEL"),\"virtualMachine\":$vm_json},\"summary\":{\"status\":$(json_str "$OVERALL"),\"pass\":$N_PASS,\"fail\":$N_FAIL,\"blocked\":$N_BLOCKED,\"requiredFail\":$REQ_FAIL,\"requiredBlocked\":$REQ_BLOCKED},\"checks\":[$CHECKS_JSON]}"

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  printf '%s\n' "$REPORT" >"$OUT"
else
  printf '%s\n' "$REPORT"
fi

if [ "$QUIET" = 0 ]; then
  {
    echo "validate-env ($ROLE) on $PLATFORM_ID: $OVERALL (pass=$N_PASS fail=$N_FAIL blocked=$N_BLOCKED)"
    printf '%s' "$SUMMARY_LINES"
  } >&2
fi

exit "$RC"
