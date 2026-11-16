#!/usr/bin/env bash
# scripts/build-dmg.sh: build the macOS app and package it as a DMG.
#
# Used by .github/workflows/build-dmg.yml. It can also run on a Mac by hand.
# Run `scripts/build-dmg.sh --help` for usage. See docs/12-pipeline-usage.md.
#
# Stages (each is a function below):
#   preflight -> select_xcode -> generate_project -> setup_signing -> archive
#   -> export_app -> make_dmg -> notarize -> checksum -> publish_release
#   cleanup runs from an EXIT trap, and again from the workflow (if: always()).
#
# Secrets come only from the environment. The script never prints them and
# never enables `set -x`.
#
# Written for bash 3.2 (macOS /bin/bash) as well as bash 5.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_SPEC="$REPO_ROOT/project.yml"
EXPORT_OPTIONS_TEMPLATE="$SCRIPT_DIR/ExportOptions.plist"

SCHEME="${SCHEME:-DriveApp}"
APP_TARGET="${APP_TARGET:-DriveApp}"
CONFIGURATION="${CONFIGURATION:-Release}"

BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
LOG_DIR="$BUILD_DIR/logs"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DIST_DIR="$BUILD_DIR/dist"

# Signing material (temporary keychain, decoded .p12/.p8, ExportOptions copy).
# Fixed path so that `cleanup`, run as a separate workflow step, finds it.
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TEMP_ROOT="${TEMP_ROOT%/}"
SIGNING_DIR="$TEMP_ROOT/driveapp-signing"

# Provisioning profile folders: Xcode 16 and later read the first; older Xcode
# and some tools read the second. Profiles are installed into both and removed
# again by cleanup (only the files this script created).
PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)

# Must match project.yml: the FSKit module's bundle ID is $(APP_BUNDLE_ID).fsext.
FS_BUNDLE_SUFFIX=".fsext"

# Unsigned builds: Xcode builds with CODE_SIGNING_ALLOWED=NO and this script
# ad-hoc signs inside-out. Each entry is "<path inside the .app>|<entitlements
# file in the repo>". Must match the targets and CODE_SIGN_ENTITLEMENTS in
# project.yml; the app itself uses ADHOC_APP_ENTITLEMENTS.
ADHOC_NESTED=(
  "Contents/MacOS/DriveAppStorageService|StorageService/DriveAppStorageService.entitlements"
  "Contents/Extensions/DriveAppFS.appex|FileSystemExtension/DriveAppFS.entitlements"
)
ADHOC_APP_ENTITLEMENTS="App/DriveApp.entitlements"

# State set by the stages.
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
MARKETING_VERSION_VALUE=""
APP_NAME=""
APP_BUNDLE_ID=""
PROJECT_NAME=""
PROJECT_PATH=""
XCODE_SELECTED=""
SIGNED="no"
NOTARIZED="no"
NOTARIZE_SKIP_REASON=""
KEYCHAIN_PATH=""
SIGNING_IDENTITY_HASH=""
FS_PROFILE_UUID=""
APP_PROFILE_UUID=""
ARCHIVE_PATH=""
EXPORTED_APP=""
DMG_NAME=""
DMG_PATH=""
SHA_PATH=""
RELEASE_TAG=""
RELEASE_URL=""
PUBLISH="${PUBLISH_RELEASE:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_ci() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }

log() { printf '==> %s\n' "$*"; }
warn() {
  if is_ci; then printf '::warning::%s\n' "$*" >&2; else printf 'WARNING: %s\n' "$*" >&2; fi
}
die() {
  local code=1
  if [[ "${2:-}" =~ ^[0-9]+$ ]]; then code="$2"; fi
  if is_ci; then printf '::endgroup::\n::error::%s\n' "$1" >&2; else printf 'ERROR: %s\n' "$1" >&2; fi
  exit "$code"
}

group_start() { if is_ci; then printf '::group::%s\n' "$*"; else printf '\n=== %s ===\n' "$*"; fi; }
group_end() { if is_ci; then printf '::endgroup::\n'; fi; }

# Hide a derived secret value from the GitHub Actions log.
mask() { if is_ci && [[ -n "${1:-}" ]]; then printf '::add-mask::%s\n' "$1"; fi; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found on PATH. $2"
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}

# Read a scalar from project.yml without yq: first "  KEY: value" line.
read_spec_setting() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]+" key ":[[:space:]]*[^[:space:]#]" {
      line = $0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/^["\047]|["\047]$/, "", line)
      print line
      exit
    }' "$PROJECT_SPEC"
}

read_spec_name() {
  awk '/^name:[[:space:]]*/ { v = $2; gsub(/^["\047]|["\047]$/, "", v); print v; exit }' "$PROJECT_SPEC"
}

