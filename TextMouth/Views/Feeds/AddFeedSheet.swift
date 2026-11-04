import SwiftUI

// MARK: - Subscribing (FR03)

/// The work of the Add Feed sheet (FR03): the address typed, a search of the
/// podcast directory, the folder the feed's own folder goes in, and
/// subscribing, with the second step that lists the feeds a web page names.
///
/// Subscribing makes a folder named after the feed inside the folder chosen
/// (`FeedFolderChoice.newFolder`), as the listener decided on October 4 ("a
/// new feed's folder goes anywhere: the same folder selector as the move
/// dialog"), and only once the feed has been read, so a failure leaves the
/// library as it was. A failure keeps the sheet, its address, and its
/// choices, and says why in the engine's words (`FeedSubscribeError.message`).
///
/// Search asks the podcast directory (`FeedCenter.searchDirectory(for:)`)
/// and lists what it found; a result's Subscribe puts its feed's address in
/// the address field and subscribes as Subscribe does for an address typed.
/// A search that finds nothing, or fails, says so in the sheet and to
/// VoiceOver.
@MainActor
final class AddFeedModel: ObservableObject, Identifiable {
    /// The address as typed or pasted.
    @Published var address = ""
    /// The words typed into Search.
    @Published var searchTerm = ""
    /// The podcasts the last search found, in the directory's order.
    @Published private(set) var searchResults: [FeedDirectoryResult] = []
    /// Whether a search runs now.
    @Published private(set) var isSearching = false
    /// What the sheet says when the last search found nothing, until the
    /// words change or another search starts.
    @Published var searchNote: String?
    /// Why the last search failed, until the words change or another search
    /// starts.
    @Published var searchFailure: String?
    /// The path of the folder the feed's folder goes in; "" for the
    /// library's top level.
    @Published var parentPath: String
    /// The feeds the web page at the address names, while the listener
    /// chooses one; empty at the first step.
    @Published private(set) var links: [FeedLink] = []
    /// Which of `links` is chosen, by its place in the list.
    @Published var chosenLinkIndex = 0
    /// Whether the address is being read now.
    @Published private(set) var isWorking = false
    /// Why the last attempt failed, until the listener changes the address
    /// or tries again.
    @Published var failureMessage: String?
    /// The feed subscribed to, once there is one.
    @Published private(set) var subscribedFeed: Feed?

    /// The engine subscribed through.
    let center: FeedCenter
    /// Speaks what the sheet says while it works, for VoiceOver.
    private let announce: @MainActor (String) -> Void
    /// The subscription under way, which Cancel stops.
    private var subscription: Task<Void, Never>?
    /// The search under way, which Cancel stops.
    private var searchWork: Task<Void, Never>?

    /// A sheet subscribing through `center`, putting the feed's folder in
    /// the folder at `parentPath`, and saying what happens through
    /// `announce`: VoiceOver, unless a test listens instead.
    init(
        center: FeedCenter,
        parentPath: String,
        announce: @escaping @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        self.center = center
        self.parentPath = parentPath
        self.announce = announce
    }

    /// Whether the sheet is at its second step, choosing among the feeds a
    /// page names.
    var isChoosing: Bool {
        !links.isEmpty
    }

    /// Whether Subscribe can run: not while the address is read, and only
    /// with an address that could name a feed, or a feed chosen.
    var canSubscribe: Bool {
        guard !isWorking else { return false }
        if isChoosing {
            return links.indices.contains(chosenLinkIndex)
        }
        return FeedAddress.normalized(address) != nil
    }

