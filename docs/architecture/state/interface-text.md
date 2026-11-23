# Interface text and the interface language
<!-- id: interface-text-page; keys: InterfaceText, InterfaceLanguage, Strings.pack, interface text state, language switch, FR39; src: TextMouth/Localization/InterfaceText/InterfaceTextEngine.swift, TextMouth/Localization/InterfaceText/InterfaceLanguage.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

How to write a line, and the tools that keep the catalog, are in [Localizing TextMouth's code](../../developer/localization.md); this page says who owns the state.

## The lookup of a line
<!-- id: interface-text-engine-state; keys: InterfaceTextEngine.shared, Strings.pack, pack, lookup, fallback to English, INTERFACE_TEXT_PROBLEM, reportProblemsToDiagnosticLog; src: TextMouth/Localization/InterfaceText/InterfaceTextEngine.swift, TextMouth/Localization/InterfaceText/InterfaceTextLine.swift, TextMouth/Localization/InterfaceText/InterfaceTextPack.swift, TextMouth/Localization/InterfaceText/InterfaceTextTables.swift, TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/Platform/iOS/App/TextMouthAppDelegate.swift -->

The interface's words.

- Owner: InterfaceTextEngine.shared, one engine for the process, which InterfaceText.line asks.
  It opens the app's Strings.pack at the first lookup (InterfaceTextPack.inMainBundle, memory-mapped).
  It keeps the decoded ID list, each language's decoded entries once that language is asked for, the verdict of the specifier check for each entry, and the problems already reported, all behind one lock.
- Who may write it: only the engine, which fills its own caches.
  The pack is read-only.
  A test makes an engine of its own over tables in memory (InterfaceTextTables), or over a pack file.
- How others observe it: they don't; a call returns a String, and is safe on any thread.
  It never traps: with no pack, no entry for the ID in the language, or a text that fails its check, the line shows the English the call holds.
- Problems: the engine reports each once, in English, to the hook the app sets.
  Both apps call InterfaceText.reportProblemsToDiagnosticLog at launch, before the first lookup, which writes them as INTERFACE_TEXT_PROBLEM event lines; until then a problem is dropped.
  The engine imports no type of the app, so that a command-line probe compiles it (Scripts/l10n/pack-probe).

## The language in use
<!-- id: interface-language-state; keys: InterfaceLanguage.current, select, InterfaceLanguageChoice, InterfaceLanguageStore, AppleLanguages, observer, didChange, scopedLanguage; src: TextMouth/Localization/InterfaceText/InterfaceLanguage.swift, TextMouth/Localization/InterfaceText/InterfaceLanguageChoice.swift, TextMouth/Models/InterfaceLanguagePicker.swift, TextMouth/Views/InterfaceLanguageEnvironment.swift, TextMouth/Platform/macOS/Views/WindowTitleFollower.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/App/MenuCommands.swift, TextMouth/Platform/iOS/App/MagicTapWindow.swift -->

The language and locale every lookup reads, and the person's choice.

- Owner of the state in use: InterfaceLanguage, whose State (the language code and the locale) is one immutable value behind a lock, made at the first lookup from the stored choice (launchState) and swapped whole by select.
  Under System at launch the language is the first of Bundle.main.preferredLocalizations that the app carries, and the locale is the autoupdating current one.
  In a process that hosts the tests, System is English with en_US.
- Owner of the choice: InterfaceLanguageStore, which keeps it as the app's own preferences domain's AppleLanguages, the key the system's per-app language setting writes: a language writes its code alone, and System removes the key.
  A value the app does not carry reads as System.
  A process that hosts the tests keeps it in the sandbox's own preferences (see [The hosted-test sandbox](hosted-test-sandbox.md)), so no test writes the installed app's.
- Who may write it: the Interface Language picker alone, through InterfaceLanguagePicker.apply and InterfaceLanguage.choose, on the main thread.
  choose saves the choice, builds the state a live switch gives, and calls select.
  That state's locale is the one Foundation builds from the next launch on, since Locale.current keeps the launch's language until then.
  apply then announces the new language through VoiceOver, in that language.
  The app reads the stored choice at launch and when the picker is made, so a change made in System Settings shows at the next launch.
- How others observe it:
  - a lookup registers a dependency (an ObservationRegistrar access), so a switch runs again every SwiftUI body that looked up a line, and nothing else: focus, selection, and scroll position stay;
  - followsInterfaceLanguage, on the root of every window, sets the view tree's locale and layout direction from the state, right to left for Arabic, Hebrew, Persian, and Urdu;
  - InterfaceLanguage.observer, which the Commands structs of the menu bar observe;
  - the notification InterfaceLanguage.didChange, which these listen to:
    - MenuVisibilityManager, for the menu titles its rules compare and the menu bar's layout direction;
    - RecordingWindowModel;
    - the iPhone window, for the reading direction UIKit's bars follow and the language VoiceOver reads in;
  - WindowTitleFollower, which sets again the title of a window whose title the code sets once: the Record, Search Library, and audio editor windows, and the quit notice's panel.
- A window or alert already open keeps its other words until it closes.
- InterfaceLanguage.scopedLanguage is a task-local language that tests and title sets bind to read a line in another language, with nothing global changed.
- Formatted numbers and dates follow the state's locale (interfaceFormatted in InterfaceFormatting.swift), not Locale.current.
