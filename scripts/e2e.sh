#!/bin/bash
# Runs the end-to-end tests: ./scripts/e2e.sh [test name…]
# Builds the app, copies it under a test bundle ID (its own settings, apart
# from a real install's), and drives it against a mock Bitbucket. Needs
# Accessibility and Screen Recording access for the terminal. Writes
# build/e2e-report: index.html (with a recording per test), junit.xml, summary.md.
set -euo pipefail
cd "$(dirname "$0")/.."

env -u BITBUCKET_OAUTH_KEY -u BITBUCKET_OAUTH_SECRET ./scripts/build-app.sh

APP="build/e2e/Bitbucket PR Notifier E2E.app"
rm -rf build/e2e build/e2e-report
mkdir -p build/e2e
cp -R "build/Bitbucket PR Notifier.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.bitbucketprnotifier.e2e" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

swift build -c release --build-system native --product BitbucketPRNotifierE2E \
    2> >(grep -v "'--build-system native' has been deprecated" >&2)
BIN="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/BitbucketPRNotifierE2E"
"$BIN" --app "$APP" --out build/e2e-report "$@"