    /// Subscribes to the address, or to the feed chosen at the second step,
    /// and returns the work, which tests await. Does nothing while a
    /// subscription runs.
    @discardableResult
    func subscribe() -> Task<Void, Never>? {
        guard canSubscribe else { return nil }
        let target = isChoosing ? links[chosenLinkIndex].url.absoluteString : address
        let choice = FeedFolderChoice.newFolder(inParentPath: parentPath)
        failureMessage = nil
        isWorking = true
        announce(FeedWording.checkingAddress)
        let work = Task {
            defer { isWorking = false }
            do {
                switch try await center.subscribe(to: target, into: choice) {
                case .subscribed(let feed):
                    subscribedFeed = feed
                case .choose(let found):
                    links = found
                    chosenLinkIndex = 0
                    announce(FeedWording.choosePrompt(count: found.count))
                }
            } catch is CancellationError {
                // Cancel closed the sheet: nothing is left to say.
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? FeedSubscribeError)?.message ?? error.localizedDescription
                failureMessage = message
                announce(message)
            }
        }
        subscription = work
        return work
    }

    /// Goes back from the feeds a page names to the address.
    func back() {
        guard !isWorking else { return }
        links = []
        chosenLinkIndex = 0
        failureMessage = nil
    }

    /// Stops the subscription and the search under way, as the sheet closes
    /// on Cancel. A subscription whose feed has already been read may still
    /// finish.
    func cancel() {
        subscription?.cancel()
        subscription = nil
        searchWork?.cancel()
        searchWork = nil
    }

    // MARK: Searching

    /// Whether Search can run: with words to search for, and not while a
    /// search or a subscription runs.
    var canSearch: Bool {
        !isSearching && !isWorking && !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Searches the podcast directory for the words typed, says it is
    /// searching, and then lists the podcasts found and says how many, or
    /// says that none were found or why the search failed. Returns the work,
    /// which tests await; does nothing when Search can't run.
    @discardableResult
    func search() -> Task<Void, Never>? {
        guard canSearch else { return nil }
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = []
        searchNote = nil
        searchFailure = nil
        isSearching = true
        announce(FeedWording.searching)
        let work = Task {
            defer { isSearching = false }
            do {
                let found = try await center.searchDirectory(for: term)
                // Cancel closed the sheet meanwhile: nothing is left to say.
                guard !Task.isCancelled else { return }
                searchResults = found
                if found.isEmpty {
                    searchNote = FeedWording.noPodcastsFound(term: term)
                }
                announce(found.isEmpty ? FeedWording.noPodcastsFound(term: term) : FeedWording.podcastsFound(count: found.count, term: term))
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? FeedSearchError)?.message ?? error.localizedDescription
                searchFailure = message
                announce(message)
            }
        }
        searchWork = work
        return work
    }

    /// Subscribes to the podcast `result` names: its feed's address goes in
    /// the address field, and subscribing continues as for an address typed.
    /// Returns the work, which tests await; does nothing while a
    /// subscription runs, or at the second step, which lists no results.
    @discardableResult
    func subscribe(to result: FeedDirectoryResult) -> Task<Void, Never>? {
        guard !isWorking, !isChoosing else { return nil }
        address = result.feedURL.absoluteString
        return subscribe()
    }
}

// MARK: - The Sheet

/// The Add Feed sheet (FR03): an address field, which VoiceOver's focus and
/// the keyboard's start in; a Search field with its button, which lists the
/// podcasts the directory finds, each with a Subscribe button of its own;
/// the Move dialog's folder picker, choosing where the feed's own folder
/// goes, with New Folder; and Subscribe, which Return presses, and Cancel,
/// which Escape presses. In the Search field, Return presses Search instead,
/// and while the picker's New Folder fields are shown it presses their
/// Create, Subscribe standing down meanwhile, so one press does one thing;
/// Escape then closes the fields, Cancel standing down until they close.
/// One button at a time is the default: in the Search field, Search, even
/// with the fields shown, Create standing down meanwhile.
/// While the address is read the sheet says so; a web page naming several
/// feeds turns the sheet to a radio group of them; a failure stays in the
/// sheet, beside the address, and is announced.
struct AddFeedSheet: View {
    /// The sheet's work.
    @ObservedObject var model: AddFeedModel
    /// The library, for the folder picker's places.
    let library: Library
    /// Which folders hold feeds, which are no place for another feed's
    /// folder.
    let feedFolders: LibraryFeedFolders
    /// Makes a folder from a name and a parent path, as the Move dialog's
    /// New Folder does.
    let onCreateFolder: (String, String) -> OperationOutcome
    /// Called once the feed is subscribed to; the owner closes the sheet.
    let onSubscribed: (Feed) -> Void
    /// Called on Cancel; the owner closes the sheet.
    let onCancel: () -> Void

