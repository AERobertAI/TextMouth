import SwiftUI
import AVFoundation

/// A reader window's content: the book, its toolbar, and its panels, each a
/// sheet over the reader that a toolbar button or a menu command opens.
///
/// The body only puts the parts together, each a view, a property, or a
/// modifier of its own (board #829). A view's body is type-checked as one
/// expression, and when every part was written out inside it, the body sat
/// at the compiler's limit: one more modifier, or a parameter whose type
/// changed, failed the build with "unable to type-check this expression in
/// reasonable time". Each part is type-checked on its own now. The parts
/// draw what the body drew, in the same order, with the same labels.
struct ReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @EnvironmentObject var soundEffectService: SoundEffectService
    /// Which of the reader's panels are showing.
    @State private var panels = ReaderPanels()
    /// The reader's transcription dialogs (FR05), kept here so that the
    /// report of a speech refusal can wait while one shows.
    @StateObject private var transcription = TranscriptionPresenter()
    /// Closes this reader's window, for Close in the cloud download view.
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let _ = ViewBodyCounter.record("ReaderView")
        readerContent
            .toolbar { toolbarItems }
            .onAppear {
                viewModel.soundEffectService = soundEffectService
            }
            // Export and the other commands on the book as a whole (FR05).
            .modifier(ReaderBookCommandsSupport(
                viewModel: viewModel,
                exportModel: $panels.export,
                moveToLibrary: $panels.moveToLibrary,
                transcription: transcription
            ))
            .modifier(ReaderErrorAlert(viewModel: viewModel))
            .modifier(ReaderPanelSheets(viewModel: viewModel, panels: $panels))
            .modifier(ReaderPanelCommands(viewModel: viewModel, panels: $panels))
            // The report of a speech refusal, once nothing else shows over
            // the reader (B05).
            .modifier(SpeechRefusalReportPresenter(viewModel: viewModel, panels: panels, transcription: transcription))
    }

    // MARK: - Content

    /// What the window shows: the book being got from the cloud, the book
    /// loading, why it could not be loaded, or, once it has loaded, the
    /// book itself: where the reader is, the info bar, the text, and the
    /// playback controls, top to bottom.
    private var readerContent: some View {
        VStack(spacing: 0) {
            if let phase = viewModel.cloudPhase {
                // The book, or the chapter about to play, is being got from
                // the cloud, or could not be (FR02).
                ReaderCloudPhaseView(
                    phase: phase,
                    title: viewModel.book.title,
                    provider: viewModel.cloudProvider,
                    actions: cloudPhaseActions
                )
            } else if viewModel.isLoading {
                ProgressView("Loading book...")
                    .accessibilityLabel("Loading \(viewModel.book.title)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadErrorMessage {
                ReaderLoadFailureView(message: error)
            } else {
                // The book's title, the heading being read, and its number.
                ReaderLocationHeader(viewModel: viewModel)

                // Info bar with progress, time remaining, sleep timer
                BookInfoBar(viewModel: viewModel)

                Divider()

                ReaderTextArea(viewModel: viewModel)

                Divider()

                // Playback controls
                PlaybackControlsView(viewModel: viewModel)
            }
        }
    }

    /// What the cloud download view's buttons do: Cancel, Download, and
    /// Try Again act on the reader, and Close closes its window.
    private var cloudPhaseActions: ReaderCloudPhaseView.Actions {
        ReaderCloudPhaseView.Actions(
            cancel: { viewModel.cancelDownload() },
            download: { viewModel.downloadAgain() },
            tryAgain: { viewModel.retryOpening() },
            close: { dismissWindow() }
        )
    }

    // MARK: - Toolbar

    /// The reader's toolbar, in order: Return, while there is a reading
    /// position to return to; Where Am I?; the buttons that open the
    /// Headings, Bookmarks, Sleep Timer, Search (a text book's, or a transcribed
    /// audiobook's), Voice
    /// or Audio Settings, and Book Info panels; and the speed in force.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            if viewModel.hasSavedPosition {
                toolbarButton(
                    "Return",
                    systemImage: "arrow.uturn.backward",
                    spokenLabel: "Return to previous reading position"
                ) {
                    viewModel.returnToSavedPosition()
                }
                .accessibilityHint("Go back to where you were before browsing headings or bookmarks")
            }

            ReaderWhereAmIToolbarButton(isSpeaking: viewModel.isWhereAmISpeaking) { detail in
                viewModel.whereAmI(detail)
            }

            toolbarButton("Headings", systemImage: "list.bullet", spokenLabel: "Show heading navigator") {
                panels.headings.toggle()
            }

            toolbarButton("Bookmarks", systemImage: "bookmark", spokenLabel: "Show bookmarks") {
                panels.bookmarks.toggle()
            }

            toolbarButton("Sleep Timer", systemImage: "moon", spokenLabel: "Sleep timer") {
                panels.sleepTimer.toggle()
            }

            if viewModel.canSearchText {
                toolbarButton("Search", systemImage: "magnifyingglass", spokenLabel: "Search in book") {
                    panels.search.toggle()
                }
            }

            // The book's own settings: a text book's voice, or an
            // audiobook's audio settings (TODO A11).
            toolbarButton(
                LocalizedStringKey(BookSettingsWording.buttonTitle(isAudioBook: viewModel.isAudioBook)),
                systemImage: Self.bookSettingsSymbol(isAudioBook: viewModel.isAudioBook),
                spokenLabel: LocalizedStringKey(BookSettingsWording.buttonLabel(isAudioBook: viewModel.isAudioBook))
            ) {
                panels.voice.toggle()
            }

            // An episode's or article's Book Info edits nothing (FR11), and
            // the button says so.
            toolbarButton(
                "Book Info",
                systemImage: "info.circle",
                spokenLabel: LocalizedStringKey(FeedItemBookInfoWording.readerButtonLabel(readOnly: viewModel.book.hasReadOnlyBookInfo))
            ) {
                panels.bookInfo.toggle()
            }

            speedCaption
        }
    }

    /// A toolbar button showing `title` beside the SF Symbol `systemImage`,
    /// which VoiceOver speaks as `spokenLabel`, and which runs `action`.
    private func toolbarButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        spokenLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityLabel(spokenLabel)
    }

    /// The speed in force, at the toolbar's end: an audiobook's speed, or a
    /// text book's words per minute, in the accent color while the book has
    /// a speed of its own.
    @ViewBuilder
    private var speedCaption: some View {
        if viewModel.isAudioBook {
            // Shared formatter: "1.25x" on screen, "1.25 times speed" spoken.
            Text(AudioSpeed.visibleLabel(for: viewModel.audioSpeed))
                .font(.caption)
                .foregroundColor(speedCaptionColor)
                .accessibilityLabel(AudioSpeed.spokenLabel(for: viewModel.audioSpeed))
        } else {
            Text("\(Int(viewModel.speechService.wordsPerMinute)) WPM")
                .font(.caption)
                .foregroundColor(speedCaptionColor)
                .accessibilityLabel("\(Int(viewModel.speechService.wordsPerMinute)) words per minute\(viewModel.book.localWPM != nil ? ", book-specific speed" : "")")
        }
    }

    /// The speed caption's color: the accent color while the book has a
    /// speed of its own, and otherwise the secondary color.
    private var speedCaptionColor: Color {
        viewModel.book.localWPM != nil ? .accentColor : .secondary
    }

    /// SF Symbol for the toolbar button that opens per-book settings. An
    /// audiobook's Audio Settings show a speed gauge, for the speed they
    /// set first, rather than the voice icon a sighted user would read as
    /// "voice settings".
    static func bookSettingsSymbol(isAudioBook: Bool) -> String {
        isAudioBook ? "gauge.with.needle" : "person.wave.2"
    }
}

