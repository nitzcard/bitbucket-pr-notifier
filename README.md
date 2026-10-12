# PR Notify

A macOS menu bar app that tells you when a Bitbucket pull request is waiting for
your review, and reminds you until you get to it.

<p>
  <img src="docs/menu.png" alt="Menu bar menu listing pull requests" width="480">
  <img src="docs/window.png" alt="PR Notify window listing pull requests" width="340">
</p>

- See every open PR where you're a reviewer, with your comments and approvals.
- Get a notification as soon as a new one is assigned to you.
- **Remind Me…** about a PR at a set time, or nag every few minutes until you review it.

## Install

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./scripts/build-app.sh
open "build/PR Notify.app"
```

Drag `build/PR Notify.app` to `/Applications` to keep it. If you got a zipped copy
from a teammate instead, run this once so macOS lets it open:

```sh
xattr -dr com.apple.quarantine "/Applications/PR Notify.app"
```

## Sign in

### With an API token (recommended)

1. Open [Atlassian API tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
   → **Create API token with scopes** → **Bitbucket**.
2. Tick these scopes: `read:user:bitbucket`, `read:workspace:bitbucket`,
   `read:repository:bitbucket`, `read:pullrequest:bitbucket`.
3. In PR Notify → **Settings…**, enter your Atlassian email and the token, then pick a repository.

The token is saved on your Mac, readable only by your user account. When it
expires, PR Notify asks you to sign in again.

### With your browser

**Sign in with Bitbucket** appears in Settings only in builds made with an OAuth
consumer; see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
