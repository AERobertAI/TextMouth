# Team shell: windows, the app's shell, menus, and keys

Read `ios0-common.md` beside this file first: it is the pattern, and its rules override this charter. Your team is `shell`, your lead `shell-lead`, and your branch `team/shell`. Your files are listed in `files-shell.md` beside this file. They are the AppKit side of the app's frame: the delegate and its quit holds, the menus, the window router, the key handling and the shortcut model, and the views that are a window's root.

## Decisions already made

- **Move to `TextMouth/Platform/macOS/`, unchanged,** whatever only the Mac's windows, menus, and key events can ever use. Likely candidates:
  - App/AppDelegate.swift, App/MenuCommands.swift, App/UnsavedChangesTermination.swift;
  - Services/MenuVisibilityManager.swift, Services/ShortcutPressDispatcher.swift (the NSEvent monitor);
  - Views/SilentKeyEquivalent.swift, Views/SwitchedWindowFocus.swift, Views/LogsInFinder.swift;
  - Views/Reader/ReaderBookCommands.swift, if it holds only menu commands;
  - Views/Settings/KeyboardShortcutsSettingsView.swift, the Mac's Shortcuts tab.

  Before each move, grep for every name the file declares. Shared files that still use one get an iOS stand-in (ios0-common.md).
- **The window router (Services/LibraryWindowRouter.swift)** routes app-wide actions to AppKit windows. Move it unchanged. Give iOS a stand-in with exactly the members shared code uses (find them with grep, or with the census after the move): `shared`, and each method doing nothing or returning nil or false, each commented. The engine and a11y teams' view models and views call it, so the stand-in must keep every signature they use, with `PlatformWindow` where the Mac's takes `NSWindow`.
  - If the Mac's own signatures say `NSWindow`, you may change them to `PlatformWindow`; that is rule 3, and the Mac compiles the same.
- **The shortcut model (Models/KeyboardShortcut.swift) stays shared.** Its stored form is part of config.json, which both apps must read and write alike. Only its AppKit parts get `#if os(macOS)`: NSEvent's modifier flags and key codes, and the `NS…FunctionKey` constants.
  - If a stored field's type is AppKit's (`NSEvent.ModifierFlags`), keep the field. Give iOS an equivalent declaration (a struct or OptionSet of the same name and raw values) in a file of yours under `TextMouth/Platform/iOS/`, so the stored values mean the same.
  - The shortcuts' wording, the labels VoiceOver reads, stays exactly as it is on the Mac.
- **KeyboardShortcutManager** (an environment object every window gets) stays shared if its config mirror is shared code; its event monitoring goes behind `#if os(macOS)`. Decide from the file, and say why in your report.
- **The window-root views stay shared** (Views/ContentView.swift, Views/Library/LibraryView.swift, Views/Reader/BookReaderWindowView.swift, Views/Feeds/LibraryFeedsWindowSupport.swift, Views/Feeds/FeedCommandRunner.swift, Views/Settings/SettingsView.swift), so that phase 1 can start from them. Wrap their AppKit parts in place:
  - NSWindow lookups and window registration;
  - `onDeleteCommand`;
  - NSApp calls;
  - the checkbox style becomes `.checkboxToggleStyle()`.

  Move one only if, after the wrappers, nothing of it would be left for iOS. Say which, and why.
- Nothing about TextMouthApp: it is already in `Platform/macOS/App/`, and the iOS app has its own entry point.

## Tasks

About four tasks. For example:
1. the router and its stand-in;
2. the shortcut model and the manager;
3. the delegate, menus, termination, and the AppKit-only views;
4. the window-root views.

Order them so that a task whose stand-ins others need comes first, and integrate it before launching a task that depends on it.

## Tests to request from the train

The areas `shortcuts`, `windows`, `settings`, and `legacy` (MenuVisibilityTests, KeyboardShortcutTests). Add `library` and `feeds` for their window-root views. Request them once per integrated state, not once per commit.

## Watch for

- Five other teams change shared view models and views at the same time. If your stand-in's signature differs from what a shared file calls, their census shows it. Post the change to the orchestrator.
- `KeyboardReachabilityTests`, `ShortcutMigrationTests`, and the legacy scenarios pin the shortcuts' behavior. Run the `shortcuts` and `legacy` areas before you report.
