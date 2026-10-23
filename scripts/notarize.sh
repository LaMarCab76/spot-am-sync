#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_DIR/build/SpotAM Sync.app"
ARCHIVE="$REPO_DIR/build/SpotAM-Sync.zip"
: "${NOTARY_PROFILE:?Definí NOTARY_PROFILE con el nombre de un perfil de notarytool guardado en Keychain.}"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
/usr/sbin/spctl --assess --type execute --verbose "$APP_DIR"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
printf 'Paquete notarizado: %s\n' "$ARCHIVE"
