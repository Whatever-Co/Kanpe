#!/bin/bash
# Build, notarize and publish a Kanpe release that Sparkle picks up.
#
#   scripts/release.sh 0.2.0
#
# Needs, once per Mac:
#   - "Developer ID Application: Whatever Co. (G5G54TCH8W)" in the login keychain
#   - a notarytool profile for team G5G54TCH8W (xcrun notarytool store-credentials),
#     named "notarytool-profile" unless NOTARY_PROFILE says otherwise
#     (override the name with NOTARY_PROFILE)
#   - the Sparkle EdDSA private key in the login keychain, account co.whatever.Kanpe
#     (generate_keys --account co.whatever.Kanpe -x / -f to export / import it)
#
# The appcast lists only this release and is attached to it; SUFeedURL points at
# releases/latest/download/appcast.xml, so the newest release is what clients see.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}
NOTARY_PROFILE=${NOTARY_PROFILE:-notarytool-profile}
SPARKLE_ACCOUNT=co.whatever.Kanpe
REPO=Whatever-Co/Kanpe
TAG="v$VERSION"

cd "$(dirname "$0")/.."

if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "error: uncommitted changes" >&2; exit 1
fi
git fetch -q origin master
if [[ $(git rev-parse HEAD) != $(git rev-parse origin/master) ]]; then
  echo "error: HEAD is not origin/master; release from a pushed master" >&2; exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2; exit 1
fi

# CFBundleVersion must grow with every release; Sparkle compares it.
BUILD=$(git rev-list --count HEAD)
OUT=build/release/$VERSION
rm -rf "$OUT"
mkdir -p "$OUT/dist"

xcodegen generate
xcodebuild -project Kanpe.xcodeproj -scheme Kanpe -configuration Release \
  -derivedDataPath build -archivePath "$OUT/Kanpe.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>G5G54TCH8W</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Kanpe.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"

APP="$OUT/export/Kanpe.app"
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

ZIP="$OUT/dist/Kanpe-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  "$OUT/dist"

gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Kanpe $VERSION" --generate-notes \
  "$ZIP" "$OUT/dist/appcast.xml"

echo "Released $TAG (build $BUILD)"
