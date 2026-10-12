# PR Notify

A tiny macOS menu bar + Dock app that lists open Bitbucket Cloud pull requests
where you're a reviewer, and notifies you when new ones show up.

- Watches **one repository**, polled every 60 seconds (Bitbucket has no push events for desktop apps).
- Menu bar: grayscale icon + count. Dock: color icon + red badge. Both show the same list.
- One new PR → notification that opens the PR. Several at once → one grouped notification that opens the window.
- First launch and switching repos are silent.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode not needed).

```sh
./scripts/build-app.sh
open "build/PR Notify.app"
```

Copy `build/PR Notify.app` to `/Applications` if you want to keep it.

## Sign in

### Option A: Sign in with Bitbucket (browser)

Shown only when the app was built with an OAuth consumer. One person sets this up once:

1. Create a workspace you own (it can be a free one; you only need admin on it):
   bitbucket.org → your avatar → **All workspaces** → **Create workspace**.
2. In that workspace: **Settings → Apps and features → OAuth consumers → Add consumer**.
   - Name: `PR Notify`
   - Callback URL: `http://localhost` (Bitbucket accepts any port for localhost)
   - Permissions: **Account: Read**, **Repositories: Read**, **Pull requests: Read**
3. Copy the **Key** and **Secret** into `oauth.env` next to this README (git-ignored):

   ```sh
   BITBUCKET_OAUTH_KEY=...
   BITBUCKET_OAUTH_SECRET=...
   ```
4. Run `./scripts/build-with-keys.sh`; it prints "OAuth sign-in enabled."
   Plain `./scripts/build-app.sh` ignores `oauth.env` and builds without the keys.

Bitbucket has no PKCE, so the secret is embedded in the built app; keep that build
to yourself and share only one from `build-app.sh`. Anyone with the app could
extract it and impersonate "PR Notify" on the consent screen, but it
grants no access to anyone's data on its own.

### Option B: API token

1. Go to <https://id.atlassian.com/manage-profile/security/api-tokens> →
   **Create API token with scopes** → **Bitbucket**.
2. Grant these read scopes: `read:user:bitbucket`, `read:workspace:bitbucket`,
   `read:repository:bitbucket`, `read:pullrequest:bitbucket`.
3. In PR Notify → Settings, enter your Atlassian email and the token, then pick a repository.

Credentials are saved to `~/Library/Application Support/PRNotify/credentials.json`
with owner-only permissions (like `gh` and `acli`). The Keychain isn't used because
it re-prompts after every rebuild of an ad-hoc-signed app. Tokens expire (max 1
year); when it does, the app shows "Sign in" again.

## Sharing with teammates

The app is ad-hoc signed, not notarized. After downloading a zipped build, run:

```sh
xattr -dr com.apple.quarantine "/Applications/PR Notify.app"
```

## Notes

- The macOS 27 SDK makes SwiftUI's `@State` a macro whose plugin ships only with
  Xcode, so the code uses `@ViewState` (an alias for the property wrapper).
- SwiftPM's default build backend fails under Command Line Tools, so the build
  script passes `--build-system native`.