// MARK: - The Reader's Parts

/// Which of a reader's panels are showing, each as a sheet over the reader.
/// The toolbar's buttons and the menu commands (`ReaderPanelCommands`) open
/// and close them, and `ReaderPanelSheets` presents them; the Export dialog
/// is opened and presented by `ReaderBookCommandsSupport`.
struct ReaderPanels {
    /// The headings (`HeadingNavigatorView`).
    var headings = false
    /// The bookmarks (`BookmarkPanelView`).
    var bookmarks = false
    /// The sleep timer (`SleepTimerView`).
    var sleepTimer = false
    /// The book's info (`ReaderBookInfoSheet`).
    var bookInfo = false
    /// The book's voice and speed, or an audiobook's audio settings
    /// (`BookVoicePickerView`).
    var voice = false
    /// Search in the book (`BookSearchView`), for a text book only.
    var search = false
    /// The Export dialog (`BookExportSheet`) for the book as a whole
    /// (FR05), which File > Export… and the toolbar's Export button open
    /// (`ReaderBookCommandsSupport`): the export it shows, or nil.
    var export: BookExportModel?
    /// Move to Library…'s sheet (`MoveToLibrarySheet`) for an episode or
    /// article in its feed (FR11, branch D), which Book > Move to Library…
    /// opens (`ReaderBookCommandsSupport`): what it moves, or nil.
    var moveToLibrary: MoveToLibraryRequest?
}

/// The reader toolbar's Where Am I? button (FR12). Pressed, it speaks the
/// brief summary, or stops the announcement speaking; VoiceOver calls it by
/// what a press does. Its VoiceOver action "Where Am I? Full Summary"
/// (VO-Command-Space), named as the Playback menu names the command, speaks
/// the full summary, as W twice does: with quick clicks no longer reaching
/// the full summary once the three-second rule was retired, the toolbar had
/// no way to it (board #1593).
struct ReaderWhereAmIToolbarButton: View {
    /// Whether an announcement speaks now, which a press stops.
    let isSpeaking: Bool
    /// Asks the reader for a summary: the brief one at a press, the full
    /// one from the VoiceOver action.
    let whereAmI: (SummaryDetail) -> Void

    /// The words on the button.
    static let title = "Where Am I?"
    /// What VoiceOver calls the button while nothing is announced.
    static let spokenLabel = "Where Am I? Announces current position in the book"
    /// What VoiceOver calls it while an announcement speaks, which a press
    /// stops.
    static let stopLabel = "Stop Where Am I announcement"
    /// The name of its VoiceOver action, the Playback menu's name for the
    /// command (`ShortcutAction.whereAmIFull`).
    static var fullSummaryActionName: String { ShortcutAction.whereAmIFull.title }

    var body: some View {
        Button {
            whereAmI(.brief)
        } label: {
            Label(Self.title, systemImage: "location.circle")
        }
        .accessibilityLabel(isSpeaking ? Self.stopLabel : Self.spokenLabel)
        .accessibilityAction(named: Text(Self.fullSummaryActionName)) {
            speakFullSummary()
        }
    }

    /// What the VoiceOver action does: asks for the full summary, which
    /// stops the full summary while it speaks, as W twice does then.
    func speakFullSummary() {
        whereAmI(.full)
    }
}

/// Why the book could not be loaded, shown in place of the book, and read
/// by VoiceOver as one element: "Failed to load book", then the reason.
struct ReaderLoadFailureView: View {
    /// What went wrong, the reader's `loadErrorMessage`.
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.red)
                .accessibilityHidden(true)
            Text("Failed to load book")
                .font(.headline)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The header above the info bar, the reader's status line: the book's
