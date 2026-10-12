#!/bin/bash
# Publishes a GitHub release: ./scripts/release.sh [version]
# Without a version, releases the next patch after Info.plist's (1.0.0 -> 1.0.1).
# Writes the version to Info.plist, builds without OAuth keys
# (safe to share), commits and tags "v<version>", pushes, and uploads the zipped
# app. The app's update check looks for these tags.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
ZIP=build/Bitbucket-PR-Notifier.zip
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
released() { git ls-remote --exit-code --tags origin "refs/tags/v$1" >/dev/null; }

# Default: the next patch version (1.0.0 -> 1.0.1).
VERSION="${1:-${CURRENT%.*}.$((${CURRENT##*.} + 1))}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 [version], e.g. $0 1.0.1" >&2
    exit 1
fi
if released "$VERSION"; then
    echo "v$VERSION is already released." >&2
    exit 1
fi
if [ "$CURRENT" = "$VERSION" ] || [ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
    echo "Version $VERSION must be newer than the current $CURRENT." >&2
    exit 1
fi
echo "Releasing v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi
if [ "$(git branch --show-current)" != main ]; then
    echo "Release from main." >&2
    exit 1
fi

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
git commit -q -m "Release v$VERSION" -- "$PLIST"

# Never ship the OAuth secret, even if it's in this shell's environment.
env -u BITBUCKET_OAUTH_KEY -u BITBUCKET_OAUTH_SECRET ./scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent "build/Bitbucket PR Notifier.app" "$ZIP"

git tag "v$VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "v$VERSION" --generate-notes
