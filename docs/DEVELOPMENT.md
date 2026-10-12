# Development

## Browser sign-in (OAuth consumer)

"Sign in with Bitbucket" needs an OAuth consumer, set up once:

1. Create a workspace you own (a free one is fine; you only need admin on it):
   bitbucket.org → your avatar → **All workspaces** → **Create workspace**.
2. In that workspace: **Settings → Apps and features → OAuth consumers → Add consumer**.
   - Name: `PR Notify`
   - Callback URL: `http://localhost` (Bitbucket accepts any port for localhost)
   - Permissions: **Account: Read**, **Repositories: Read**, **Pull requests: Read**
3. Copy the **Key** and **Secret** into `oauth.env` in the repo root (git-ignored):

   ```sh
   BITBUCKET_OAUTH_KEY=...
   BITBUCKET_OAUTH_SECRET=...
   ```
4. Build with `./scripts/build-with-keys.sh`; it prints "OAuth sign-in enabled."
   Plain `./scripts/build-app.sh` ignores `oauth.env` and builds without the keys.

Bitbucket has no PKCE, so the secret is embedded in the built app. Keep that build
to yourself and share only one from `build-app.sh`: anyone with the app could
extract the secret and impersonate "PR Notify" on the consent screen, though it
grants no access to anyone's data on its own.

## Credentials

Saved to `~/Library/Application Support/PRNotify/credentials.json` with owner-only
permissions (like `gh` and `acli`). The Keychain isn't used because it re-prompts
after every rebuild of an ad-hoc-signed app.

## Build notes

- The macOS 27 SDK makes SwiftUI's `@State` a macro whose plugin ships only with
  Xcode, so the code uses `@ViewState` (an alias for the property wrapper).
- SwiftPM's default build backend fails under Command Line Tools, so the build
  script passes `--build-system native`.
