# Fix `fixflow`: one re-read flow for both pop-up models, one places sentence, and an honest confirmation (review findings 8 and 5)

Team `braillecodes`, lead `braillecodes-lead`. Slug `braillecodes-fixflow`, branch `braillecodes/fixflow` from `team/braillecodes` (3b9bbee3 or later). Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first. The outside review is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/review-braillecodes.md`: read its findings 5 and 8 (lines 70-77 and 100-109). The orchestrator's decisions below settle every choice.

**Do not build.** The disk is nearly full; the lead builds the whole fix round once. Write the code and tests carefully (they must compile the first time), run `make lint-tests LINT_BASE=team/braillecodes`, commit, post `done:`, and report.

## Finding 8: the shared flow (behaviour and words unchanged)

Files: `TextMouth/ViewModels/BookRereadChoosing.swift`, `TextMouth/ViewModels/TextEncodingChoiceModel.swift`, `TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift`.

1. In `BookRereadChoosing.swift`, a `@MainActor final class RereadChoiceFlow<Option: Equatable & Sendable>: ObservableObject`, documented, holding what both models now repeat: `@Published private(set) var pending: RereadConfirmation<Option>?`, `isWorking`, `failureMessage`; `let bookID: UUID`, the `LibraryViewModel`, the `MaintenanceFileAccess`; and:
   - `func choose(_ option: Option) async`: `failureMessage = nil`, then `library.rereadPreflight(of:access:)`: refused sets `failureMessage = OperationFailureNotice.message(after: .failure(reason))`; ready sets `pending`.
   - `func confirm(_ option: Option, choosing choice: TextRereadChoice, thenReload reload: () async -> Void) async`: exactly today's `confirm` body (pending nil, failure nil, working, `readTextAgain(bookID:choosing:access:)`, the failure message, `await reload()`, not working). The reload is a parameter, never stored, so no cycle.
   - `func cancel()`.
2. Each model holds one: `let flow: RereadChoiceFlow<TextEncodingOption>` (and `<BrailleFileCode>`), made in `init`, and forwards its changes so views observing the model redraw: `flow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }` kept in a stored `AnyCancellable`. `pending`, `isWorking`, `failureMessage`, and `bookID` become computed forwards to the flow, so `BookRereadChoosing`, the sheet, and every existing test compile unchanged. Each model's `choose(_ item:)` keeps its own guard (the item is an option or code, not the selection, and `isEnabled`) and then awaits `flow.choose(option)`; `confirm` awaits `flow.confirm(option, choosing: .textEncoding(option)) { await self.load() }` (`.brailleFileCode(code)` for braille); `cancel()` calls the flow's. Remove the repeated stored properties and bodies.
3. The places sentence, one function: `TextEncodingWording.placesSentence(example: String?) -> String`, giving exactly today's encoding sentence for `"as when garbled letters become Cyrillic"` and exactly today's braille one for nil. `TextEncodingWording.placesNote` and `BrailleFileCodeWording.placesNote` stay as names (tests use them), each defined by that function. Both sentences' words are pinned now and must not change.

## Finding 5: "Nothing checks…" only between seven-bit codes

4. `BrailleFileCodeWording.confirmMessage(keepsText:stopsEditing:)` becomes `confirmMessage(from current: BrailleFileCode?, to chosen: BrailleFileCode, keepsText: Bool, stopsEditing: Bool)`. Its first sentence is `uncheckedNote` only when neither code is Unicode braille patterns (`current` nil, an id this TextMouth lacks, counts as not Unicode); otherwise a new `checkedNote(codeName:)`: "If the file is not written in \(chosen.name), TextMouth refuses it, and nothing changes." The rest is today's (`replacedNote`, the places sentence, then the kept-edit and Edit Text sentences when they apply).
5. `BrailleFileCodeChoiceModel.confirmMessage(for:)` passes `BrailleFileCode.code(forStored: storedCode)` as `current`.

## Tests

- New class `BookRereadFlowTests` (file `TextMouthProductionTests/BookRereadFlowTests.swift`): one test that, for each model (a text book's `TextEncodingChoiceModel`, a BRF book's `BrailleFileCodeChoiceModel`), drives choose (pending set), cancel (nil), a refused preflight (a book in `booksBeingReadAgain`: the busy sentence shown, nothing pending), and a confirm (the re-read runs, `isWorking` ends false, the model shows the new choice). Reuse the fixtures of `TextEncodingPopUpTests` and `BrailleFileCodeBookInfoTests` if they are not private; otherwise write small ones (`LibraryIndexSandbox`, bound table and code, never `~/.TextMouth`).
- In `BrailleFileCodeBookInfoTests`, change only the calls the new `confirmMessage` signature breaks, and add: North American to Unicode, and Unicode to Eurobraille, open with the checked sentence (exactly), and North American to Eurobraille keeps the unchecked one.
- Every existing test of both pop-ups must pass unchanged (`TextEncodingPopUpTests`, `TextEncodingBookInfoTests`, `TextEncodingChoiceTests`, `TextEncodingRereadTests`).
- `/opt/homebrew/bin/xcodegen generate` for the new test file; commit the project file (four lines; regenerate until the copy phases are not shuffled).

## Do not

Build; edit any file not named here (the lead edits `LibraryInfoWording.swift` only in `Book.brailleFileCodeDescription`'s region, apart from yours: keep to `TextEncodingWording`'s places lines and `BrailleFileCodeWording`'s confirmation lines); edit `*.md`; touch `~/.TextMouth`.
