# Task D, `feedopts-feedsheet`: Feed Info's three listening controls

Branch `feedopts/feedsheet`. Read `00-contract.md` first. Task A is on the team branch (`ListeningOptions`, `Feed.listeningOptions`, `FeedCenter.setListeningOptions(_:of:)`, `ListeningOptionsWording`, `EnumSettingRule.storedValue(in:)`). **Add three controls to Feed Info's "This Feed's Settings", beside "Delete downloads after playing", so the sheet reads as the feed's listening settings.** The sheet is the one Command-I opens on a feed's row (and, after task F, the toolbar's Feed Settings button). Deleting finished episodes already exists there: add no control for it.

## The controls (after the delete-downloads pair, `FeedInfoSheet.swift:336-351`)

1. **A pop-up button** labelled `ListeningOptionsWording.continuationLabel(noun)` ("When an episode ends"), choices `continuationTitle` for nil ("Use the global setting (<the global When book ends choice, e.g. Stop>)"), `.playBookBelow` ("Play the episode below"), `.playBookAbove` ("Play the episode above"), `.stop` ("Stop"), in that order, hint `continuationHint(noun)`. Selecting a choice saves at once; selecting the first stores nil.
2. **A checkbox** "Skip finished episodes" (`skipFinishedLabel`), hint `skipFinishedHint`, on by default, always available.
3. **A checkbox** "Download the next episode before this one ends" (`predownloadLabel`), on by default, **available only while listening would go on to another episode** (`ListeningOptions.goesOn(under: globalEndOfBookBehavior)`: below or above chosen, or the global choice chosen and the global setting at Continue to Next Book); dimmed otherwise, and its hint then is `predownloadHint(noun, enabled: false)`, else `predownloadHint(noun, enabled: true)`. The stored value is kept while dimmed.

`noun` is the feed's own: `ListeningOptionsWording.Noun(counts.noun)` where the sheet already has `counts.noun` (`FeedInfoSheet.swift:180,188`), so a feed of articles says "article".

Build them as `ReadingListOptionsBar.swift` builds its pop-up and checkbox (`.pickerStyle(.menu)`, `.toggleStyle(.checkbox)`, `.help`, `.accessibilityLabel`, `.accessibilityHint` from the wording). Every control keyboard-operable (they are AppKit pop-up and checkbox controls); nothing conveyed by sight alone: the dimmed pre-download checkbox says why in its hint.

## The model (`FeedInfoModel`, `FeedInfoSheet.swift:11-99`)

Add, beside the other "own settings" properties (`:43-75`), documented like them:
- `init(feedID:center:library:defaults:)` gets a new last parameter `defaults: UserDefaults = .standard` (`FeedCommandRunner.swift:87` and the tests construct the model without it; they must keep compiling unedited).
- `var listeningOptions: ListeningOptions` (get: the feed's or `.standard`; set: `center.setListeningOptions(_, of: feedID)`).
- `var episodeEnd: ReadingList.Continuation?`, `var skipsFinishedEpisodes: Bool`, `var predownloadsNextEpisode: Bool`: each reads and writes `listeningOptions`.
- `var globalEndOfBookBehavior: EndOfBookBehavior` (`SettingsPolicy.endOfBookBehavior.storedValue(in: defaults)`) and `var continuesToAnotherEpisode: Bool` (`listeningOptions.goesOn(under: globalEndOfBookBehavior)`).

## Existing tests that change on purpose

`FeedUICommandsTests.testFeedInfoDrawsItsLabelledControls` (`FeedUICommandsTests.swift:443-490`) counts the controls Feed Info draws: two pop-ups ("the List and download and folder pop-ups") and three checkboxes. After this task it draws **three pop-ups and five checkboxes**. Change exactly those two counts and their failure messages, nothing else in that test or file, and say so in your report with the reason. Any other existing test that fails: stop and ask.

## Tests (new `TextMouthProductionTests/FeedListeningOptionsSheetTests.swift`, needs `xcodegen generate`, the regenerated `project.pbxproj` committed with it)

Host Feed Info as `FeedUICommandsTests` does (`withHostedView` and `descendants(of:as:)` from `AccessibilityTestSupport.swift`; the sheet is 520 by 600, host it in a fixed frame; read `withHostedView`'s comment on views that outgrow their window), with a `FeedTestWorld` for the feed (`FeedTestSupport.swift:439`; the `Harness` at `FeedUICommandsTests.swift:694` shows one subscribed feed):
1. The model: each property reads the feed's options and writes through the engine (the record changes, standard writes nothing, the first choice stores nil); `continuesToAnotherEpisode` for all nine combinations of the feed's choice and the global setting (a private `UserDefaults` suite, removed afterwards).
2. The hosted sheet: the new pop-up has the four titles in order and the right selected title for a feed with no options, with `.playBookAbove`, and with `.stop`; two more checkboxes, on by default; the pre-download checkbox is disabled exactly when listening would stop, and enabled again after the choice changes; in a feed of articles the words say "article".
3. Choosing in the pop-up and clicking each checkbox in the hosted sheet saves (reads back through `center.store.record(of:)`).
4. All wording is `ListeningOptionsWording`'s (task A pinned the strings); test that the sheet shows the wording functions' output, not a copy.

## Tests to run

`FeedListeningOptionsSheetTests`, `FeedUICommandsTests` (with its two changed counts), `ListeningOptionsTests`, `LibraryFeedUnsubscribeTests` (it uses Feed Info's model).

## Commits

1. The model's properties, with their tests.
2. The three controls, the two changed counts, and the hosted tests.

## Do not touch

`ListeningOptions*.swift` (task A's), `LibraryView.swift`, `LibraryFeedsWindowSupport.swift`, `FeedCommandRunner.swift`, any existing test besides the two counts.
