#!/bin/bash
# Builds "build/PR Notify.app" with only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PR Notify.app"

# The default (swift-build) backend fails under Command Line Tools; use the native one.
swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/PRNotify"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRNotify"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Optional "Sign in with Bitbucket": consumer key/secret from the environment
# (scripts/build-with-keys.sh sets them from oauth.env). Without them only
# API-token sign-in shows, and the app is safe to share.
if [ -n "${BITBUCKET_OAUTH_KEY:-}" ] && [ -n "${BITBUCKET_OAUTH_SECRET:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :PRNOAuthClientID string $BITBUCKET_OAUTH_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :PRNOAuthClientSecret string $BITBUCKET_OAUTH_SECRET" "$APP/Contents/Info.plist"
    echo "OAuth sign-in enabled."
else
    echo "OAuth sign-in disabled (no BITBUCKET_OAUTH_KEY / BITBUCKET_OAUTH_SECRET)."
fi

"$BIN" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for notifications and the Keychain on this Mac.
codesign --force --sign - "$APP"

echo "Built $APP"
