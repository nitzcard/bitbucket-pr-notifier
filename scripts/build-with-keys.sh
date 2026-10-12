#!/bin/bash
# Development build with "Sign in with Bitbucket": embeds the OAuth consumer
# key/secret from the git-ignored oauth.env (see README). Don't share this app;
# the secret can be read from it. For a shareable build use build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f oauth.env ]; then
    echo "oauth.env not found. Create it with BITBUCKET_OAUTH_KEY and BITBUCKET_OAUTH_SECRET (see README)." >&2
    exit 1
fi
set -a
source oauth.env
set +a
if [ -z "${BITBUCKET_OAUTH_KEY:-}" ] || [ -z "${BITBUCKET_OAUTH_SECRET:-}" ]; then
    echo "oauth.env must set both BITBUCKET_OAUTH_KEY and BITBUCKET_OAUTH_SECRET." >&2
    exit 1
fi

exec ./scripts/build-app.sh