/// title, the heading being read, and that heading's number among all the
/// book's headings, the same list and numbering the headings panel shows.
/// Internal content units (spine files, audio files) are never counted
/// here. It follows the display cursor, so it moves with playback
/// across headings without drawing again at every word.
struct ReaderLocationHeader: View {
    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        let _ = ViewBodyCounter.record("ReaderLocationHeader")
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.content != nil {
                Text(viewModel.book.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)

                // A book read from the reading list says where it stands in
                // the list, as plain text VoiceOver reads after the title
                // (FR09); the window's title says "Reading List" too.
                if let place = viewModel.readingListPlace {
                    Text(ReadingListReaderWording.place(place))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let position = viewModel.displayHeadingPosition
                if let title = viewModel.locationTitle(
                    for: position,
                    chapterIndex: viewModel.displayChapterIndex
                ) {
                    Text(title)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                // Empty for a book without headings.
                if !position.label.isEmpty {
                    Text(position.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The book's text, in a scroll area VoiceOver calls "Book content", where
/// VoiceOver and a braille display read its words whole.
///
/// The label names the scroll area, never the text (TODO A11). On the text
/// it became the text's value in place of its words: while the book
/// played, VoiceOver read "Book content" and nothing of the book; while it
/// was paused, when the text can be selected, the value said "Book
/// content" while the characters were the book's, and VoiceOver showed as
/// many of them as the label has, twelve: "Where did th".
///
/// Only a window of text around the current position is drawn. The full
/// chapter text lives in the model for TTS; rendering hundreds of thousands
/// of characters in a SwiftUI Text view freezes the main thread.
struct ReaderTextArea: View {
    @ObservedObject var viewModel: ReaderViewModel

    /// What VoiceOver calls the scroll area holding the book's text.
    static let accessibilityLabel = "Book content"

    var body: some View {
        let _ = ViewBodyCounter.record("ReaderTextArea")
        ScrollView {
            if let content = viewModel.content,
               viewModel.displayChapterIndex < content.chapters.count {
                if viewModel.isPlaybackActivelyAdvancing {
                    // Keep selection disabled while the playback window is
                    // still capable of moving. A constantly replaced
                    // selectable Text view was the most likely trigger for
                    // the huge VoiceOver/AppKit memory spike during live
                    // playback.
                    visibleText
                        .textSelection(.disabled)
                } else {
                    visibleText
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    /// The window of text around the current position, laid out across the
    /// area's width.
    private var visibleText: some View {
        Text(viewModel.displayVisibleTextWindow)
            .font(.body)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A problem met after the book has loaded, such as a chapter whose audio
/// cannot be played or could not be got from the cloud, shown as an alert
/// over the reader, which stays usable behind it. Return chooses the
/// default button, Retry (Try Again for the cloud) or OK, and Escape
/// cancels.
struct ReaderErrorAlert: ViewModifier {
    /// The reader whose error the alert shows, observed so the alert comes
    /// and goes with it.
    @ObservedObject var viewModel: ReaderViewModel

    func body(content: Content) -> some View {
        content.alert(
            viewModel.errorAlert?.title ?? "",
            isPresented: isPresented,
            presenting: viewModel.errorAlert
        ) { alert in
            if alert.offersRetry {
                Button(alert.retryTitle) {
                    // SwiftUI closes the alert around this action. Retrying
                    // on the next turn of the main queue lets a retry that
                    // fails again present a fresh alert, rather than having
                    // the closing alert clear its message.
                    DispatchQueue.main.async { viewModel.retryAudioPlayback() }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// Whether the error alert is showing: while the reader has an error to
    /// show over its content. Closing the alert by any button, or with
    /// Escape, forgets the error.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorAlert != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissErrorAlert()
                }
            }
        )
    }
}

/// The reader's panels, each presented as a sheet over the reader while
/// `panels` says it shows. The reader is observed, as the reader view
/// observed it when it presented them itself, so a sheet that is showing
/// is made again with what the reader holds now.
struct ReaderPanelSheets: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var panels: ReaderPanels

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $panels.headings) {
                HeadingNavigatorView(viewModel: viewModel)
            }
            .sheet(isPresented: $panels.bookmarks) {
                BookmarkPanelView(viewModel: viewModel)
            }
            .sheet(isPresented: $panels.sleepTimer) {
                sleepTimerSheet
            }
            .sheet(isPresented: $panels.bookInfo) {
                ReaderBookInfoSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $panels.voice) {
                BookVoicePickerView(viewModel: viewModel)
            }
            // A result of a transcript moves the audio while the sheet closes;
            // where it moved to is said once the sheet has gone and VoiceOver
            // has settled on the reader.
            .sheet(isPresented: $panels.search, onDismiss: { viewModel.announcePendingJump() }) {
                searchSheet
            }
    }

    /// The sleep timer of this reader's window, whose start plays the book
    /// unless it is playing already, and whose Close, or its closing by
    /// itself when Settings say so, closes the sheet.
    private var sleepTimerSheet: some View {
        SleepTimerView.sheet(for: viewModel) {
            panels.sleepTimer = false
        }
    }

    /// Search in the loaded book: a text book's text, or a transcribed
    /// audiobook's transcript, whose results say when they are heard.
    /// Choosing a result moves the reader there and closes the sheet.
    @ViewBuilder
    private var searchSheet: some View {
        if let content = viewModel.content, let corpus = viewModel.searchCorpus {
            // A timed corpus is a transcript, whose results are places in
            // its text, not in the audio's spacing.
            let isTranscript = corpus.timing != nil
            BookSearchView(
                corpus: corpus,
                totalCharacterCount: content.totalCharacterCount,
                totalWordCount: content.totalWordCount,
                currentWPM: viewModel.speechService.wordsPerMinute,
                announce: viewModel.announceToVoiceOver,
                onNavigate: { chapterIndex, charOffset in
                    viewModel.goToSearchResult(
                        chapterIndex: chapterIndex,
                        characterOffset: charOffset,
                        inTranscript: isTranscript
                    )
                    panels.search = false
                }
            )
        }
    }
}

/// The reader's Book Info sheet: an EPUB's metadata or an audiobook's, in
/// the metadata editor, or for any other book (plain text, Markdown, HTML)
/// the simple info editor the library uses. Each says after a field's label
/// that the user edited it by hand, from the book's record (`Book.handEdits`),
/// as the Library window's Book Info does. The reader's copy of the book
/// takes the record from every save of its row, the reader's own saves
/// included, and the reader is observed, so the sheet, opened again, says
/// "edited by hand" for a field just saved.
///
/// While the sheet is open the reader takes every change the library makes
/// to the book (another window's save, the launch metadata refresh), and
/// the sheet is made again with it. Each editor keeps what it opened with
/// and its save hands that on, so the save changes, and marks, only what
/// the user changed in it (`Book.MetadataEdit`): the library's change is
/// neither put back nor counted as the user's.
///
/// An episode or article in its feed has no editor here (FR11,
/// `Book.hasReadOnlyBookInfo`): its Book Info is read-only, as in the
/// Library.
struct ReaderBookInfoSheet: View {
    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        if viewModel.book.hasReadOnlyBookInfo {
            FeedItemBookInfoSheet(
                book: viewModel.book,
                info: viewModel.audioMetadata.map { .audio($0, isCloudOnly: false) } ?? .simple,
                feedTitle: viewModel.libraryViewModel.feedTitle(of: viewModel.book)
            )
        } else if let metadata = viewModel.epubMetadata {
            MetadataEditorView(
                metadata: metadata,
                isEPUB: viewModel.book.format == .epub,
                handEdits: viewModel.book.handEdits,
                onSave: { edited, opened, writeToFile in
                    viewModel.saveEPUBMetadata(edited, openedAs: opened, writeToFile: writeToFile)
                }
            )
        } else if let audioMeta = viewModel.audioMetadata {
            MetadataEditorView(
                audioMetadata: audioMeta,
                handEdits: viewModel.book.handEdits,
                book: viewModel.book,
                onSave: { edited, opened in
                    viewModel.saveAudioMetadata(edited, openedAs: opened)
                }
            )
        } else {
            // Plain text, Markdown, HTML: the simple info editor, which
            // reads the book's record of hand edits itself.
            LibraryBookInfoSheet(
                book: viewModel.book,
                libraryViewModel: viewModel.libraryViewModel
            )
        }
    }
}

/// The menu commands that open and close the reader's panels: Headings,
/// Bookmarks, Sleep Timer, and Search toggle theirs, and Book Info opens
/// its own. The reader is read only when a command arrives, so it is not
/// observed.
struct ReaderPanelCommands: ViewModifier {
    /// The reader the panels belong to.
    let viewModel: ReaderViewModel
    @Binding var panels: ReaderPanels

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showHeadingList)) { notification in
                guard shouldAcceptPanelCommand(notification) else { return }
                panels.headings.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBookmarkList)) { notification in
                guard shouldAcceptPanelCommand(notification) else { return }
                panels.bookmarks.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSleepTimer)) { notification in
                guard shouldAcceptPanelCommand(notification) else { return }
                panels.sleepTimer.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchInBook)) { notification in
                guard shouldAcceptPanelCommand(notification) else { return }
                if viewModel.canSearchText {
                    panels.search.toggle()
                } else if viewModel.isAudioBook, viewModel.content != nil {
                    // A loaded audiobook with no transcript text has only
                    // spacing that counts time, which the toolbar offers no
                    // Search for; the menu command says why rather than
                    // staying silent: that it has no transcript, and the
                    // command that makes one, or, for a transcript whose text
                    // is not shown, why not.
                    viewModel.announceNoTextToSearch(
                        hasTranscript: TranscribedBooks.shared.contains(viewModel.book.id)
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goBack)) { notification in
                // Go Back returns a reader to where it was before a jump from
                // a panel (a search result, a heading, a bookmark). Only the
                // reader that takes the command acts, as for the panels; a
                // Library window takes the same command for its folders.
                guard shouldAcceptPanelCommand(notification) else { return }
                viewModel.goBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBookInfo)) { notification in
                // Only open in the focused reader window
                if let sourceWindow = notification.userInfo?["sourceWindow"] as? PlatformWindow {
                    guard sourceWindow === viewModel.hostWindow else { return }
                } else {
                    guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
                }
                panels.bookInfo = true
            }
    }

    /// Accept panel commands from the reader window itself or from a sheet
    /// attached to that reader. This makes each panel's opening shortcut a
    /// reliable toggle while preserving correct routing between book windows.
    private func shouldAcceptPanelCommand(_ notification: Notification) -> Bool {
        WindowCommandRouting.shouldAccept(
            sourceWindow: notification.userInfo?["sourceWindow"] as? PlatformWindow,
            hostWindow: viewModel.hostWindow,
            keyWindow: PlatformApplication.keyWindow
        )
    }
}

// MARK: - Cloud Download (FR02)

/// What a reader window shows in place of its book while it gets the book
/// from the cloud (FR02): the download under way, whose progress bar
/// VoiceOver lands on, or why the book isn't ready and what can be done.
/// Every value is spoken as well as shown, and every button is labelled and
/// reachable from the keyboard.
struct ReaderCloudPhaseView: View {
    /// What the view's buttons do.
    struct Actions {
        /// Cancel: stops waiting for the download.
        let cancel: () -> Void
        /// Download: downloads the book again after a cancel.
        let download: () -> Void
        /// Try Again: opens the book afresh.
        let tryAgain: () -> Void
        /// Close: closes the reader's window.
        let close: () -> Void
    }

    let phase: ReaderCloudPhase
    /// The book's title.
    let title: String
    /// The sync service holding the library, when known.
    let provider: CloudProvider?
    let actions: Actions

    var body: some View {
        Group {
            switch phase {
            case .downloading(let download):
                ReaderDownloadProgressView(download: download, title: title, onCancel: actions.cancel)
            case .notDownloaded:
                ReaderCloudMessageView(
                    symbol: "icloud.and.arrow.down",
                    message: ReaderCloudWording.notDownloaded(title: title),
                    primaryTitle: "Download",
                    primaryHint: "Downloads the book again",
                    onPrimary: actions.download,
                    onClose: actions.close
                )
            case .failed(let failure):
                ReaderCloudMessageView(
                    symbol: "exclamationmark.icloud",
                    message: ReaderCloudWording.message(for: failure, title: title, provider: provider),
                    primaryTitle: "Try Again",
                    primaryHint: "Tries to get the book again",
                    onPrimary: actions.tryAgain,
                    onClose: actions.close
                )
            case .waitingForSync:
                ReaderCloudMessageView(
                    symbol: "arrow.clockwise.icloud",
                    message: ReaderCloudWording.waitingForSync(title: title, provider: provider),
                    primaryTitle: "Try Again",
                    primaryHint: "Looks for the book again",
                    onPrimary: actions.tryAgain,
                    onClose: actions.close
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A download under way: the heading "Downloading <title>", where it comes
/// from, a progress bar labelled "Download progress" whose value says how
/// far it has got, and Cancel (Escape). VoiceOver moves to the progress bar
/// when the view appears.
struct ReaderDownloadProgressView: View {
    let download: ReaderDownload
    /// The book's title.
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(ReaderCloudWording.heading(title: title))
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(ReaderCloudWording.source(provider: download.provider, chapterNumber: download.chapterNumber))
                .foregroundColor(.secondary)

            // The time waited steps every few seconds, so a value read by
            // VoiceOver or shown on a braille display does not churn.
            TimelineView(.periodic(from: download.startedAt, by: ReaderCloudWording.elapsedStep)) { context in
                let elapsed = ReaderCloudWording.elapsed(since: download.startedAt, at: context.date)
                VStack(spacing: 6) {
                    // One progress view, with no value while there is no
                    // percentage, so it stays the same element for
                    // VoiceOver whether or not it shows one.
                    ProgressView(value: ReaderCloudWording.fraction(of: download))
                        .progressViewStyle(.linear)
                        .accessibilityLabel(ReaderCloudWording.progressLabel)
                        .accessibilityValue(ReaderCloudWording.progressValue(of: download, elapsed: elapsed, spoken: true))
                        .modifier(InitialVoiceOverFocusModifier(isTarget: true))
                    // The bar's value, shown; VoiceOver hears it on the bar.
                    Text(ReaderCloudWording.progressValue(of: download, elapsed: elapsed, spoken: false))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
            }

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Stops waiting for the download")
        }
        .frame(maxWidth: 420)
    }
}

/// Why a book isn't ready to read: the reason, which VoiceOver moves to,
/// and a button to try once more (Return) beside Close.
struct ReaderCloudMessageView: View {
    /// The SF Symbol above the message; hidden from VoiceOver.
    let symbol: String
    /// What happened, shown and spoken.
    let message: String
    /// The title of the button that tries again.
    let primaryTitle: String
    /// What that button does, as VoiceOver hints it.
    let primaryHint: String
    let onPrimary: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))
            HStack(spacing: 12) {
                Button("Close", action: onClose)
                    .accessibilityHint("Closes this book's window")
                Button(primaryTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(primaryHint)
            }
        }
        .frame(maxWidth: 420)
    }
}

// MARK: - Per-Book Voice Picker

struct BookVoicePickerView: View {
    /// What the sheet shows of its reader: the voice, speed, pitch, or audio
    /// speed in force, the end-of-book choice, and whether the book has
    /// settings of its own (PERF30). The sheet draws again when this
    /// changes, and only then, rather than with each of the reader's
    /// publishes, about one a second while it plays. Its body reads the reader
    /// itself, whose values these are by the time it draws.
    struct ReaderState: Equatable {
        let title: String
        let isAudioBook: Bool
        let voiceIdentifier: String?
        let wordsPerMinute: Double
        let pitchMultiplier: Double
        let audioSpeed: Double
        let endOfBookBehavior: EndOfBookBehavior
        let hasLocalEndOfBookBehavior: Bool
        let hasLocalSettings: Bool

        /// What `reader` shows the sheet now.
        @MainActor
        init(of reader: ReaderViewModel) {
            title = reader.book.title
            isAudioBook = reader.isAudioBook
            voiceIdentifier = reader.speechService.currentVoice?.identifier
            wordsPerMinute = reader.speechService.wordsPerMinute
            pitchMultiplier = reader.speechService.pitchMultiplier
            audioSpeed = reader.audioSpeed
            endOfBookBehavior = reader.effectiveEndOfBookBehavior
            hasLocalEndOfBookBehavior = reader.book.localEndOfBookBehavior != nil
            hasLocalSettings = reader.hasLocalSettings
        }
    }

    /// The reader whose voice, speed, and pitch the sheet sets. Not
    /// observed: the sheet follows `shown` instead (PERF30).
    let viewModel: ReaderViewModel
    /// What the sheet shows of the reader, republished only when it changes.
    @StateObject private var shown: ReaderSnapshot<ReaderState>
    /// The installed voices, listed once and shared (TODO PERF07), observed
    /// so the pickers fill as soon as the list arrives.
    @ObservedObject private var voiceCatalog = VoiceCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLanguage: String = ""
    /// The synthesizer that previews a voice, made at the first preview: a
    /// default value would make one each time the sheet is made, that is
    /// each time the reader view presenting it draws (PERF30).
    @State private var previewSynthesizer: AVSpeechSynthesizer?

    /// A sheet that sets `viewModel`'s voice, speed, and pitch, or an
    /// audiobook's speed, and what happens when the book ends.
    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _shown = StateObject(wrappedValue: ReaderSnapshot(of: viewModel, ReaderState.init(of:)))
    }

    var body: some View {
        let _ = ViewBodyCounter.record("BookVoicePickerView")
        VStack(spacing: 16) {
            Text(BookSettingsWording.heading(isAudioBook: viewModel.isAudioBook))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                if viewModel.isAudioBook {
                    // Audio settings use multipliers throughout; the TTS
                    // voice, WPM, and pitch controls would otherwise write
                    // incompatible local state, so none of them appear here.
                    Section("Audio Speed") {
                        audioSpeedSlider
                    }
                } else {
                    Section {
                        Picker("Language", selection: $selectedLanguage) {
                            Text("All").tag("")
                            ForEach(availableLanguages, id: \.self) { lang in
                                Text(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                                    .tag(lang)
                            }
                        }
                        .accessibilityLabel("Voice language filter")

                        Picker("Voice", selection: Binding(
                            get: { viewModel.speechService.currentVoice?.identifier ?? "" },
                            set: { id in
                                if let voice = AVSpeechSynthesisVoice(identifier: id) {
                                    viewModel.setLocalVoice(voice)
                                }
                            }
                        )) {
                            ForEach(filteredVoices, id: \.identifier) { voice in
                                HStack {
                                    Text(voice.name)
                                    Text("(\(voiceQualityLabel(voice)))")
                                        .foregroundColor(.secondary)
                                }
                                .tag(voice.identifier)
                                .accessibilityLabel("\(voice.name), \(voiceQualityLabel(voice)) quality")
                            }
                        }
                        .accessibilityLabel("Select voice for this book")

                        Button("Preview Voice") {
                            previewVoice()
                        }
                        .accessibilityLabel("Preview selected voice")
                    } header: {
                        Text("Voice")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        // The speed for the eye; VoiceOver hears it once, as
                        // the slider's value (TODO A10).
                        Text("Speed: \(Int(viewModel.speechService.wordsPerMinute)) WPM")
                            .accessibilityHidden(true)

                        Slider(
                            value: Binding(
                                get: { viewModel.speechService.wordsPerMinute },
                                set: { newWPM in
                                    let clamped = max(50, min(newWPM, 650))
                                    let delta = clamped - viewModel.speechService.wordsPerMinute
                                    if abs(delta) >= 1 {
                                        viewModel.adjustSpeed(delta: delta)
                                    }
                                }
                            ),
                            in: 50...650,
                            step: 25
                        ) {
                            Text("Words per minute")
                        }
                        // VoiceOver says the control's kind itself, so the
                        // label names the setting alone (TODO A10).
                        .accessibilityLabel("Speed")
                        .accessibilityValue("\(Int(viewModel.speechService.wordsPerMinute)) words per minute")
                    }
                } header: {
                    Text("Speed")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        // The pitch for the eye; VoiceOver hears it once, as
                        // the slider's value (TODO A10).
                        Text("Pitch: \(SpeechService.pitchLabel(viewModel.speechService.pitchMultiplier))")
                            .accessibilityHidden(true)

                        Slider(
                            value: Binding(
                                get: { viewModel.speechService.pitchMultiplier },
                                set: { newPitch in
                                    let clamped = SpeechService.clampedPitch(newPitch)
                                    if abs(clamped - viewModel.speechService.pitchMultiplier) >= 0.05 {
                                        viewModel.adjustPitch(to: clamped)
                                    }
                                }
                            ),
                            in: 0.5...2.0,
                            step: 0.1
                        ) {
                            Text("Pitch")
                        }
                        .accessibilityLabel("Pitch")
                        .accessibilityValue(SpeechService.pitchLabel(viewModel.speechService.pitchMultiplier))
                    }
                } header: {
                    Text("Pitch")
                }
                }

                Section {
                    Picker("When this book ends", selection: Binding(
                        get: { viewModel.effectiveEndOfBookBehavior },
                        set: { viewModel.setLocalEndOfBookBehavior($0) }
                    )) {
                        ForEach(EndOfBookBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.rawValue).tag(behavior)
                        }
                    }
                    .accessibilityLabel("End of book behavior for this book")

                    if viewModel.book.localEndOfBookBehavior != nil {
                        Button("Use Global Default") {
                            viewModel.setLocalEndOfBookBehavior(nil)
                        }
                        .accessibilityLabel("Reset to global end-of-book setting")
                    }
                } header: {
                    Text("End of Book")
                }

                Section {
                    if !viewModel.isAudioBook {
                        Button(BookSettingsWording.saveButtonTitle) {
                            viewModel.saveSettingsToGlobal()
                        }
                        // The playback bar's button says the same: both
                        // copy the voice, speed, and pitch (TODO A10).
                        .accessibilityLabel(BookSettingsWording.saveAsDefaultsLabel)
                        .accessibilityHint(BookSettingsWording.saveAsDefaultsHint)
                    }

                    if viewModel.hasLocalSettings {
                        Button(BookSettingsWording.resetButtonTitle(isAudioBook: viewModel.isAudioBook)) {
                            viewModel.resetToGlobalSettings()
                        }
                        .accessibilityLabel(BookSettingsWording.resetLabel(isAudioBook: viewModel.isAudioBook))
                        .accessibilityHint(BookSettingsWording.resetHint(isAudioBook: viewModel.isAudioBook))
                    }
                }
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
        .frame(width: 450, height: 600)
        .navigationTitle(BookSettingsWording.title(isAudioBook: viewModel.isAudioBook, bookTitle: viewModel.book.title))
        .onAppear {
            // Default to the current voice's language
            if let voice = viewModel.speechService.currentVoice {
                selectedLanguage = String(voice.language.prefix(2))
            }
            // Should the sheet come before the first Library window.
            voiceCatalog.loadIfNeeded()
        }
    }

    /// An audiobook's speed, set with one slider as a text book's is
    /// (TODO A11). A stepper beside it did the same thing, and a line of
    /// text read the speed to VoiceOver a third time. The slider moves by
    /// `AudioSpeed.fineStep`, and VoiceOver reads it once: "Audio speed,
    /// 1.25 times speed", then the step as its hint. The speed shown above
    /// it is for the eye alone, as on a text book's sheet.
    ///
    /// On macOS the slider is an AppKit cell. SwiftUI copies an explicit
    /// `accessibilityLabel` onto it, but not the label view, so the label
    /// is repeated. `accessibilityValue` becomes the AXValueDescription that
    /// VoiceOver speaks instead of the cell's bare number.
    private var audioSpeedSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The speed for the eye; VoiceOver hears it once, as the
            // slider's value.
            Text("Speed: \(AudioSpeed.visibleLabel(for: viewModel.audioSpeed))")
                .accessibilityHidden(true)

            Slider(value: audioSpeedBinding, in: AudioSpeed.range, step: AudioSpeed.fineStep) {
                Text(BookSettingsWording.audioSpeedLabel)
            }
            .accessibilityLabel(BookSettingsWording.audioSpeedLabel)
            .accessibilityValue(AudioSpeed.spokenLabel(for: viewModel.audioSpeed))
            .accessibilityHint(AudioSpeed.stepHint(AudioSpeed.fineStep))
        }
    }

    /// The binding behind the audio speed slider. Writes go through
    /// `setAudioSpeed(_:)`, which snaps, clamps, applies, saves, and announces
    /// the speed, so the playback bar and toolbar caption update at once.
    /// Internal (not private) so hosted tests can drive exactly what the
    /// slider does.
    var audioSpeedBinding: Binding<Double> {
        Binding(
            get: { viewModel.audioSpeed },
            set: { viewModel.setAudioSpeed($0) }
        )
    }

    /// The languages the Language picker offers: the shared catalog's, read
    /// rather than listed each time the sheet draws (TODO PERF07).
    private var availableLanguages: [String] {
        voiceCatalog.languages
    }

    /// The voices the Voice picker offers for the language chosen, every
    /// voice when none is, from the shared catalog (TODO PERF07).
    private var filteredVoices: [AVSpeechSynthesisVoice] {
        voiceCatalog.voices(forLanguage: selectedLanguage)
    }

    private func voiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        voice.qualityLabel
    }

    /// Speaks a sample in the voice, speed, and pitch chosen, with the
    /// sheet's own synthesizer, made the first time.
    private func previewVoice() {
        let synthesizer = previewSynthesizer ?? AVSpeechSynthesizer()
        previewSynthesizer = synthesizer
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hello! This is how I'll read for you.")
        utterance.voice = viewModel.speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(viewModel.speechService.wordsPerMinute)
        utterance.pitchMultiplier = Float(SpeechService.clampedPitch(viewModel.speechService.pitchMultiplier))
        synthesizer.speak(utterance)
    }
}