# "26.4.1" -> "000260000400001" (sortable as a string).
version_key() {
  printf '%s\n' "$1" | awk -F. '{ printf "%05d%05d%05d\n", $1 + 0, $2 + 0, $3 + 0 }'
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

any_set() {
  local name
  for name in "$@"; do [[ -n "${!name:-}" ]] && return 0; done
  return 1
}

missing_of() {
  local name out=""
  for name in "$@"; do [[ -n "${!name:-}" ]] || out="$out $name"; done
  printf '%s' "${out# }"
}

usage() {
  cat <<'EOF'
Usage: scripts/build-dmg.sh [COMMAND] [--version X.Y.Z] [--build-number N]

Builds the DriveApp macOS app with Xcode 26, packages it as a DMG, and
(on GitHub Actions) attaches it to a draft pre-release v<version>-b<build>.

Commands:
  build       Run every stage (default).
  preflight   Check inputs, platform and tools only; build nothing.
  cleanup     Delete the temporary keychain, decoded keys and the profiles
              this script installed. Safe to repeat.
  help        Show this help (same as --help / -h).

Inputs (environment variables or flags):
  VERSION            Marketing version: MAJOR.MINOR.PATCH, optional -prerelease
                     suffix (e.g. 0.0.1, 0.1.0-beta.1). CFBundleShortVersionString
                     gets the numeric part only.
  BUILD_NUMBER       Digits only (CFBundleVersion), e.g. 1.

Optional signing (all or nothing; unset = ad-hoc signed "-unsigned.dmg"):
  MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, APPLE_TEAM_ID,
  MACOS_PROFILE_FSEXT_BASE64 (Developer ID profile for <APP_BUNDLE_ID>.fsext
                     with the FSKit Module capability; required when signing),
  MACOS_PROFILE_APP_BASE64 (optional Developer ID profile for the app),
  KEYCHAIN_PASSWORD (optional; random if unset)

Optional notarisation (needs signing too):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64

Other environment:
  XCODE_APP          Path to a specific Xcode.app (default: newest
                     /Applications/Xcode_26*.app).
  PUBLISH_RELEASE    1 = create the draft release, 0 = skip. Default: 1 on
                     GitHub Actions, 0 elsewhere.
  GH_TOKEN           Token for `gh` (required when publishing).
  BUILD_DIR          Output directory (default: <repo>/build).

Outputs: build/dist/<App>-<version>-<build>[-unsigned].dmg and .dmg.sha256

Runs only on macOS. On other systems `preflight`/`build` stop with a clear
message; `cleanup` and `help` work anywhere.
EOF
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

validate_inputs() {
  [[ -n "$VERSION" ]] || die "VERSION is not set (workflow input 'version', e.g. 0.0.1)." 2
  [[ -n "$BUILD_NUMBER" ]] || die "BUILD_NUMBER is not set (workflow input 'build_number', e.g. 1)." 2
  if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    die "VERSION '$VERSION' is not valid. Use MAJOR.MINOR.PATCH with an optional -prerelease suffix, e.g. 0.0.1 or 0.1.0-beta.1." 2
  fi
  if ! [[ "$BUILD_NUMBER" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
    die "BUILD_NUMBER '$BUILD_NUMBER' is not valid. Use digits only (no leading zeros), e.g. 1." 2
  fi
  MARKETING_VERSION_VALUE="${VERSION%%-*}"
  RELEASE_TAG="v${VERSION}-b${BUILD_NUMBER}"
}

preflight() {
  group_start "Preflight"
  validate_inputs
  log "Version $VERSION (CFBundleShortVersionString $MARKETING_VERSION_VALUE), build $BUILD_NUMBER, release tag $RELEASE_TAG"

  local os
  os="$(uname -s)"
  if [[ "$os" != "Darwin" ]]; then
    die "This build needs macOS with Xcode 26 (found $os). On Linux, only static checks are possible: actionlint .github/workflows/build-dmg.yml; shellcheck -x scripts/build-dmg.sh. Run the build on GitHub Actions (Actions > Build DMG > Run workflow) or on a Mac." 3
  fi
  log "Host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  [[ "$(uname -m)" == "arm64" ]] || warn "Host is $(uname -m), not arm64. The build still targets arm64 only."

  [[ -f "$PROJECT_SPEC" ]] || die "project.yml not found at $PROJECT_SPEC."
  local tool
  for tool in xcrun hdiutil codesign security shasum ditto openssl base64 awk; do
    require_tool "$tool" "It ships with macOS."
  done
  [[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy not found."

  APP_NAME="$(read_spec_setting APP_NAME)"
  PROJECT_NAME="$(read_spec_name)"
  [[ -n "$APP_NAME" ]] || die "APP_NAME not found in project.yml settings.base."
  APP_BUNDLE_ID="$(read_spec_setting APP_BUNDLE_ID)"
  [[ "$APP_BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || die "APP_BUNDLE_ID '$APP_BUNDLE_ID' in project.yml settings.base is missing or not a reverse-DNS bundle ID."
  [[ -n "$PROJECT_NAME" ]] || die "Top-level 'name:' not found in project.yml."
  PROJECT_PATH="$REPO_ROOT/$PROJECT_NAME.xcodeproj"
  log "App name (project.yml APP_NAME): $APP_NAME"

  # Signing inputs: all or nothing.
  if [[ -n "${MACOS_CERT_P12_BASE64:-}" ]]; then
    SIGNED="yes"
    [[ -n "${APPLE_TEAM_ID:-}" ]] || die "MACOS_CERT_P12_BASE64 is set but APPLE_TEAM_ID is not. Add the APPLE_TEAM_ID secret (10-character team ID)."
    [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "APPLE_TEAM_ID must be a 10-character team ID (A-Z, 0-9)."
    [[ -n "${MACOS_CERT_PASSWORD:-}" ]] || warn "MACOS_CERT_PASSWORD is empty; importing the .p12 with an empty password."
    # com.apple.developer.fskit.fsmodule is a restricted entitlement, so the
    # Developer ID-signed FSKit module needs a Developer ID provisioning profile
    # (TN3125). Without one Xcode stops at "requires a provisioning profile"
    # after compiling, and even a forced signature would not load. Fail now.
    [[ -n "${MACOS_PROFILE_FSEXT_BASE64:-}" ]] \
      || die "MACOS_CERT_P12_BASE64 is set but MACOS_PROFILE_FSEXT_BASE64 is not. A Developer ID build of the FSKit module needs a Developer ID provisioning profile for $APP_BUNDLE_ID$FS_BUNDLE_SUFFIX with the FSKit Module capability (docs/12-pipeline-usage.md). Add the secret, or remove MACOS_CERT_P12_BASE64 for an unsigned build."
    log "Signing: Developer ID (MACOS_CERT_P12_BASE64 is set), FSKit module profile from MACOS_PROFILE_FSEXT_BASE64."
    if [[ -n "${MACOS_PROFILE_APP_BASE64:-}" ]]; then
      log "Signing: app profile from MACOS_PROFILE_APP_BASE64."
    else
      log "Signing: no app profile (MACOS_PROFILE_APP_BASE64 not set); the app claims no restricted entitlement."
    fi
  else
    SIGNED="no"
    if any_set MACOS_CERT_PASSWORD APPLE_TEAM_ID MACOS_PROFILE_FSEXT_BASE64 MACOS_PROFILE_APP_BASE64; then
      warn "Some signing secrets are set but MACOS_CERT_P12_BASE64 is not; building unsigned."
    fi
    log "Signing: none (MACOS_CERT_P12_BASE64 not set). Ad-hoc signing; DMG will be named -unsigned."
  fi

  # Notarisation inputs.
  if [[ "$SIGNED" != "yes" ]]; then
    NOTARIZE_SKIP_REASON="the build is unsigned (MACOS_CERT_P12_BASE64 not set); notarisation needs a Developer ID signature"
  elif ! any_set ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64; then
    NOTARIZE_SKIP_REASON="ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8_BASE64 are not set"
  elif [[ -n "$(missing_of ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64)" ]]; then
    NOTARIZE_SKIP_REASON="incomplete App Store Connect key, missing: $(missing_of ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64)"
    warn "Notarisation secrets are only partly set ($NOTARIZE_SKIP_REASON)."
  else
    NOTARIZE_SKIP_REASON=""
  fi
  if [[ -n "$NOTARIZE_SKIP_REASON" ]]; then
    log "Notarisation: will be skipped ($NOTARIZE_SKIP_REASON)."
  else
    log "Notarisation: enabled."
  fi

  # Release publishing.
  if [[ -z "$PUBLISH" ]]; then
    if is_ci; then PUBLISH="1"; else PUBLISH="0"; fi
  fi
  if [[ "$PUBLISH" == "1" ]]; then
    require_tool gh "Install GitHub CLI, or set PUBLISH_RELEASE=0."
    [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is not set (needed to create the draft release). Set PUBLISH_RELEASE=0 to skip publishing."
    [[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY is not set (owner/repo). Set it, or PUBLISH_RELEASE=0."
    ensure_release_absent
    log "Release: will create draft pre-release $RELEASE_TAG in $GITHUB_REPOSITORY."
  else
    log "Release: publishing disabled (PUBLISH_RELEASE=0); the DMG stays in $DIST_DIR."
  fi
  group_end
}

# Fail early (before a 15-minute build) if the release or the tag exists.
ensure_release_absent() {
  local out rc
  rc=0
  out="$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json tagName 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    die "Release $RELEASE_TAG already exists in $GITHUB_REPOSITORY. Use a new build_number (or delete the old draft)."
  elif [[ "$out" != *"release not found"* ]]; then
    die "Could not check for release $RELEASE_TAG: $out"
  fi
  rc=0
  out="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    die "Tag $RELEASE_TAG already exists in $GITHUB_REPOSITORY. Use a new build_number."
  elif [[ "$out" != *"404"* ]]; then
    die "Could not check for tag $RELEASE_TAG: $out"
  fi
}

select_xcode() {
  group_start "Select Xcode"
  local candidate version key best="" best_key=""
  if [[ -n "${XCODE_APP:-}" ]]; then
    [[ -d "$XCODE_APP/Contents/Developer" ]] || die "XCODE_APP='$XCODE_APP' is not an Xcode.app."
    best="$XCODE_APP"
  else
    for candidate in /Applications/Xcode_26*.app; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue   # skip aliases like Xcode_26.4.app
      case "$candidate" in *[Bb]eta* | *Release_Candidate*) continue ;; esac
      version="$(plist_get "$candidate/Contents/version.plist" CFBundleShortVersionString || true)"
      if [[ -z "$version" ]]; then
        version="${candidate#/Applications/Xcode_}"
        version="${version%.app}"
      fi
      key="$(version_key "$version")"
      if [[ -z "$best" || "$key" > "$best_key" ]]; then
        best="$candidate"
        best_key="$key"
      fi
    done
    [[ -n "$best" ]] || die "No /Applications/Xcode_26*.app found on this machine. Set XCODE_APP=/path/to/Xcode.app, or pick a runner image with Xcode 26."
  fi
  XCODE_SELECTED="$best"
  export DEVELOPER_DIR="$XCODE_SELECTED/Contents/Developer"
  if is_ci; then
    # Also switch the global selection on the throwaway runner.
    sudo xcode-select --switch "$DEVELOPER_DIR"
  fi
  log "Using $XCODE_SELECTED"
  xcodebuild -version
  local major sdk
  major="$(xcodebuild -version | awk '/^Xcode / { split($2, v, "."); print v[1]; exit }')"
  [[ "${major:-0}" -ge 26 ]] || die "Xcode 26 or later is required (selected Xcode $major)."
  sdk="$(xcrun --sdk macosx --show-sdk-version)"
  log "macOS SDK $sdk"
  [[ "$(version_key "$sdk")" > "$(version_key 25.99)" ]] || die "macOS 26 SDK required (found $sdk)."
  group_end
}

generate_project() {
  group_start "Generate Xcode project (XcodeGen)"
  if ! command -v xcodegen >/dev/null 2>&1; then
    require_tool brew "Install Homebrew, or install XcodeGen another way."
    log "Installing XcodeGen with Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew install xcodegen
  fi
  log "XcodeGen $(xcodegen --version 2>/dev/null | awk '{ print $NF }')"
  (cd "$REPO_ROOT" && xcodegen generate --spec "$PROJECT_SPEC")
  [[ -d "$PROJECT_PATH" ]] || die "XcodeGen did not create $PROJECT_PATH."

  # The build setting is the authority for the product name.
  local product
  product="$(xcodebuild -project "$PROJECT_PATH" -target "$APP_TARGET" -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *PRODUCT_NAME = / { print $2; exit }')"
  if [[ -n "$product" && "$product" != "$APP_NAME" ]]; then
    warn "PRODUCT_NAME ($product) differs from project.yml APP_NAME ($APP_NAME); using $product."
    APP_NAME="$product"
  fi
  xcodebuild -project "$PROJECT_PATH" -list
  group_end
}

setup_signing() {
  if [[ "$SIGNED" != "yes" ]]; then
    log "Signing setup skipped (unsigned build)."
    return 0
  fi
  group_start "Set up temporary signing keychain"
  rm -rf "$SIGNING_DIR"
  (umask 077 && mkdir -p "$SIGNING_DIR")
  chmod 700 "$SIGNING_DIR"

  local keychain_password="${KEYCHAIN_PASSWORD:-}"
  if [[ -z "$keychain_password" ]]; then
    keychain_password="$(openssl rand -base64 32 | tr -d '\n')"
  fi
  mask "$keychain_password"

  KEYCHAIN_PATH="$SIGNING_DIR/ci-$(openssl rand -hex 8).keychain-db"
  local p12="$SIGNING_DIR/cert.p12"
  (umask 077 && printf '%s' "$MACOS_CERT_P12_BASE64" | tr -d '[:space:]' | base64 --decode >"$p12") \
    || die "MACOS_CERT_P12_BASE64 is not valid base64."
  [[ -s "$p12" ]] || die "MACOS_CERT_P12_BASE64 decoded to an empty file."

  # Remember the user search list so cleanup can restore it.
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' >"$SIGNING_DIR/original-keychains"

  security create-keychain -p "$keychain_password" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$keychain_password" "$KEYCHAIN_PATH"
  security import "$p12" -k "$KEYCHAIN_PATH" -f pkcs12 -P "${MACOS_CERT_PASSWORD:-}" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null \
    || die "Could not import the .p12 (wrong MACOS_CERT_PASSWORD or not a PKCS#12 file)."
  rm -f "$p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$KEYCHAIN_PATH" >/dev/null

  local -a search=("$KEYCHAIN_PATH")
  local kc
  while IFS= read -r kc; do
    [[ -n "$kc" ]] && search+=("$kc")
  done <"$SIGNING_DIR/original-keychains"
  security list-keychains -d user -s "${search[@]}"

  local identities
  identities="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep '"Developer ID Application' || true)"
  [[ -n "$identities" ]] || die "No valid 'Developer ID Application' identity in the imported .p12. Export the Developer ID Application certificate WITH its private key."
  if [[ "$(printf '%s\n' "$identities" | wc -l | tr -d ' ')" -gt 1 ]]; then
    warn "More than one Developer ID Application identity found; using the first."
  fi
  SIGNING_IDENTITY_HASH="$(printf '%s\n' "$identities" | head -n 1 | awk '{ print $2 }')"
  log "Imported identity: $(printf '%s\n' "$identities" | head -n 1 | sed -e 's/^[[:space:]]*[0-9]*)[[:space:]]*//')"

  install_profile fsext MACOS_PROFILE_FSEXT_BASE64 "$APP_BUNDLE_ID$FS_BUNDLE_SUFFIX" com.apple.developer.fskit.fsmodule
  FS_PROFILE_UUID="$PROFILE_UUID"
  if [[ -n "${MACOS_PROFILE_APP_BASE64:-}" ]]; then
    install_profile app MACOS_PROFILE_APP_BASE64 "$APP_BUNDLE_ID" ""
    APP_PROFILE_UUID="$PROFILE_UUID"
  fi
  group_end
}

# install_profile NAME SECRET_VAR BUNDLE_ID REQUIRED_ENTITLEMENT -> PROFILE_UUID.
# Decodes a Developer ID provisioning profile, checks that it fits this build
# (team, App ID, Developer ID type, expiry, certificate, entitlement) and
# installs it where Xcode looks. Not called in $(...), so `set -e` and die apply.
PROFILE_UUID=""
install_profile() {
  local name="$1" var="$2" bundle_id="$3" required="$4"
  local raw="$SIGNING_DIR/$name.provisionprofile" plist="$SIGNING_DIR/$name-profile.plist"
  (umask 077 && printf '%s' "${!var}" | tr -d '[:space:]' | base64 --decode >"$raw") \
    || die "$var is not valid base64."
  security cms -D -i "$raw" >"$plist" 2>/dev/null \
    || die "$var does not decode to a provisioning profile (security cms -D failed). Encode the .provisionprofile file with: base64 -i <file>"

  local uuid pname team appid all_devices expires now
  uuid="$(plist_get "$plist" UUID || true)"
  pname="$(plist_get "$plist" Name || true)"
  team="$(plist_get "$plist" TeamIdentifier:0 || true)"
  appid="$(plist_get "$plist" Entitlements:com.apple.application-identifier || true)"
  all_devices="$(plist_get "$plist" ProvisionsAllDevices || true)"
  expires="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || true)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "$var: profile has no valid UUID."
  log "$name profile: \"$pname\" ($uuid), App ID $appid, expires $expires"
  [[ "$team" == "$APPLE_TEAM_ID" ]] || die "$var: profile team is '$team', expected APPLE_TEAM_ID ($APPLE_TEAM_ID)."
  [[ "$appid" == "$APPLE_TEAM_ID.$bundle_id" ]] \
    || die "$var: profile App ID is '$appid', expected $APPLE_TEAM_ID.$bundle_id. Create the profile for that bundle ID."
  [[ "$all_devices" == "true" ]] \
    || die "$var: not a Developer ID profile (ProvisionsAllDevices is not true). Create it under Profiles > Distribution > Developer ID."
  if [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    [[ "$expires" > "$now" ]] || die "$var: profile expired ($expires)."
  else
    warn "$var: could not read the profile's ExpirationDate ('$expires'); not checking expiry."
  fi
  if [[ -n "$required" ]]; then
    [[ "$(plist_get "$plist" "Entitlements:$required" || true)" == "true" ]] \
      || die "$var: profile does not authorise $required. Enable that capability on the App ID and regenerate the profile."
  fi

  # The imported certificate must be one of the profile's certificates.
  local i cert_b64 sha match="no"
  for ((i = 0; i < 50; i++)); do
    cert_b64="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null)" || break
    sha="$(printf '%s' "$cert_b64" | base64 --decode | openssl sha1 | awk '{ print toupper($NF) }' || true)"
    if [[ "$sha" == "$SIGNING_IDENTITY_HASH" ]]; then match="yes"; break; fi
  done
  [[ "$match" == "yes" ]] \
    || die "$var: the profile does not include the imported Developer ID Application certificate. Regenerate the profile with that certificate."

  local dir dest
  for dir in "${PROFILE_DIRS[@]}"; do
    mkdir -p "$dir"
    dest="$dir/$uuid.provisionprofile"
    if [[ -e "$dest" ]]; then
      log "$name profile already installed at $dest; leaving it in place."
      continue
    fi
    cp "$raw" "$dest"
    printf '%s\n' "$dest" >>"$SIGNING_DIR/installed-profiles"
  done
  rm -f "$raw" "$plist"
  PROFILE_UUID="$uuid"
}

run_xcodebuild() {
  local name="$1"
  shift
  local logfile="$LOG_DIR/$name.log"
  local status=0
  mkdir -p "$LOG_DIR"
  log "xcodebuild $*"
  if command -v xcbeautify >/dev/null 2>&1; then
    local -a fmt=(xcbeautify)
    if is_ci; then fmt+=(--renderer github-actions); fi
    xcodebuild "$@" 2>&1 | tee "$logfile" | "${fmt[@]}" || status=$?
  else
    xcodebuild "$@" 2>&1 | tee "$logfile" || status=$?
  fi
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "--- last 60 lines of $logfile ---" >&2
    tail -n 60 "$logfile" >&2 || true
    die "xcodebuild $name failed (exit $status). Full log on the runner: $logfile"
  fi
}

archive() {
  group_start "Archive ($CONFIGURATION, arm64)"
  ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
  rm -rf "$ARCHIVE_PATH"

  local -a settings=(
    "ARCHS=arm64"
    "ONLY_ACTIVE_ARCH=NO"
    "MARKETING_VERSION=$MARKETING_VERSION_VALUE"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  )
  if [[ "$SIGNED" == "yes" ]]; then
    # Applies to every target, so nested code (FSKit .appex, helper tool) is
    # signed inside-out by Xcode with the same identity and hardened runtime.
    settings+=(
      "CODE_SIGN_STYLE=Manual"
      "CODE_SIGN_IDENTITY=Developer ID Application"
      "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
      "ENABLE_HARDENED_RUNTIME=YES"
      "OTHER_CODE_SIGN_FLAGS=--timestamp --options=runtime --keychain $KEYCHAIN_PATH"
      # Per-target profiles (project.yml maps these to PROVISIONING_PROFILE_SPECIFIER).
      "DRIVEAPP_FS_PROFILE=$FS_PROFILE_UUID"
      "DRIVEAPP_APP_PROFILE=$APP_PROFILE_UUID"
    )
  else
    # No signing in Xcode at all. With CODE_SIGN_IDENTITY=- ("Sign to Run
    # Locally") Xcode still checks entitlements and stops with "requires a
    # provisioning profile" for the restricted FSKit entitlement. export_app
    # ad-hoc signs the copied app inside-out instead (adhoc_sign_app).
    settings+=(
      "CODE_SIGNING_ALLOWED=NO"
      "CODE_SIGNING_REQUIRED=NO"
      "CODE_SIGN_IDENTITY=-"
      "DEVELOPMENT_TEAM="
    )
  fi

  run_xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    archive \
    "${settings[@]}"

  local app_rel
  app_rel="$(plist_get "$ARCHIVE_PATH/Info.plist" ApplicationProperties:ApplicationPath || true)"
  [[ -n "$app_rel" ]] || die "The archive is not an app archive (no ApplicationProperties). Set SKIP_INSTALL: YES on every non-app target (extension, helper tool) in project.yml."
  [[ -d "$ARCHIVE_PATH/Products/$app_rel" ]] || die "Archived app not found at Products/$app_rel."
  log "Archived $app_rel"
  group_end
}

# Nested code inside the app: bundles under Contents (not descending into
# them) and executables in Contents/MacOS other than the main one.
list_nested_code() {
  local app="$1" main
  main="$(plist_get "$app/Contents/Info.plist" CFBundleExecutable || true)"
  find "$app/Contents" -mindepth 1 \( -name '*.appex' -o -name '*.xpc' -o -name '*.framework' -o -name '*.app' \) -prune -print 2>/dev/null
  find "$app/Contents/MacOS" -type f -perm -u+x ! -name "${main:-.}" 2>/dev/null
}

# Report every nested code item. Signed builds fail on anything notarisation
# would reject (no Developer ID, no hardened runtime, no secure timestamp).
check_nested_signatures() {
  local app="$1" item rel info who problems=""
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    rel="${item#"$app"/}"
    info="$(codesign -dv --verbose=2 "$item" 2>&1 || true)"
    if [[ "$info" == *"not signed"* ]]; then
      problems="$problems $rel(not signed)"
    elif [[ "$SIGNED" == "yes" ]]; then
      [[ "$info" == *"Authority=Developer ID Application"* ]] || problems="$problems $rel(no Developer ID)"
      [[ "$info" == *"(runtime)"* ]] || problems="$problems $rel(no hardened runtime)"
      [[ "$info" == *"Timestamp="* ]] || problems="$problems $rel(no secure timestamp)"
      if [[ "$item" == *.appex && ! -f "$item/Contents/embedded.provisionprofile" ]]; then
        problems="$problems $rel(no embedded.provisionprofile)"
      fi
    fi
    who="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -n 1)"
    [[ -n "$who" ]] || who="$(printf '%s\n' "$info" | sed -n 's/^Signature=//p' | head -n 1)"
    log "Nested: $rel (${who:-unknown signature})"
  done < <(list_nested_code "$app")
  if [[ -n "$problems" ]]; then
    if [[ "$SIGNED" == "yes" ]]; then die "Nested code problems:$problems"; fi
    warn "Nested code problems:$problems"
  fi
}

# Resolve the build settings an entitlements file uses, for ad-hoc signing.
resolve_entitlements() {
  local src="$REPO_ROOT/$1" out="$2" tmp="$2.xml"
  [[ -f "$src" ]] || die "Entitlements file $1 not found (ADHOC_NESTED / ADHOC_APP_ENTITLEMENTS in build-dmg.sh vs project.yml)."
  plutil -convert xml1 -o "$tmp" "$src" || die "$1 is not a valid plist."
  # Unsigned build: DEVELOPMENT_TEAM is empty, exactly as Xcode would expand it.
  # shellcheck disable=SC2016  # literal $(...) placeholders, not expansions
  sed -e 's/\$(DEVELOPMENT_TEAM)//g' -e "s/\\\$(APP_BUNDLE_ID)/$APP_BUNDLE_ID/g" "$tmp" >"$out"
  rm -f "$tmp"
  # shellcheck disable=SC2016
  if grep -q '\$(' "$out"; then
    die "$1 uses a build setting other than DEVELOPMENT_TEAM/APP_BUNDLE_ID; teach resolve_entitlements in build-dmg.sh about it."
  fi
  plutil -lint "$out" >/dev/null || die "Resolved entitlements for $1 are not a valid plist."
}

# Unsigned build: ad-hoc sign the app inside-out with each target's
# entitlements and the hardened runtime flag (as Xcode would have).
adhoc_sign_app() {
  local app="$1" dir="$BUILD_DIR/adhoc-entitlements" entry rel ent n=0 item known
  rm -rf "$dir"
  mkdir -p "$dir"
  # Refuse nested code this script does not know how to sign.
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    known="no"
    for entry in "${ADHOC_NESTED[@]}"; do
      if [[ "${item#"$app"/}" == "${entry%%|*}" ]]; then known="yes"; fi
    done
    [[ "$known" == "yes" ]] || die "Unknown nested code ${item#"$app"/}: add it to ADHOC_NESTED in scripts/build-dmg.sh."
  done < <(list_nested_code "$app")
  for entry in "${ADHOC_NESTED[@]}"; do
    rel="${entry%%|*}"
    ent="$dir/$n.entitlements"
    n=$((n + 1))
    [[ -e "$app/$rel" ]] || die "Expected nested code $rel is missing from the app (embed phases in project.yml)."
    resolve_entitlements "${entry#*|}" "$ent"
    codesign --force --sign - --timestamp=none --options runtime --entitlements "$ent" "$app/$rel" \
      || die "Ad-hoc signing $rel failed."
  done
  ent="$dir/app.entitlements"
  resolve_entitlements "$ADHOC_APP_ENTITLEMENTS" "$ent"
  codesign --force --sign - --timestamp=none --options runtime --entitlements "$ent" "$app" \
    || die "Ad-hoc signing the app failed."
}

export_app() {
  group_start "Export app"
  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  local app_rel
  app_rel="$(plist_get "$ARCHIVE_PATH/Info.plist" ApplicationProperties:ApplicationPath)"

  if [[ "$SIGNED" == "yes" ]]; then
    local options="$SIGNING_DIR/ExportOptions.plist"
    cp "$EXPORT_OPTIONS_TEMPLATE" "$options"
    /usr/libexec/PlistBuddy -c "Set :teamID $APPLE_TEAM_ID" "$options" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :teamID string $APPLE_TEAM_ID" "$options"
    # Manual export signing needs a profile per bundle ID that had one at build time.
    /usr/libexec/PlistBuddy -c "Delete :provisioningProfiles" "$options" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$options"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID$FS_BUNDLE_SUFFIX string $FS_PROFILE_UUID" "$options"
    if [[ -n "$APP_PROFILE_UUID" ]]; then
      /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROFILE_UUID" "$options"
    fi
    run_xcodebuild export \
      -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$options"
    EXPORTED_APP="$EXPORT_DIR/$(basename "$app_rel")"
    [[ -d "$EXPORTED_APP" ]] || die "Export finished but $EXPORTED_APP is missing."
    codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP" || die "codesign verification failed for the exported app."
    local info
    info="$(codesign -dv --verbose=2 "$EXPORTED_APP" 2>&1)"
    printf '%s\n' "$info" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true
    [[ "$info" == *"Authority=Developer ID Application"* ]] || die "Exported app is not signed with a Developer ID Application certificate."
    [[ "$info" == *"(runtime)"* ]] || die "Exported app lacks the hardened runtime flag."
  else
    # Unsigned: Xcode built without signing; ad-hoc sign the copy here.
    EXPORTED_APP="$EXPORT_DIR/$(basename "$app_rel")"
    ditto "$ARCHIVE_PATH/Products/$app_rel" "$EXPORTED_APP"
    adhoc_sign_app "$EXPORTED_APP"
    codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP" || die "Ad-hoc signature of the app does not verify."
    log "Unsigned build: the FSKit module claims a restricted entitlement without a profile, so macOS will not load it. Only the app itself is testable."
  fi
  check_nested_signatures "$EXPORTED_APP"
  local short build
  short="$(plist_get "$EXPORTED_APP/Contents/Info.plist" CFBundleShortVersionString || true)"
  build="$(plist_get "$EXPORTED_APP/Contents/Info.plist" CFBundleVersion || true)"
  log "Exported $(basename "$EXPORTED_APP"): version $short ($build)"
  [[ "$short" == "$MARKETING_VERSION_VALUE" && "$build" == "$BUILD_NUMBER" ]] \
    || die "App version is $short ($build); expected $MARKETING_VERSION_VALUE ($BUILD_NUMBER)."
  group_end
}

make_dmg() {
  group_start "Create DMG"
  local file_stem="${APP_NAME// /-}-${VERSION}-${BUILD_NUMBER}"
  if [[ "$SIGNED" == "yes" ]]; then DMG_NAME="$file_stem.dmg"; else DMG_NAME="$file_stem-unsigned.dmg"; fi
  DMG_PATH="$DIST_DIR/$DMG_NAME"

  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR" "$DIST_DIR"
  rm -f "$DMG_PATH" "$DMG_PATH.sha256"
  ditto "$EXPORTED_APP" "$STAGING_DIR/$(basename "$EXPORTED_APP")"
  ln -s /Applications "$STAGING_DIR/Applications"

  # hdiutil sometimes fails with "Resource busy" on CI; retry a few times.
  local attempt
  for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"; then
      break
    fi
    [[ $attempt -lt 3 ]] || die "hdiutil create failed 3 times."
    warn "hdiutil create failed (attempt $attempt); retrying in 5 s."
    sleep 5
  done
  hdiutil verify "$DMG_PATH"

  if [[ "$SIGNED" == "yes" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY_HASH" --keychain "$KEYCHAIN_PATH" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH" || die "DMG signature does not verify."
  fi
  log "Created $DMG_PATH ($(du -h "$DMG_PATH" | awk '{ print $1 }'))"
  group_end
}

notarize() {
  if [[ -n "$NOTARIZE_SKIP_REASON" ]]; then
    log "Notarisation skipped: $NOTARIZE_SKIP_REASON."
    return 0
  fi
  group_start "Notarise and staple"
  local p8="$SIGNING_DIR/AuthKey_${ASC_KEY_ID}.p8"
  (umask 077 && printf '%s' "$ASC_KEY_P8_BASE64" | tr -d '[:space:]' | base64 --decode >"$p8") \
    || die "ASC_KEY_P8_BASE64 is not valid base64."
  chmod 600 "$p8"
  grep -q 'BEGIN PRIVATE KEY' "$p8" || die "ASC_KEY_P8_BASE64 does not decode to a .p8 private key."

  local -a auth=(--key "$p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  local result="$BUILD_DIR/notarytool-submit.json"
  local rc=0
  xcrun notarytool submit "$DMG_PATH" "${auth[@]}" --wait --timeout 20m --output-format json >"$result" || rc=$?
  cat "$result" || true
  printf '\n'
  local id status
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  if [[ $rc -ne 0 || "$status" != "Accepted" ]]; then
    if [[ -n "$id" ]]; then
      log "Notary log for submission $id:"
      xcrun notarytool log "$id" "${auth[@]}" || true
    fi
    die "Notarisation failed (exit $rc, status '${status:-unknown}')."
  fi
  rm -f "$p8"

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" \
    || warn "spctl assessment of the DMG did not pass (informational)."
  NOTARIZED="yes"
  group_end
}

checksum() {
  group_start "SHA-256"
  SHA_PATH="$DMG_PATH.sha256"
  (cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
  cat "$SHA_PATH"
  local hash
  hash="$(awk '{ print $1 }' "$SHA_PATH")"
  summary "## $APP_NAME DMG"
  summary ""
  summary "| | |"
  summary "| --- | --- |"
  summary "| File | \`$DMG_NAME\` |"
  summary "| Version | $VERSION (build $BUILD_NUMBER) |"
  summary "| Signed (Developer ID) | $SIGNED |"
  summary "| Notarised | $NOTARIZED |"
  summary "| SHA-256 | \`$hash\` |"
  summary "| Xcode | $(basename "$XCODE_SELECTED") |"
  group_end
}

publish_release() {
  if [[ "$PUBLISH" != "1" ]]; then
    log "Release skipped (PUBLISH_RELEASE=0). DMG: $DMG_PATH"
    return 0
  fi
  group_start "Create draft pre-release $RELEASE_TAG"
  ensure_release_absent
  local target="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
  local notes="$BUILD_DIR/release-notes.md"
  local title="$APP_NAME $VERSION (build $BUILD_NUMBER)"
  [[ "$SIGNED" == "yes" ]] || title="$title, unsigned"
  {
    printf 'Test build of %s %s (build %s) from commit %s.\n\n' "$APP_NAME" "$VERSION" "$BUILD_NUMBER" "$target"
    printf -- '- Developer ID signed: %s\n- Notarised: %s\n' "$SIGNED" "$NOTARIZED"
    printf -- '- Built with %s on macOS %s, arm64 only. Requires macOS 26 or later.\n' \
      "$(basename "$XCODE_SELECTED" .app)" "$(sw_vers -productVersion)"
    printf -- "- SHA-256: \`%s\`\n\n" "$(awk '{ print $1 }' "$SHA_PATH")"
    printf "Verify: \`shasum -a 256 -c %s\` in the download folder.\n\n" "$DMG_NAME.sha256"
    if [[ "$SIGNED" != "yes" ]]; then
      printf 'This DMG is NOT signed or notarised. macOS will block the first launch: see docs/12-pipeline-usage.md ("Opening an unsigned build").\n'
    elif [[ "$NOTARIZED" != "yes" ]]; then
      printf 'Signed but NOT notarised. Gatekeeper will block the first launch on other Macs.\n'
    fi
  } >"$notes"

  local -a cmd=(gh release create "$RELEASE_TAG" "$DMG_PATH" "$SHA_PATH"
    --repo "$GITHUB_REPOSITORY" --draft --prerelease --target "$target"
    --title "$title" --notes-file "$notes")
  RELEASE_URL="$("${cmd[@]}")"
  log "Draft pre-release: $RELEASE_URL"
  summary ""
  summary "Draft pre-release: $RELEASE_URL"
  group_end
}

# Idempotent; never fails. Removes the keychain and every decoded key.
cleanup() {
  local kc profile dir ours
  if [[ -d "$SIGNING_DIR" ]]; then
    # Remove only the profile files this script installed (listed by path).
    if [[ -f "$SIGNING_DIR/installed-profiles" ]]; then
      while IFS= read -r profile; do
        ours="no"
        for dir in "${PROFILE_DIRS[@]}"; do
          if [[ "$profile" == "$dir/"*.provisionprofile ]]; then ours="yes"; fi
        done
        if [[ "$ours" == "yes" && -f "$profile" ]]; then rm -f "$profile" || true; fi
      done <"$SIGNING_DIR/installed-profiles"
    fi
    if command -v security >/dev/null 2>&1; then
      if [[ -f "$SIGNING_DIR/original-keychains" ]]; then
        local -a original=()
        while IFS= read -r kc; do
          [[ -n "$kc" ]] && original+=("$kc")
        done <"$SIGNING_DIR/original-keychains"
        if [[ ${#original[@]} -gt 0 ]]; then
          security list-keychains -d user -s "${original[@]}" >/dev/null 2>&1 || true
        fi
      fi
      for kc in "$SIGNING_DIR"/*.keychain-db; do
        [[ -e "$kc" ]] || continue
        security delete-keychain "$kc" >/dev/null 2>&1 || true
      done
    fi
    rm -rf "$SIGNING_DIR" || true
    log "Cleanup: removed temporary keychain, decoded keys and installed profiles ($SIGNING_DIR)."
  else
    log "Cleanup: nothing to remove."
  fi
  return 0
}

on_exit() {
  local status=$?
  cleanup || true
  if [[ $status -ne 0 ]]; then
    printf 'build-dmg.sh: failed (exit %s).\n' "$status" >&2
  fi
  exit "$status"
}

build() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  preflight
  select_xcode
  generate_project
  setup_signing
  archive
  export_app
  make_dmg
  notarize
  checksum
  publish_release
  log "Done: $DMG_PATH"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local command="build"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help | help) usage; return 0 ;;
      build | preflight | cleanup) command="$1" ;;
      --version) [[ $# -ge 2 ]] || die "--version needs a value." 2; VERSION="$2"; shift ;;
      --version=*) VERSION="${1#*=}" ;;
      --build-number) [[ $# -ge 2 ]] || die "--build-number needs a value." 2; BUILD_NUMBER="$2"; shift ;;
      --build-number=*) BUILD_NUMBER="${1#*=}" ;;
      *) usage >&2; die "Unknown argument: $1" 2 ;;
    esac
    shift
  done

  case "$command" in
    build) build ;;
    preflight) preflight ;;
    cleanup) cleanup ;;
  esac
}

main "$@"
