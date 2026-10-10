#!/bin/bash
# Builds a release zip, signs it for Sparkle, and publishes it as a GitHub Release with an
# appcast.xml attached. Installed copies find it through SUFeedURL in Info.plist, which
# points at releases/latest/download/appcast.xml, so the newest release is always the feed.
#
#   Scripts/release.sh 0.2.0
#
# Needs: a clean main that matches origin, `gh` logged in, and the Sparkle signing key in
# the login keychain (made once with Sparkle's generate_keys; back it up with
# `generate_keys -x <file>` — without it, installed copies can't be updated).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version, e.g. 0.2.0>}"
TAG="v$VERSION"
REPO="obattisha/whisper-keyboard"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: uncommitted changes" >&2
    exit 1
fi
git fetch -q --tags origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "error: HEAD isn't origin/main; push or pull first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: $TAG already exists" >&2
    exit 1
fi

# Sparkle decides "newer" by CFBundleVersion, so it has to only ever go up. The commit
# count on main does.
BUILD_NUMBER=$(git rev-list --count HEAD)
OUT="build/release/$TAG"
DERIVED="build/DerivedData"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building $VERSION ($BUILD_NUMBER)..."
xcodebuild -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build 2>&1 | grep -E "warning:|error:|BUILD SUCCEEDED|BUILD FAILED" | grep -v appintentsmetadataprocessor
APP="$DERIVED/Build/Products/Release/WhisperKeyboard.app"
[[ -d "$APP" ]] || { echo "error: build produced no app" >&2; exit 1; }

# A zip, not a DMG: on this Mac `hdiutil create`/`convert` fail ("Permission denied" /
# "Resource temporarily unavailable") even outside any sandbox, and the `makehybrid`
# workaround adds Finder info that breaks the app's code signature once it's copied out.
# ditto keeps the signature intact, Sparkle installs from zips natively, and Safari unzips
# on download.
echo "Zipping..."
ZIP_NAME="WhisperKeyboard-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Signing for Sparkle..."
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
SPARKLE_SIG=$("$SIGN_UPDATE" "$ZIP")

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log --no-merges --format='%s' "$PREV_TAG..HEAD")
else
    CHANGES="First release"
fi
CHANGES_HTML=$(printf '%s\n' "$CHANGES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|')
CHANGES_MD=$(printf '%s\n' "$CHANGES" | sed 's/^/- /')

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>whisper-keyboard</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.3</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$CHANGES_HTML
</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME" $SPARKLE_SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

NOTES="$CHANGES_MD

**Install:** download the zip (Safari unzips it) and drag WhisperKeyboard into Applications. The app isn't notarized, so the first time you open it macOS will block it: go to System Settings → Privacy & Security and click **Open Anyway**. Later versions install from the app's Check for Updates menu item."

echo "Publishing $TAG..."
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --target main \
    --title "$VERSION" --notes "$NOTES"
git fetch -q --tags origin
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