/// The voice sheet's only input is its reader (PERF30).
extension BookVoicePickerView: SheetOverOneReader {}

/// Every word a book's own settings say: the reader's settings sheet
/// (`BookVoicePickerView`), the toolbar button that opens it, the Save and
/// Reset buttons, and the playback bar's save button.
///
/// - The sheet is a text book's voice, speed, and pitch, or an audiobook's
///   audio settings. The user asked on October 10 (TODO A11) that the
///   audiobook's be named "audio settings", since the sheet holds more than
///   the speed it was named for. Its button says the same words on screen
///   and to VoiceOver.
/// - The playback bar's save button and the sheet's Save to Global Settings
///   both run `ReaderViewModel.saveSettingsToGlobal()`, which copies the
///   book's voice, speed, and pitch, so both name all three (TODO A10; the
///   bar's said "speed" and the sheet's "voice and speed"). The sheet's
///   Reset to Global Settings, which clears all three, says so too.
enum BookSettingsWording {
    /// An audiobook's sheet: the button's title, its VoiceOver label, and
    /// the sheet's name.
    private static let audioSettings = "Audio Settings"

    /// The sheet's name, which begins its heading and its title: "Audio
    /// Settings", or a text book's "Voice & Speed".
    private static func sheetName(isAudioBook: Bool) -> String {
        isAudioBook ? audioSettings : "Voice & Speed"
    }