    /// Whether the address field has keyboard focus.
    @FocusState private var addressFocused: Bool
    /// Whether the Search field has keyboard focus, which gives Return to
    /// Search rather than to Subscribe.
    @FocusState private var searchFocused: Bool
    /// Why the last folder could not be made in the picker.
    @State private var folderFailure: String?
    /// Whether the picker's new-folder fields are showing, while Return
    /// presses their Create rather than Subscribe, and Escape closes them
    /// rather than the sheet.
    @State private var isMakingFolder: Bool

    /// A sheet doing `model`'s work in `library`, whose folder picker keeps
    /// off the folders `feedFolders` says hold feeds; `makingFolder` opens
    /// it with the new folder's fields already shown, as the tests of the
    /// Return key need.
    init(
        model: AddFeedModel,
        library: Library,
        feedFolders: LibraryFeedFolders,
        onCreateFolder: @escaping (String, String) -> OperationOutcome,
        onSubscribed: @escaping (Feed) -> Void,
        onCancel: @escaping () -> Void,
        makingFolder: Bool = false
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.library = library
        self.feedFolders = feedFolders
        self.onCreateFolder = onCreateFolder
        self.onSubscribed = onSubscribed
        self.onCancel = onCancel
        _isMakingFolder = State(initialValue: makingFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(FeedWording.addFeedTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if model.isChoosing {
                choiceStep
            } else {
                addressStep
            }

            OperationFailureNotice(message: model.failureMessage ?? folderFailure)

            if model.isWorking {
                SheetWorkIndicator(label: FeedWording.checkingAddress)
            }

            buttons
        }
        .padding()
        .frame(width: 480)
        .navigationTitle(FeedWording.addFeedTitle)
        .clearingFailure($model.failureMessage, whenChanged: model.address)
        .clearingFailure($model.searchFailure, whenChanged: model.searchTerm)
        .clearingFailure($model.searchNote, whenChanged: model.searchTerm)
        .onChange(of: model.subscribedFeed) { _, feed in
            if let feed {
                onSubscribed(feed)
            }
        }
        .onAppear {
            // After the sheet's own animation, as the search sheet does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                addressFocused = true
            }
        }
    }

    // MARK: Steps

