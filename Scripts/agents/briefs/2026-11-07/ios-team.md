# Team `iosui`: the iPhone interface, its spec and its first build (November 7, 2026)

The user, at about 01:30 on November 7: "theres 30% left on the weekly usage with like 6 hours left... so Go crazy, I want to use it all. Maybe have a full Opus team go through and design a spec for the IOS interface and try having them start implementing it."

You are the lead, `iosui-lead`, and your team is all Opus, as the user asked: launch each agent with `model: "opus"`. The week resets at about 07:00 Eastern. Use the time well and spend what the work needs, but the point is a spec the user can trust and a real start on the app, not activity. Commit small and often, so a stop loses nothing.

## Who this is for

The user is blind and reads with VoiceOver and braille. They'd be the app's first user, on their own iPhone. This isn't a sighted app made accessible afterward: the VoiceOver and braille experience is the design, and the visual layout follows from it. They read this spec by VoiceOver too, so write it with real headings and short lists, with no diagrams, no ASCII art, and nothing that depends on seeing it. Say "the button after Play", not "the button on the right".

## What exists

TextMouth is a native Mac text-to-speech and audiobook reader. Since November 4 it has a second target, `TextMouthiOS`, compiled from the same sources, which compiles and links for iOS 26 with 0 errors and 0 warnings (`make typecheck-ios`). Its screen is a placeholder: `TextMouth/Platform/iOS/App/TextMouthIOSApp.swift`, 30 lines. The speech, playback, library, import, and feed engines are shared, and so are all the document and Kindle readers, which are TextMouth's own Swift code now. The app handles no opened file yet.

Read these first:
- `Scripts/agents/briefs/2026-11-06/common.md`, and `Scripts/agents/briefs/2026-11-04/readers-common.md` as it says, for builds, tests, the board, and the rules. You also may read `AGENTS.md`, `docs/architecture/platforms.md`, `docs/architecture/parts-of-the-app.md`, `docs/architecture/reading-a-book.md`, and `docs/user/` for what a person can do on the Mac today.
- `IOS-PORT-RESEARCH-2026-11-03.md`, from its section "The iPhone app, for the person using it" through "A plan in phases".
- `humanQuestions/2026-11-03.md`, with its open questions.

## What's decided, and what isn't

Questions 1 to 4 and 6 in `humanQuestions/2026-11-03.md` have no answers from the user yet. Build on the recommended answers, and keep each reversible:
- iPhone first, with layouts that also work on an iPad. iPad windows and the menu bar come later.
- The first version is the list in question 2: the library, with folders and sorting; adding books from Files and the share sheet; the reader, for text read aloud and for audiobooks, with voices, rate, navigation by sentence, paragraph, heading, and page, bookmarks, Where Am I?, and the sleep timer; listening with the screen locked, with lock-screen, Control Center, and AirPods controls; VoiceOver throughout.
- Later: feeds, transcription, export, braille, editing text, recording, and the audio editor.
- A library of the phone's own, not shared with the Mac.
- iOS 26 and later.
- Questions 7 to 9 have moved on: TextMouth's own readers now read `.doc`, `.odt`, RTF, MOBI, and KFX on iOS. Ogg and braille stay out at first.

Anything else you'd need to ask the user goes in the spec's last section, each question with your recommendation and what you built in the meantime. Ask nothing of the user directly.

## The limit you must plan around

**Nothing can run on iOS tonight.** The Mac has about 10 GB free and the iOS platform needs about 10 GB, so there is no simulator and no device. Don't download it. `make typecheck-ios` compiles and links, and that's the only check of iOS code. So:
- Keep SwiftUI views thin, and put logic in plain types that compile on both platforms, so the Mac's test host can run their tests through the train.
- Check each API against Apple's documentation, because no run will catch a misuse. Name each behavior you couldn't verify.
- Say plainly in every report that nothing has run on iOS. The spec ends with a hand-check list the user can follow with VoiceOver on their iPhone, once the platform is there.

## The work

1. **Research, in parallel, read-only.** Launch agents for each of these, and give each a narrow brief:
   - **What a VoiceOver and braille reader needs on an iPhone.** Primary sources first: Apple's accessibility documentation for iOS 26, including custom rotors, the magic tap, the escape gesture, adjustable elements, `accessibilityRespondsToUserInteraction`, focus, announcements and their priorities, Direct Touch, Braille Screen Input, and braille displays. Then the hard question for this app in particular: an app that speaks while VoiceOver also speaks. How do ducking, the audio session, VoiceOver's own reading, and the app's speech interact, and when should the app stay silent? Then what blind readers say about Voice Dream Reader, Dolphin EasyReader, Apple Books, Audible, and Overcast, on AppleVis and similar places: what they praise and what they curse. iOS 26's design changes matter too, as far as they touch VoiceOver.
   - **What's in the code.** Every Mac screen and command, and which view models and services it uses. What's reusable as it stands, what's AppKit, where the seams are (`PlatformWindow`, `FrontWindowKind`, `VoiceOverFocus`, `NowPlayingService+iOS`, and so on). How a reader opens, what owns its state, and what assumes a window. A map from the first version's features to the code.
   - **What iOS does to the app.** `AVAudioSession` categories and interruptions, route changes, background audio, Now Playing and `MPRemoteCommandCenter`; `AVSpeechSynthesizer` in the background, `usesApplicationAudioSession`, and the engine path; the app's life cycle and saving; memory limits and `os_proc_available_memory`; the sandbox and where the library lives; Files visibility, `LSSupportsOpeningDocumentsInPlace`, `fileImporter`, Open In, and whether a share extension is needed; security-scoped URLs; a long import while the app goes to the background.

