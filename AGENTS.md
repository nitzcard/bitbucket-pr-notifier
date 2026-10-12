# Working agreement

## UI follows the 1987 Apple Human Interface Guidelines

Design every window, dialog and menu by the original Apple *Human Interface Guidelines* (1987), unless the user asks for something different. When the user's request conflicts with them, do what the user asked and point out the conflict.

Dialogs:
- Each label sits directly beside its control: right-aligned labels ending in a colon, with left-aligned controls immediately after.
- Mutually exclusive options are radio buttons, all visible. Controls belonging to an unselected option are dimmed, not hidden.
- The default button is at the bottom right, with Cancel to its left. A destructive action (e.g. Cancel Reminder) is at the bottom left, set apart.
- Windows fit their content snugly, with no empty space below or beside the controls. Keep the layout fixed: when content appears and disappears, the window resizes, and that can crash (see Build gotchas).

Menus:
- Items are verbs or attributes in title case.
- Item names stay fixed. An item that can't apply right now is dimmed.
- A trailing "…" only on items that ask for more input before acting.
- Related items are grouped between separators; Quit comes last.
- Keyboard equivalents are only for frequent commands. Keep the standard ones (⌘Q, ⌘O, ⌘,) for their standard meanings.

## Build gotchas (Command Line Tools, no Xcode)

- Use `@ViewState` (alias of SwiftUI's `State` wrapper). The `@State` macro's plugin ships only with Xcode.
- Build with `./scripts/build-with-keys.sh` while developing. It embeds the OAuth keys from `oauth.env` so browser sign-in works, then runs `build-app.sh` (which passes `--build-system native`). If `oauth.env` is missing, build with `./scripts/build-app.sh` and tell the user browser sign-in is off in that build.
- An `NSHostingController` with `.preferredContentSize` crashes when its content changes size during the window's first layout. For such windows, give them a fixed size (`fitsContent: false` in `WindowManager`).
