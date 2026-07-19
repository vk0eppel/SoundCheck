#!/usr/bin/env bash
#
# Cut a signed SoundCheck release locally.
#
# Unlike a plain `xcodebuild ... CODE_SIGNING_ALLOWED=NO` CI build (which is
# ad-hoc/unsigned and hits Gatekeeper's hard "cannot verify developer" block),
# this signs the app with the local Apple *Development* identity + hardened
# runtime, matching how FreqTrace is cut. Result: the downloaded .app opens on
# machines that trust this cert (yours + registered Macs) with only the soft
# "downloaded from the internet" prompt -- no `xattr`/right-click dance.
#
# NOT notarized (that needs a paid Developer ID). So it still won't open
# friction-free for the general public -- see the release note below.
#
# Usage:  scripts/release.sh v0.2.0 [--publish]
#   without --publish: builds + zips into ./dist, does not touch GitHub
#   with    --publish: also `gh release create`/uploads the signed zip
#
set -euo pipefail

TAG="${1:?usage: scripts/release.sh vX.Y.Z [--publish]}"
PUBLISH="${2:-}"
VERSION="${TAG#v}"

IDENTITY="Apple Development: vkoeppel@gmail.com (TTT95N68D9)"
TEAM="VJG34543FT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build_release"
DIST="$ROOT/dist"
ZIP="$DIST/SoundCheck-$TAG.zip"

echo "==> Building signed Release for $TAG (MARKETING_VERSION=$VERSION)"
rm -rf "$BUILD"
xcodebuild -project "$ROOT/SoundCheck.xcodeproj" -scheme SoundCheck \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ENABLE_HARDENED_RUNTIME=YES \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-list --count HEAD)" \
  build

APP="$BUILD/Build/Products/Release/SoundCheck.app"
echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Zipping -> $ZIP"
mkdir -p "$DIST"; rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$PUBLISH" == "--publish" ]]; then
  echo "==> Publishing GitHub release $TAG"
  NOTE=$'Signed with an Apple Development certificate (not notarized). Opens cleanly on Macs that trust this developer.\nOn an unrecognized Mac, first launch: right-click `SoundCheck.app` > **Open** > **Open**.'
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
  else
    gh release create "$TAG" "$ZIP" --title "$TAG" --generate-notes --notes "$NOTE"
  fi
fi

echo "==> Done: $ZIP"