    /// The toolbar button's title: "Audio Settings", or a text book's
    /// "Voice".
    static func buttonTitle(isAudioBook: Bool) -> String {
        isAudioBook ? audioSettings : "Voice"
    }

    /// What VoiceOver calls the toolbar button: an audiobook's is its title.
    static func buttonLabel(isAudioBook: Bool) -> String {
        isAudioBook ? audioSettings : "Change voice for this book"
    }

    /// The heading at the top of the sheet: "Audio Settings for This Book".
    static func heading(isAudioBook: Bool) -> String {
        "\(sheetName(isAudioBook: isAudioBook)) for This Book"
    }

    /// The sheet's title, naming the book: "Audio Settings: " and the title.
    static func title(isAudioBook: Bool, bookTitle: String) -> String {
        "\(sheetName(isAudioBook: isAudioBook)): \(bookTitle)"
    }

    /// The audiobook speed slider's label, which VoiceOver reads before the
    /// speed: "Audio speed, 1.25 times speed".
    static let audioSpeedLabel = "Audio speed"

    // MARK: Saving and resetting

    /// The sheet's Save to Global Settings button's title (a text book's
    /// only; an audiobook's sheet has no such button).
    static let saveButtonTitle = "Save to Global Settings"

    /// The save buttons' VoiceOver label.
    static let saveAsDefaultsLabel = "Save this book's voice, speed, and pitch as the global defaults"

