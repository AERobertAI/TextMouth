# Task `iosdry`: fold the iPhone code's duplicates (November 8, 2026)

Slug `iosdry`, branch `ios/dry-1108` from `ios/lead-1108`. Read `Scripts/agents/briefs/2026-11-08/ios-workers.md` first; its rules hold.

The slices of November 7 were built in parallel, and some made the same thing twice. Fold each into one, by the project's rule: don't repeat yourself. **Nothing a person hears or reads changes:** every word stays exactly as it is, and the tests that pin the words keep pinning them, under the folded names.

## What to fold

1. **One voice type.** Settings has `PhoneSettingsVoice` (TextMouth/Phone/PhoneSettingsModel.swift, about line 296), and the reader's Voice & Speed sheet has `PhoneVoiceOption` (TextMouth/Phone/PhoneVoiceModel.swift, about line 64): the same voice, the same Personal Voice filter. Keep `PhoneVoiceOption`, which knows the language too, and make Settings use it. Settings' worker said so on the board (#5304): "Same words, same filter. Once both are on ios/interface, one should call the other."
2. **One no-voices sentence and one voice label.** `PhoneSettingsWording.noVoicesInstalled` and `PhoneVoiceWording.noVoices` are the same sentence; `PhoneSettingsVocabulary.voiceChoice(name:quality:)` and `PhoneVoiceVocabulary.voiceChoice(name:quality:)` the same label. Keep the Voice sheet's, and make Settings call them.
3. **One "Cancel".** The phone defines it five times: `PhoneBookmarksModel.swift:32`, `PhoneFolderVocabulary.swift:27`, `PhoneGoToModel.swift:14`, `PhoneLibraryVocabulary.swift:107`, and `PhoneReaderWording.swift:76`. Make one phone constant, in `PhoneAppWording`, and have every phone use of "Cancel" read it. Leave the Mac's own (`AddToLibraryWording.cancel`, `LibraryViewEditorWording.cancel`) as they are: they're Mac code.
4. **One "New Folder".** `PhoneLibraryVocabulary.newFolderTitle` and `PhoneFolderVocabulary.newFolderTitle` are the same word. Keep one, where the folder sheets' words live.
5. **Anything else of the same kind you find,** among the phone's own files only (`TextMouth/Phone/`, `TextMouth/Platform/iOS/`): the same sentence or word defined twice, or the same small type or function written twice. Find them with a script that lists every string literal defined in more than one `static let` there. Fold what is truly the same thing; leave words that are the same by chance but mean different things, and say which you left and why.

Leave `TextMouth/Phone/PhoneSettingsDefaults.swift` (one comment line) where it is: nothing is deleted during the run, and the orchestrator will remove it later. Say so in your report.

## How

- One commit per fold, each with its tests updated in the same commit: the tests in `TextMouthProductionTests/Phone*Tests.swift` that name the old constants or type. Keep every pinned word.
- Where a test pinned that two copies said the same thing, it can now pin the one.
- Update the views that use the folded names: `TextMouth/Platform/iOS/Views/Settings/PhoneSettingsView.swift`, `TextMouth/Platform/iOS/Views/Reader/PhoneVoiceSheet.swift`, and the sheets that say "Cancel".
- Checks, as the shared page says: trap-lint, the Mac projection (no new real change: these files are the phone's own), `make typecheck-ios`, `make typecheck-mac`, then the train with `--areas phone`.

## Your files

`TextMouth/Phone/**`, `TextMouth/Platform/iOS/Views/**`, and `TextMouthProductionTests/Phone*Tests.swift`. Claim them on the board. The lead may also be changing `TextMouth/Platform/iOS/App/` and the test targets `TextMouthiOSTests/` and `TextMouthiOSUITests/`: leave those to the lead.
