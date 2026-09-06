#!/usr/bin/env bash
#
# Build, sign, and (for Direct/Setapp) notarize a Distavo edition.
# Companion to ../../docs/distribution-checklist.md.
#
# Usage:
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=distavo-notary \
#     ./build-and-notarize.sh direct        # -> notarized, stapled .app + .zip
#   TEAM_ID=... NOTARY_PROFILE=... ./build-and-notarize.sh setapp
#   TEAM_ID=... ./build-and-notarize.sh appstore  # -> .pkg for App Store upload
#
# Prereqs (one-time, see the checklist):
#   - "Developer ID Application" cert in the login keychain (direct/setapp)
#   - "Apple Distribution" cert + Mac App Store provisioning profile (appstore)
#   - notarytool keychain profile:
#       xcrun notarytool store-credentials distavo-notary \
#         --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
set -Eeuo pipefail

cd "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

EDITION="${1:-}"
: "${TEAM_ID:?set TEAM_ID to your 10-char Apple Team ID}"

# Each edition is its OWN target with its own configFiles/INFOPLIST_FILE in
# project.yml. A target-level xcconfig outranks a project-level command-line
# -xcconfig, so building every edition from `-scheme Distavo` would silently
# produce the Direct target (bundle id, Sparkle, donate link and all) whatever
# xcconfig was passed. Always select the edition by SCHEME + CONFIGURATION.
case "$EDITION" in
  direct)   SCHEME="Distavo";          CONFIG="Release";           METHOD="developer-id" ;;
  setapp)   SCHEME="Distavo-Setapp";   CONFIG="Release";           METHOD="developer-id" ;;
  appstore) SCHEME="Distavo-AppStore"; CONFIG="Release-AppStore";  METHOD="app-store-connect" ;;
  *) echo "usage: $0 {direct|setapp|appstore}" >&2; exit 2 ;;
esac

BUILD_DIR="build/release-$EDITION"
ARCHIVE="$BUILD_DIR/Distavo.xcarchive"
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
xcodebuild -project Distavo.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic archive

# Assert the archive really is the edition that was asked for. The bug this
# guards against is silent: a wrong scheme still builds, signs and notarizes
# cleanly, and is only caught by a Setapp/App Review rejection days later.
verify_edition() {
  local -r app="$ARCHIVE/Products/Applications/Distavo.app"
  local -r plist="$app/Contents/Info.plist"
  local expect_id want_sparkle

  [[ -f "$plist" ]] || { echo "missing archived Info.plist: $plist" >&2; return 1; }

  case "$EDITION" in
    direct)   expect_id="uk.co.riera.distavo";        want_sparkle=yes ;;
    setapp)   expect_id="uk.co.riera.distavo-setapp"; want_sparkle=no  ;;
    appstore) expect_id="uk.co.riera.distavo";        want_sparkle=no  ;;
  esac

  local -r got_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  [[ "$got_id" == "$expect_id" ]] || {
    echo "edition mismatch: built bundle id '$got_id', expected '$expect_id' for $EDITION" >&2
    return 1
  }

  # Sparkle must link into Direct ONLY (App Store forbids third-party updaters;
  # Setapp ships its own). Its presence/absence is the cheapest edition tell.
  local has_sparkle=no
  [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] && has_sparkle=yes
  [[ "$has_sparkle" == "$want_sparkle" ]] || {
    echo "edition mismatch: Sparkle.framework present=$has_sparkle, expected $want_sparkle for $EDITION" >&2
    return 1
  }

  # The donate link is Direct-only (App Review 3.1.1 / Setapp both forbid it).
  if [[ "$EDITION" != "direct" ]] && grep -qa "DONATE_ENABLED" "$app/Contents/MacOS/Distavo" 2>/dev/null; then
    echo "edition mismatch: DONATE_ENABLED found in the $EDITION binary" >&2
    return 1
  fi

  echo "    verified: $got_id, Sparkle=$has_sparkle"
}

echo "==> Verifying edition ($EDITION)"
verify_edition

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" -exportPath "$EXPORT_DIR"

if [ "$EDITION" = "appstore" ]; then
  echo "==> App Store export ready in $EXPORT_DIR"
  echo "    Upload to App Store Connect with the App Store Connect API key:"
  echo "      xcrun altool --upload-app -t macos -f \"$EXPORT_DIR\"/*.pkg \\"
  echo "        --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
  echo "    (or drag the .pkg into Transporter.app). CI does this unattended —"
  echo "    see .github/workflows/release-appstore.yml and docs/release-automation.md."
  exit 0
fi

: "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile) to notarize}"
APP="$EXPORT_DIR/Distavo.app"
ZIP="$BUILD_DIR/Distavo-$EDITION.zip"
NOTARY_ZIP="$BUILD_DIR/Distavo-$EDITION-notary.zip"

package_distribution_zip() {
  local -r app="$1"
  local -r zip="$2"

  rm -f -- "$zip"

  if [[ "$EDITION" == "setapp" ]]; then
    local -r package_root="$BUILD_DIR/setapp-package"
    local -r icon_source="Resources/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png"

    [[ -d "$app" ]] || { echo "missing app bundle: $app" >&2; return 1; }
    [[ -f "$icon_source" ]] || { echo "missing Setapp AppIcon.png source: $icon_source" >&2; return 1; }

    rm -rf -- "$package_root"
    mkdir -p -- "$package_root"
    ditto "$app" "$package_root/Distavo.app"
    cp "$icon_source" "$package_root/AppIcon.png"
    ditto -c -k "$package_root" "$zip"
    return 0
  fi

  ditto -c -k --keepParent "$app" "$zip"
}

echo "==> Notarizing"
rm -f -- "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling + verifying"
xcrun stapler staple "$APP"
# Apple discourages --deep for verification; verify the app, then assess Gatekeeper.
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Fresh zip of the stapled app for distribution.
package_distribution_zip "$APP" "$ZIP"
echo "==> Done: $ZIP"
