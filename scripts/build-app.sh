#!/bin/bash
# Builds "build/Bitbucket PR Notifier.app" with only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Bitbucket PR Notifier.app"

# The default (swift-build) backend fails under Command Line Tools ("Unknown error
# parsing property list" as of Swift 6.4), so use the native one and hide its
# deprecation warning. Retry the default when the toolchain updates.
swift_build() {
    swift build -c release --build-system native "$@" \
        2> >(grep -v "'--build-system native' has been deprecated" >&2)
}
swift_build
BIN="$(swift_build --show-bin-path)/BitbucketPRNotifier"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BitbucketPRNotifier"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Optional "Sign in with Bitbucket": consumer key/secret from the environment
# (scripts/build-with-keys.sh sets them from oauth.env). Without them only
# API-token sign-in shows, and the app is safe to share.
if [ -n "${BITBUCKET_OAUTH_KEY:-}" ] && [ -n "${BITBUCKET_OAUTH_SECRET:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :BPRNOAuthClientID string $BITBUCKET_OAUTH_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :BPRNOAuthClientSecret string $BITBUCKET_OAUTH_SECRET" "$APP/Contents/Info.plist"
    echo "OAuth sign-in enabled."
else
    echo "OAuth sign-in disabled (no BITBUCKET_OAUTH_KEY / BITBUCKET_OAUTH_SECRET)."
fi

"$BIN" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for notifications and the Keychain on this Mac.
codesign --force --sign - "$APP"

echo "Built $APP"
