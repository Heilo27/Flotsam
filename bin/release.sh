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
[ -e "/Volumes/Flotsam $VER" ] && { echo "A volume named \"Flotsam $VER\" is mounted; eject it (or wait for the other release run) and retry" >&2; exit 1; }  # FR-009-12
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
# Explicit create/attach/copy/convert instead of `hdiutil create -srcfolder`: its internal detach has no
# fallback and fails "Resource busy" while CoreSimulator is shutting simulators down (shared Mac).
fail() { echo "DMG step failed: $1" >&2; [ -n "${DEV:-}" ] && { diskutil unmountDisk force "$DEV" >/dev/null 2>&1 || true; diskutil eject "$DEV" >/dev/null 2>&1 || true; }; rm -rf dist/stage dist/rw.dmg; exit 1; }
DEV=; RW=dist/rw.dmg; SZ=$(( $(du -sm dist/stage | cut -f1) + 20 ))
hdiutil create -quiet -size "${SZ}m" -fs HFS+ -volname "Flotsam $VER" -ov "$RW" || fail "create blank image"
ATT=$(hdiutil attach -nobrowse -noautoopen -noverify "$RW") || fail "attach $RW"
DEV=$(printf '%s\n' "$ATT" | awk 'NR==1{print $1}'); MNT=$(printf '%s\n' "$ATT" | awk -F'\t' '/\/Volumes\//{print $NF}')
[ -n "$DEV" ] && [ -n "$MNT" ] || fail "attach $RW (no device or mount point)"
ditto dist/stage "$MNT" || fail "copy app into image"
for i in 1 2 3 4 5; do diskutil eject "$DEV" >/dev/null 2>&1 && break; sleep 3; done
if hdiutil info | grep -qF "$PWD/$RW"; then
  diskutil unmountDisk force "$DEV" >/dev/null 2>&1 || true; diskutil eject "$DEV" >/dev/null || fail "eject $DEV"; fi
DEV=; hdiutil convert -quiet "$RW" -format UDZO -ov -o "$DMG" || fail "compress to $DMG"
rm -rf dist/stage "$RW"
if [ ${#missing[@]} -eq 0 ]; then
  codesign --force --timestamp --sign "$ID" "$DMG"
  xcrun notarytool submit "$DMG" "${notary[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "Flotsam $VER (build $BLD): $DMG"