2. **The spec:** `IOS-INTERFACE-SPEC-2026-11-07.md` at the repository's root (`git add -f`). It says:
   - the principles, and the app's structure and navigation, decided by how they work under VoiceOver, with the alternatives you rejected and why;
   - **every screen, element by element, in VoiceOver's order:** label, value, hint, traits, actions, rotor items, what's announced and when, where focus lands on arrival and on return, and what a braille display shows;
   - the reader in full, since it's the heart of the app: how the reading units, the rotor, position, rate, the magic tap, bookmarks, Where Am I?, and the sleep timer work, and how a user both hears the book and uses VoiceOver at once;
   - the Now Playing bar, the lock screen, Control Center, AirPods;
   - importing, errors, empty states, and long operations;
   - settings: which of the Mac's settings the first version has, and in what words;
   - how the wording stays the Mac's where the Mac's wording exists: the two apps share one vocabulary;
   - what's deferred, and how it would fit later; how it fits an iPad;
   - the map to existing code; the implementation slices in order, each with its tests;
   - the hand-check list, and the open questions.

3. **Two outside reviews of the spec, independently, each by a fresh Opus agent,** neither shown the other's report, and neither given your reasoning:
   - **As the user.** Walk through real tasks, step by step, gesture by gesture: find a book, open it, listen, jump to page 40, bookmark a place, lock the phone, pause from AirPods, come back the next day and find your place, add a book from Mail, a book that won't import. What's unclear, slow, or silent? Where does VoiceOver lose focus? Where do the app's speech and VoiceOver collide?
   - **As an iOS engineer who has read the code.** What can't be built as written, what misuses an API, what's underspecified, and what will the first real run on a phone show that a compile can't?
   Revise the spec from both, and keep both reports. Save them at `build/orchestrator/iosui/`, or give them to me in your report if that write is refused.

4. **Start building, in slices, from the revised spec.** Work in the order of the research's phase 1: the frame (library, reader, settings, importing, the library in the app's container); audio (session, background, interruptions, routes, lock screen, remote commands); the life cycle; VoiceOver (rotor, magic tap, adjustable rate and position, actions, focus); then bookmarks, Where Am I?, the sleep timer, voices, and rate. Give each slice to its own Opus worker, in its own worktree and branch off yours, with files claimed on the board, and merge each into `ios/interface` yourself. Don't rush a slice to reach the next: a smaller set that's right is the goal. Run `Scripts/test/a11y-lint.py` over what's written.

5. **An outside Opus code review of what's built,** against the spec and against Apple's documentation, then a fix round, as far as time allows.

## The Mac must not change

The user installs main, and the Mac's suite must stay green: 10261 tests today. iOS code goes in `TextMouth/Platform/iOS/`, or in shared files behind `#if os(iOS)`. A change to a shared type must leave the Mac's behavior as it is, with tests to show it. Name every such change in your report. Run `make typecheck-mac` and `make typecheck-ios` on committed work, and send your branch through the train with the classes your shared changes can break. The train pools every pending branch, so never queue a deliberately broken one.

You don't merge into main. Your branch stays as `ios/interface`, and the orchestrator decides what follows.

## Rules that have tightened tonight

- **Nobody deletes anything tonight.** No `rm` at all, not even with a relative name, and no deleting from scripts. A prompt about an `rm` woke the user and stopped things. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer, and that stalled one agent for four hours tonight. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk is tight.** Keep each agent's scratch under 500 MB, and avoid private copies of the whole source tree. Say so to every agent you launch.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- Put all of these rules, word for word, in every prompt you write. Reviewers too.

## Your report

Your final message is your report. Try to save it as well at `build/orchestrator/iosui/lead-report.md`, in the main checkout. Give: the spec's path and commit; the decisions a reader should check first; each slice, with its commits and what it does; what shared code changed and why it's safe for the Mac; `make typecheck-*` and the train's results; what's built and hasn't been run, and the hand checks to do first; the open questions, with your recommendations; and what to do next. Be plain about what isn't done.
