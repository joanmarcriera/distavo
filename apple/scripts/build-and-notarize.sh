#!/usr/bin/env bash
#
# Build, sign, and (for Direct/Setapp) notarize a Seshat edition.
# Companion to ../../docs/distribution-checklist.md.
#
# Usage:
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=seshat-notary \
#     ./build-and-notarize.sh direct        # -> notarized, stapled .app + .zip
#   TEAM_ID=... NOTARY_PROFILE=... ./build-and-notarize.sh setapp
#   TEAM_ID=... ./build-and-notarize.sh appstore  # -> .pkg for App Store upload
#
# Prereqs (one-time, see the checklist):
#   - "Developer ID Application" cert in the login keychain (direct/setapp)
#   - "Apple Distribution" cert + Mac App Store provisioning profile (appstore)
#   - notarytool keychain profile:
#       xcrun notarytool store-credentials seshat-notary \
#         --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
set -euo pipefail

cd "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

EDITION="${1:-}"
: "${TEAM_ID:?set TEAM_ID to your 10-char Apple Team ID}"

case "$EDITION" in
  direct)   XCCONFIG="configs/Direct.xcconfig";   METHOD="developer-id" ;;
  setapp)   XCCONFIG="configs/Setapp.xcconfig";   METHOD="developer-id" ;;
  appstore) XCCONFIG="configs/AppStore.xcconfig"; METHOD="app-store-connect" ;;
  *) echo "usage: $0 {direct|setapp|appstore}" >&2; exit 2 ;;
esac

BUILD_DIR="build/release-$EDITION"
ARCHIVE="$BUILD_DIR/Seshat.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
PLIST="$BUILD_DIR/exportOptions.plist"

echo "==> Generating project"
command -v xcodegen >/dev/null || { echo "xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

mkdir -p "$BUILD_DIR"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST

echo "==> Archiving ($EDITION)"
xcodebuild -project Seshat.xcodeproj -scheme Seshat -configuration Release \
  -xcconfig "$XCCONFIG" -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic archive

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" -exportPath "$EXPORT_DIR"

if [ "$EDITION" = "appstore" ]; then
  echo "==> App Store export ready in $EXPORT_DIR"
  echo "    Upload the .pkg with Transporter, or:"
  echo "    xcrun notarytool is NOT used for App Store; use:"
  echo "    xcrun altool --upload-app -t macos -f \"$EXPORT_DIR\"/*.pkg \\"
  echo "      --apple-id <id> --team-id $TEAM_ID --password <app-specific-pw>"
  exit 0
fi

: "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile) to notarize}"
APP="$EXPORT_DIR/Seshat.app"
ZIP="$BUILD_DIR/Seshat-$EDITION.zip"

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling + verifying"
xcrun stapler staple "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Fresh zip of the stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Done: $ZIP"