    /// The save buttons' hint, and the bar's tooltip: what saving does.
    static let saveAsDefaultsHint = "Updates the default voice, speed, and pitch for every book without settings of its own."

    /// The sheet's Reset button's title: an audiobook's "Reset to Normal
    /// Speed", or a text book's "Reset to Global Settings".
    static func resetButtonTitle(isAudioBook: Bool) -> String {
        isAudioBook ? "Reset to Normal Speed" : "Reset to Global Settings"
    }

    /// The VoiceOver label of a text book's Reset to Global Settings.
    static let resetToDefaultsLabel = "Reset this book's voice, speed, and pitch to the global defaults"

    /// A text book's Reset hint: what resetting does.
    static let resetToDefaultsHint = "Removes this book's own voice, speed, and pitch, so it uses the global defaults."

    /// What VoiceOver calls the sheet's Reset button: an audiobook's "Reset
    /// to normal audio speed", or a text book's `resetToDefaultsLabel`.
    static func resetLabel(isAudioBook: Bool) -> String {
        isAudioBook ? "Reset to normal audio speed" : resetToDefaultsLabel
    }

    /// The sheet's Reset button's hint: an audiobook's names the speed it
    /// resets to, a text book's is `resetToDefaultsHint`.
    static func resetHint(isAudioBook: Bool) -> String {
        isAudioBook
            ? "Resets this book to \(AudioSpeed.spokenLabel(for: AudioSpeed.normal))"
            : resetToDefaultsHint
    }

