# Development

## Browser sign-in (OAuth consumer)

"Sign in with Bitbucket" needs an OAuth consumer, set up once:

1. Create a workspace you own (a free one is fine; you only need admin on it):
   bitbucket.org → your avatar → **All workspaces** → **Create workspace**.
2. In that workspace: **Settings → Apps and features → OAuth consumers → Add consumer**.
   - Name: `Bitbucket PR Notifier`
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
extract the secret and impersonate "Bitbucket PR Notifier" on the consent screen, though it
grants no access to anyone's data on its own.

## Credentials

Saved to `~/Library/Application Support/BitbucketPRNotifier/credentials.json` with owner-only
permissions (like `gh` and `acli`). The Keychain isn't used because it re-prompts
after every rebuild of an ad-hoc-signed app.

## Build notes

- The macOS 27 SDK makes SwiftUI's `@State` a macro whose plugin ships only with
  Xcode, so the code uses `@ViewState` (an alias for the property wrapper).
- SwiftPM's default build backend fails under Command Line Tools, so the build
  script passes `--build-system native`.

## End-to-end tests

```sh
./scripts/e2e.sh                         # all tests
./scripts/e2e.sh setAndCancelReminder    # just one
```

`Tests/E2E` launches the built app against a mock Bitbucket (and a mock GitHub
releases API) and drives it through the Accessibility API: sign-in, choosing a
repository, the menu bar menu, refreshing, reminders, sign-out and expired
tokens, and the update check. The app runs under its own bundle ID and support
folder, so a real install's settings and sign-in are untouched.

- The terminal needs **Accessibility** and **Screen Recording** access, and the
  screen must be unlocked; the tests take over the mouse focus while they run.
- The report goes to `build/e2e-report`: `index.html` with a screen recording
  per test (click a step's time to jump to it), `junit.xml`, and `summary.md`.
  A failed test also leaves `<test>.ax.txt`, what the app's windows showed.
- On every push to `main`, GitHub Actions runs each test as its own job (its own
  check) and attaches its report and recording as an artifact. The job's
  summary shows the recording as a GIF, kept on the `e2e-recordings/<test>`
  branch; each run replaces it, so only the latest run's GIF is kept.
- The app reads `BPRN_API_URL`, `BPRN_RELEASES_URL` and `BPRN_SUPPORT_DIR` only
  for these tests (`TestOverrides.swift`).

## Releasing

```sh
./scripts/release.sh          # next patch version: 1.0.0 -> 1.0.1
./scripts/release.sh 1.2.0    # or a version of your choice (must be newer)
```

It writes the version to `Info.plist`, builds without OAuth keys, commits and
tags `v<version>`, pushes, and publishes a GitHub release with
`Bitbucket-PR-Notifier.zip` and generated notes. Run it from a clean `main`. The
app's update check compares its version with the latest release's tag, so always
release through this script.
