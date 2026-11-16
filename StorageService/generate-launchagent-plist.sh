#!/bin/sh
# Writes the StorageService LaunchAgent plist into the host app bundle at
#   Contents/Library/LaunchAgents/$(APP_BUNDLE_ID).storageservice.plist
# Run as a DriveApp post-build script phase (before Xcode signs the app).
#
# Why a build phase instead of a checked-in plist: SMAppService.agent(plistName:) looks the plist
# up by file name inside Contents/Library/LaunchAgents, and the file name, Label and Mach service
# name all derive from APP_BUNDLE_ID / DEVELOPMENT_TEAM. Generating it keeps project.yml the single
# source of identity. The values must match the DriveAppStorageMachService Info.plist key.
#
# Docs: https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)
#       https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos
#       (BundleProgram is relative to the app bundle; AssociatedBundleIdentifiers names the app.)
# User-script sandboxing is off for the DriveApp target only (project.yml), so this script can
# create Contents/Library/LaunchAgents. It reads only build-setting environment variables.
set -eu

: "${APP_BUNDLE_ID:?APP_BUNDLE_ID is not set}"
: "${TARGET_BUILD_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}"
TEAM="${DEVELOPMENT_TEAM:-}"

# Restrict to reverse-DNS characters so the heredoc below cannot produce malformed XML.
case "$APP_BUNDLE_ID" in
  *[!A-Za-z0-9.-]*) echo "error: APP_BUNDLE_ID has unexpected characters: $APP_BUNDLE_ID" >&2; exit 1 ;;
esac
case "$TEAM" in
  *[!A-Z0-9]*) echo "error: DEVELOPMENT_TEAM has unexpected characters" >&2; exit 1 ;;
esac
if [ -z "$TEAM" ]; then
  echo "warning: DEVELOPMENT_TEAM is empty (ad-hoc build). The Mach service name will not be App Group prefixed, so the sandboxed app and FSKit extension cannot reach StorageService."
fi

LABEL="${APP_BUNDLE_ID}.storageservice"
MACH_SERVICE="${TEAM}.${APP_BUNDLE_ID}.storage"
OUT_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
OUT="${OUT_DIR}/${LABEL}.plist"

mkdir -p "$OUT_DIR"
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/DriveAppStorageService</string>
	<key>MachServices</key>
	<dict>
		<key>${MACH_SERVICE}</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>${APP_BUNDLE_ID}</string>
	</array>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST

plutil -lint "$OUT"
echo "Wrote ${OUT}"
