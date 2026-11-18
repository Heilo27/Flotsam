#!/usr/bin/env bash
# One-command release: Release build -> sign -> DMG -> notarize + staple -> SHA-256 (FRD-009). Output in ./dist.
# Credentials never live in the repo. Identity: FLOTSAM_SIGN_IDENTITY, else the keychain's "Developer ID Application".
# Notary: keychain profile only, FLOTSAM_NOTARY_PROFILE (default "flotsam"). No password is ever passed on argv (visible to ps).
# Missing either one -> ad-hoc signed, un-notarized DMG (local testing only) and a list of exactly what is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BLD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
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
SIGN=(--force --options runtime --entitlements App/Flotsam/Flotsam.entitlements)
if [ ${#missing[@]} -eq 0 ]; then SIGN+=(--timestamp --sign "$ID"); else
  SIGN+=(--sign -); printf 'AD-HOC BUILD (not distributable). Missing:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2; fi

mkdir -p "$DD"
xcodegen generate --quiet --spec project.yml  # xcodebuild resolves packages itself
xcodebuild -project Flotsam.xcodeproj -scheme Flotsam -configuration Release -derivedDataPath "$DD" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build >"$DD.log" 2>&1 || { tail -30 "$DD.log" >&2; exit 1; }
codesign "${SIGN[@]}" "$APP"
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