    /// What VoiceOver is told once a text book's reset has run; it names
    /// all three settings the reset clears, as the button does.
    static let resetDone = "Using global voice, speed, and pitch settings"
}

// MARK: - Book Info Bar

/// The strip above the reader text showing progress, the page (PG03, for a
/// book with pages, while the setting that shows it is on), time-remaining,
/// total time, and (when active) the sleep timer. The percent, page, and
/// time-remaining labels are buttons — clicking one expands a collapsible
/// jump panel below the bar with a field for jumping to a specific point
/// (`ReaderJumpPanels.swift`). The "Total" label and the sleep timer
/// indicator are non-interactive (no jump UI; that would just duplicate the
/// percent / time-remaining flows). Go to Page… opens the page panel even
/// while the page button is not drawn.
struct BookInfoBar: View {
    @ObservedObject var viewModel: ReaderViewModel
    /// The settings, observed so the time left and the total follow the
    /// setting that names their speed beside them at once (P08).
    @ObservedObject private var settingsViewModel: SettingsViewModel

    /// The status row of `viewModel`'s reader.
    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        self.settingsViewModel = viewModel.settingsViewModel
    }

    /// Mutually-exclusive expansion state — clicking percent collapses
    /// any open time or page panel and vice-versa, so the bar never grows by
    /// two panel-heights at once. Nil means everything collapsed.
    @State private var expandedPanel: ExpandedPanel?

    enum ExpandedPanel {
        case percent
        case page
        case time
    }

    var body: some View {
        let _ = ViewBodyCounter.record("BookInfoBar")
        VStack(spacing: 0) {
            statusRow
            if expandedPanel == .percent {
                JumpToPercentPanel(
                    viewModel: viewModel,
                    onJump: { expandedPanel = nil },
                    onCancel: { expandedPanel = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if expandedPanel == .page {
                // Shown whether or not the page button is drawn, so Go to
                // Page… works with the setting that shows the page off.
                JumpToPagePanel(
                    viewModel: viewModel,
                    focusRequests: viewModel.goToPageRequests,
                    onJump: { expandedPanel = nil },
                    onCancel: { expandedPanel = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if expandedPanel == .time {
                JumpToTimePanel(
                    viewModel: viewModel,
                    onJump: { expandedPanel = nil },
                    onCancel: { expandedPanel = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
        // Go to Page… (PG03): opens the page panel, and never closes it; a
        // request made while it is open puts the keyboard back in its field.
        .onChange(of: viewModel.goToPageRequests) { _, _ in
            withAnimation(.easeInOut(duration: 0.15)) { expandedPanel = .page }
        }
        // A book that no longer has pages to move by has no page panel to
        // leave open.
        .onChange(of: viewModel.hasSeveralPages) { _, hasSeveralPages in
            if !hasSeveralPages && expandedPanel == .page { expandedPanel = nil }
        }
    }

    /// The status row — percent / time-remaining / total / sleep
    /// timer. The first two are buttons; the rest are read-only.
    private var statusRow: some View {
        HStack(spacing: 16) {
            // Progress percentage — click to open jump-to-percent
            Button {
                togglePanel(.percent)
            } label: {
                Label {
                    Text(viewModel.displayFormattedPercentComplete)
                } icon: {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.blue)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(viewModel.displayFormattedPercentComplete) through the book")
            .accessibilityHint(percentButtonHint)

            // The page — click to open jump-to-page (PG03). Drawn for a book
            // with more than one page while the setting that shows it is on.
            if settingsViewModel.showsPageInReader && viewModel.hasSeveralPages {
                Button {
                    togglePanel(.page)
                } label: {
                    Label {
                        Text(viewModel.displayPagePosition.label)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundColor(.purple)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(viewModel.displayPagePosition.label)
                .accessibilityHint(pageButtonHint)
            }

            // Time remaining — click to open jump-to-time. With the setting
            // on, it and the total name the speed they count at (P08).
            Button {
                togglePanel(.time)
            } label: {
                Label {
                    Text(ReaderTimeWording.timeLeftShown(viewModel.displayFormattedTimeRemaining, namedSpeed))
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ReaderTimeWording.timeLeftSpoken(viewModel.displayTimeRemaining, namedSpeed))
            .accessibilityHint(timeButtonHint)

            // Total book time — non-interactive
            Label {
                Text(ReaderTimeWording.totalShown(viewModel.formattedTotalTime, namedSpeed))
            } icon: {
                Image(systemName: "book.closed")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ReaderTimeWording.totalSpoken(viewModel.totalEstimatedTime, namedSpeed))

            Spacer()

            // Sleep timer status — non-interactive (managed via the
            // sleep timer sheet; clicking it would duplicate that flow).
            // The label observes the timer itself, so it moves each second
            // whether or not the reader publishes (`SleepTimerStatusLabel`).
            SleepTimerStatusLabel(timer: viewModel.sleepTimerService) { timer in
                Label {
                    Text(timer.formattedRemaining)
                } icon: {
                    Image(systemName: "moon.fill")
                        .foregroundColor(.orange)
                }
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityElement(children: .combine)
                // "Sleep timer: 4:59 remaining", or where a timer set for
                // a place in the book stops playback. The label holds the
                // time, so there is no value to read it again (TODO A10).
                .accessibilityLabel(timer.spokenLabel)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// The speed the time left and the total name beside them, or nil while
    /// the setting is off (`ReaderViewModel.namedListeningSpeed`).
    private var namedSpeed: ReaderTimeWording.ListeningSpeed? {
        viewModel.namedListeningSpeed
    }

    /// Mutual-exclusion expand/collapse with a small animation. Tapping
    /// the same panel that's already open collapses it.
    private func togglePanel(_ panel: ExpandedPanel) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedPanel == panel {
                expandedPanel = nil
            } else {
                expandedPanel = panel
            }
        }
    }

    /// VoiceOver hint for the percent button. Three states — closed,
    /// percent already open, the OTHER (time) panel open — each with a
    /// distinct sentence so the user always hears what activating the
    /// button will actually do. Previously the "open / hide" wording
    /// alone left the cross-switch case ambiguous: focusing the
    /// percent button while the time panel was open would say "Opens
    /// jump-to-percent" without acknowledging the side effect of
    /// closing the time panel.
    private var percentButtonHint: String {
        switch expandedPanel {
        case nil: return "Opens jump to percent controls"
        case .percent: return "Hides jump to percent controls"
        case .page, .time: return "Switches to jump to percent controls"
        }
    }

    /// Same three-state pattern as `percentButtonHint`, mirrored for
    /// the time button.
    private var timeButtonHint: String {
        switch expandedPanel {
        case nil: return "Opens jump to time controls"
        case .time: return "Hides jump to time controls"
        case .percent, .page: return "Switches to jump to time controls"
        }
    }

    /// Same three-state pattern, mirrored for the page button (PG03).
    private var pageButtonHint: String {
        switch expandedPanel {
        case nil: return ReaderPageWording.openHint
        case .page: return ReaderPageWording.hideHint
        case .percent, .time: return ReaderPageWording.switchHint
        }
    }
}
