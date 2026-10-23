#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
APP_DIR="$BUILD_DIR/SpotAM Sync.app"
CONFIGURATION="${CONFIGURATION:-release}"
DEBUG_INFO_FORMAT="${DEBUG_INFO_FORMAT:-none}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.lamarcab.spotamsync}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ ! "$APP_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    printf '%s\n' 'APP_BUNDLE_ID no es un identificador de aplicación válido.' >&2
    exit 1
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$REPO_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_DIR/.build/ModuleCache"

cd "$REPO_DIR"
mkdir -p "$BUILD_DIR" "$REPO_DIR/.build/typecheck"
swift build --disable-sandbox --configuration "$CONFIGURATION" -debug-info-format "$DEBUG_INFO_FORMAT" --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security
BIN_DIR="$(swift build --disable-sandbox --configuration "$CONFIGURATION" --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)"

# Only replace the generated bundle in this repository; installed apps and user data are untouched.
STAGING_APP="$BUILD_DIR/.SpotAM-Sync-staging.app"
if [ -d "$STAGING_APP" ]; then /bin/rm -rf "$STAGING_APP"; fi
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
/usr/bin/ditto "$BIN_DIR/SpotAMSync" "$STAGING_APP/Contents/MacOS/SpotAMSync"
/usr/bin/ditto Resources/Info.plist "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGING_APP/Contents/Info.plist"

swift scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset" "$STAGING_APP/Contents/Resources/AppIcon.icns"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    # MusicKit is an App Service associated with a registered App ID; an ad hoc
    # signature has no developer team and cannot establish that association.
    /usr/bin/codesign --force --sign - "$STAGING_APP"
else
    # No invented MusicKit entitlement: enable it under App Services in the portal.
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$STAGING_APP"
fi
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"
if [ -d "$APP_DIR" ]; then /bin/rm -rf "$APP_DIR"; fi
/bin/mv "$STAGING_APP" "$APP_DIR"
printf 'App creada: %s\n' "$APP_DIR"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    printf '%s\n' 'Firma local ad hoc: demostración y Spotify disponibles; Apple Music requiere configurar firma, App ID y MusicKit.'
fi