    /// The address, a search of the podcast directory, and where the feed's
    /// folder goes.
    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FeedWording.addressLabel)
                .accessibilityHidden(true)
            TextField(FeedWording.addressLabel, text: $model.address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .disabled(model.isWorking)
                .accessibilityLabel(FeedWording.addressLabel)
                .accessibilityHint(FeedWording.addressHint)
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: 1.2))
            Text(FeedWording.addressHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            searchSection

            LibraryFolderPicker(
                options: AddFeedPlaces.parents(in: library, feedFolders: feedFolders),
                newFolderParents: AddFeedPlaces.newFolderParents(in: library, feedFolders: feedFolders),
                selection: $model.parentPath,
                caption: FeedWording.folderCaption,
                accessibilityLabel: FeedWording.folderLabel,
                onCreateFolder: onCreateFolder,
                failureMessage: $folderFailure,
                isDisabled: model.isWorking,
                isMakingFolder: $isMakingFolder,
                // Search takes Return while its field has the keyboard, so
                // Create stands down then: one default button at a time,
                // and Return in the Search field never makes a folder.
                createTakesReturn: !searchFocused
            )
            // A page naming several feeds replaces this step, picker and
            // all: its fields are gone, so Subscribe takes Return back.
            .onDisappear { isMakingFolder = false }
            Text(FeedWording.folderHelp(parentPath: model.parentPath))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The feeds a page names, to choose one.
    private var choiceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FeedWording.choosePrompt(count: model.links.count))
                .fixedSize(horizontal: false, vertical: true)
            Picker(FeedWording.chooseCaption, selection: $model.chosenLinkIndex) {
                ForEach(Array(model.links.enumerated()), id: \.offset) { index, link in
                    Text(FeedWording.linkTitle(link)).tag(index)
                }
            }
            .radioGroupPickerStyle()
            .disabled(model.isWorking)
            .accessibilityLabel(FeedWording.chooseLabel)
            .modifier(InitialVoiceOverFocusModifier(isTarget: true))
        }
    }

    // MARK: Search

    /// The Search field and its button, then what the last search found:
    /// its podcasts, that it found none, or why it failed.
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FeedWording.searchLabel)
                .accessibilityHidden(true)
            HStack {
                TextField(FeedWording.searchLabel, text: $model.searchTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .disabled(model.isWorking)
                    .accessibilityLabel(FeedWording.searchLabel)
                    .accessibilityHint(FeedWording.searchHint)
                Button(FeedWording.searchButtonTitle) {
                    model.search()
                }
                // Return in the Search field searches, and only there.
                .keyboardShortcut(searchFocused ? KeyboardShortcut.defaultAction : nil)
                .disabled(!model.canSearch)
            }
            if model.isSearching {
                SheetWorkIndicator(label: FeedWording.searching)
            }
            if let note = model.searchNote {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OperationFailureNotice(message: model.searchFailure)
            if !model.searchResults.isEmpty {
                searchResults
            }
        }
    }

    /// The podcasts the last search found, one row each, in a scrolling
    /// list VoiceOver reads as one group of rows.
    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.searchResults) { result in
                    searchResultRow(result)
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 8)
        }
        .frame(height: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FeedWording.searchResultsLabel(count: model.searchResults.count))
    }

    /// One podcast found: its title, then who publishes it and its episodes,
    /// read as one line, beside a Subscribe button that names it.
    private func searchResultRow(_ result: FeedDirectoryResult) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let details = FeedWording.searchResultDetails(result) {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FeedWording.searchResultLabel(result))
            Spacer()
            Button(FeedWording.subscribeTitle) {
                model.subscribe(to: result)
            }
            .disabled(model.isWorking)
            .accessibilityLabel(FeedWording.subscribeToResultLabel(result))
            .accessibilityHint(FeedWording.subscribeToResultHint)
        }
    }

    /// Cancel, Back at the second step, and Subscribe, which Return presses
    /// everywhere but in the Search field and while the new folder's fields
    /// are shown.
    private var buttons: some View {
        HStack {
            Button("Cancel") {
                model.cancel()
                onCancel()
            }
            // Escape cancels, except while the new folder's fields are
            // shown, when it closes them first (their Cancel New Folder)
            // and a second Escape cancels.
            .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut.cancelAction)
            Spacer()
            if model.isChoosing {
                Button(FeedWording.backTitle) {
                    model.back()
                }
                .disabled(model.isWorking)
            }
            Button(FeedWording.subscribeTitle) {
                model.subscribe()
            }
            // Return subscribes, except in the Search field, where it
            // searches, and while the new folder's fields are shown, when
            // it presses their Create.
            .keyboardShortcut(searchFocused || isMakingFolder ? nil : KeyboardShortcut.defaultAction)
            .disabled(!model.canSubscribe)
        }
    }
}

// MARK: - Where a Feed's Folder Can Go

/// The places Add Feed offers for a new feed's folder (FR03): the library's
/// top level and every folder a folder can still be made in, except a
/// feed's own folder, which lists its feed's items.
enum AddFeedPlaces {
    /// The places the pop-up offers: the top level, and each folder that is
    /// not a feed's and is shallow enough to hold one more.
    @MainActor
    static func parents(in library: Library, feedFolders: LibraryFeedFolders) -> [LibraryFolderOption] {
        LibraryFolderOption.options(in: library) { folder in
            folder.depth < BookFolder.maxDepth && !feedFolders.holdsFeed(folder)
        }
    }

    /// The folders New Folder may make a folder in here: those whose new
    /// folder could itself hold a feed's folder, never a feed's own.
    @MainActor
    static func newFolderParents(in library: Library, feedFolders: LibraryFeedFolders) -> [LibraryFolderOption] {
        LibraryFolderOption.options(in: library) { folder in
            folder.depth < BookFolder.maxDepth - 1 && !feedFolders.holdsFeed(folder)
        }
    }

    /// The place first chosen when the sheet opens in a window showing the
    /// folder at `shownPath` ("" when it shows the top level or no folder):
    /// that folder when it is offered, and otherwise the top level.
    @MainActor
    static func initialParent(shownPath: String, in library: Library, feedFolders: LibraryFeedFolders) -> String {
        parents(in: library, feedFolders: feedFolders).contains { $0.path == shownPath } ? shownPath : ""
    }
}
