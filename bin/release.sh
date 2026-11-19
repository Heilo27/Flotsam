#!/usr/bin/env bash
# One-command release: Release build -> sign -> DMG -> notarize + staple -> SHA-256 (FRD-009). Output in ./dist.
# Credentials never live in the repo. Identity: FLOTSAM_SIGN_IDENTITY, else the keychain's "Developer ID Application".
# Notary: keychain profile only, FLOTSAM_NOTARY_PROFILE (default "flotsam"). No password is ever passed on argv (visible to ps).
# Missing either one -> ad-hoc signed, un-notarized DMG (local testing only) and a list of exactly what is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BLD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
# The helper's signing identifier is the one project.yml gives its target: read here, not repeated (FR-009-02).
HELPER_ID=$(awk '/^  flotsam-mcp:/{t=1;next} t&&/^  [^ ]/{t=0} t&&/PRODUCT_BUNDLE_IDENTIFIER:/{print $2; exit}' project.yml)
[ -n "$HELPER_ID" ] || { echo "project.yml: flotsam-mcp PRODUCT_BUNDLE_IDENTIFIER not found" >&2; exit 1; }
[ -n "$VER" ] && [ -n "$BLD" ] || { echo "project.yml: CFBundleShortVersionString/CFBundleVersion not found" >&2; exit 1; }
DD=build/release; APP=$DD/Build/Products/Release/Flotsam.app
DMG=dist/Flotsam-$VER.dmg
ID=${FLOTSAM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
PROFILE=${FLOTSAM_NOTARY_PROFILE:-flotsam}
missing=()
[ -n "$ID" ] || missing+=("Developer ID Application certificate (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)")
notary=()
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  notary=(--keychain-profile "$PROFILE")
else
  missing+=("notarytool keychain profile \"$PROFILE\" not found or unusable: run xcrun notarytool store-credentials $PROFILE (prompts for Apple ID, app-specific password and team ID; stored in the keychain)")
fi
SIGN=(--force --options runtime)  # shared by the helper and the app
if [ ${#missing[@]} -eq 0 ]; then SIGN+=(--timestamp --sign "$ID"); else
  SIGN+=(--sign -); printf 'AD-HOC BUILD (not distributable). Missing:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2; fi

mkdir -p "$DD"
xcodegen generate --quiet --spec project.yml  # xcodebuild resolves packages itself
xcodebuild -project Flotsam.xcodeproj -scheme Flotsam -configuration Release -derivedDataPath "$DD" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build >"$DD.log" 2>&1 || { tail -30 "$DD.log" >&2; exit 1; }
# Inside-out (FR-009-02, AC-009-15): the embedded helper is signed explicitly, first, with the hardened runtime and a
# secure timestamp, under its own identifier. Signing the app afterwards seals it into the app's resources; `--deep` is
# not relied on to reach it. The helper needs no entitlements: it only relays bytes to a socket.
HELPER="$APP/Contents/MacOS/flotsam-mcp"
[ -f "$HELPER" ] || { echo "embedded helper not found: $HELPER" >&2; exit 1; }
codesign "${SIGN[@]}" --identifier "$HELPER_ID" "$HELPER"
codesign --verify --strict "$HELPER"
codesign "${SIGN[@]}" --entitlements App/Flotsam/Flotsam.entitlements "$APP"
codesign --verify --deep --strict "$APP"

rm -rf dist/stage dist/Flotsam-*.dmg dist/Flotsam-*.dmg.sha256; mkdir -p dist/stage
cp -R "$APP" dist/stage/; ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname "Flotsam $VER" -srcfolder dist/stage -format UDZO -ov "$DMG"
rm -rf dist/stage
if [ ${#missing[@]} -eq 0 ]; then
  codesign --force --timestamp --sign "$ID" "$DMG"
  xcrun notarytool submit "$DMG" "${notary[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "Flotsam $VER (build $BLD): $DMG"
