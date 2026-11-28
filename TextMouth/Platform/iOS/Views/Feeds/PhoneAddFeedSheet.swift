import SwiftUI

/// Which element of the Add Feed sheet VoiceOver's focus is asked onto.
private enum PhoneAddFeedElement: Hashable, Sendable {
    /// The address field, where the sheet opens.
    case address
    /// One of the feeds a web page names, by its place in the list; the first is where the second step opens.
    case link(Int)
    /// The row naming the folder the feed's own folder goes in, which a choice returns to.
    case folderRow
}

/// The Add Feed sheet on the iPhone (FR53, phase F1), over the Mac's own
/// `AddFeedModel` and in the Mac's words (`FeedWording`): the address, a
/// search of the podcast directory, and where the feed's folder goes.
///
/// VoiceOver's order: the heading "Add Feed", Cancel, the address field, which
/// takes focus as the sheet opens, its help line, Subscribe, the row naming
/// the folder, the search field and its button, then what the search found,
/// each podcast one element that subscribes to it. A web page that names
/// several feeds turns the sheet to a list of them, each one element marked
/// selected when chosen, then Back and Subscribe. A failure and what the sheet
/// is doing are read where they appear and said once through the model's own
/// announcements.
///
/// The model closes nothing: once the feed is subscribed to, `onSubscribed`
/// hands it to the owner, which closes the sheet and tells the listener.
struct PhoneAddFeedSheet: View {
    /// The sheet's work.
    @ObservedObject var model: AddFeedModel
    /// The library, for the places the feed's folder may go.
    let library: Library
    /// Which folders hold feeds, which are no place for another feed's folder.
    let feedFolders: LibraryFeedFolders
    /// Called once the feed is subscribed to; the owner closes the sheet.
    let onSubscribed: (Feed) -> Void
    /// Called on Cancel; the owner closes the sheet.
    let onCancel: () -> Void

    /// Where VoiceOver's focus is asked to go: on arrival, on the second step, and on return from the folder choice.
    @AccessibilityFocusState private var focus: PhoneAddFeedElement?
    /// Whether the keyboard is in the address field.
    @FocusState private var addressHasKeyboard: Bool
    /// Whether the list of places is showing.
    @State private var isChoosingFolder = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if model.isChoosing {
                        choiceStep
                    } else {
                        addressStep
                        folderSection(proxy: proxy)
                        searchSection
                    }
                    if model.failureMessage != nil || model.isWorking {
                        Section {
                            OperationFailureNotice(message: model.failureMessage)
                            if model.isWorking {
                                SheetWorkIndicator(label: FeedWording.checkingAddress)
                            }
                        }
                    }
                }
                .navigationTitle(FeedWording.addFeedTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PhoneSheetButton(title: FeedWording.cancelTitle) {
                        model.cancel()
                        onCancel()
                    }
                }
                // A subscription under way can't be swiped away: Cancel stops it.
                .interactiveDismissDisabled(model.isWorking)
                .clearingFailure($model.failureMessage, whenChanged: model.address)
                .clearingFailure($model.searchFailure, whenChanged: model.searchTerm)
                .clearingFailure($model.searchNote, whenChanged: model.searchTerm)
                .onChange(of: model.subscribedFeed) { _, feed in
                    if let feed {
                        onSubscribed(feed)
                    }
                }
                // A page that names several feeds replaces the address: focus goes to the first of them.
                .onChange(of: model.isChoosing) { _, choosing in
                    if choosing {
                        PhoneListFocus.focus(PhoneAddFeedElement.link(0), proxy: proxy, state: $focus)
                    }
                }
                // The places are a list of the app's own, never a menu, which wouldn't return focus (the spec, "Choices").
                .sheet(isPresented: $isChoosingFolder, onDismiss: {
                    PhoneListFocus.focus(PhoneAddFeedElement.folderRow, proxy: proxy, state: $focus)
                }) {
                    PhoneChoiceSheet(
                        title: FeedWording.folderCaption,
                        choices: places.map { PhoneChoice(id: $0.path, label: $0.label) },
                        selected: model.parentPath
                    ) { path in
                        model.parentPath = path
                    }
                }
                .task {
                    // A moment for the sheet to finish sliding in, then VoiceOver goes to the address, which takes the keyboard.
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    focus = .address
                    addressHasKeyboard = true
                }
            }
        }
    }

    // MARK: - The Address

    /// The address field, its help line, and Subscribe.
    private var addressStep: some View {
        Section {
            TextField(FeedWording.addressLabel, text: $model.address)
                .focused($addressHasKeyboard)
                .accessibilityFocused($focus, equals: .address)
                .id(PhoneAddFeedElement.address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { model.subscribe() }
                .disabled(model.isWorking)
                .accessibilityLabel(FeedWording.addressLabel)
                .accessibilityHint(FeedWording.addressHint)
            PhoneReadableCaption(FeedWording.addressHelp)
            PhoneActionButton(title: FeedWording.subscribeTitle) {
                model.subscribe()
            }
            .disabled(!model.canSubscribe)
        }
    }

    // MARK: - The Folder

    /// The places the feed's folder may go: the library's top and every folder that can hold one more, but a feed's own.
    private var places: [LibraryFolderOption] {
        AddFeedPlaces.parents(in: library, feedFolders: feedFolders)
    }

    /// What the folder named by `model.parentPath` is called.
    private var placeName: String {
        places.first { $0.path == model.parentPath }?.label ?? LibraryFolderOption.rootLabel
    }

    /// The row naming where the feed's folder goes, which opens the list of places, and the line saying what that means.
    private func folderSection(proxy: ScrollViewProxy) -> some View {
        Section {
            Button {
                isChoosingFolder = true
            } label: {
                PhoneValueRow(name: FeedWording.folderCaption, value: placeName)
            }
            .disabled(model.isWorking)
            .accessibilityLabel(FeedWording.folderLabel)
            .accessibilityValue(placeName)
            .accessibilityFocused($focus, equals: .folderRow)
            .id(PhoneAddFeedElement.folderRow)
            PhoneReadableCaption(FeedWording.folderHelp(parentPath: model.parentPath))
        }
    }

    // MARK: - The Second Step

    /// The feeds a web page names, to choose one, then Back and Subscribe.
    private var choiceStep: some View {
        Group {
            Section {
                Text(FeedWording.choosePrompt(count: model.links.count))
                    .phonePrimaryText()
                    .phoneWholeWords()
                ForEach(Array(model.links.enumerated()), id: \.offset) { index, link in
                    linkRow(link, at: index)
                }
            } header: {
                Text(FeedWording.chooseCaption)
                    .accessibilityAddTraits(.isHeader)
            }
            Section {
                PhoneActionButton(title: FeedWording.subscribeTitle) {
                    model.subscribe()
                }
                .disabled(!model.canSubscribe)
                PhoneActionButton(title: FeedWording.backTitle) {
                    model.back()
                }
                .disabled(model.isWorking)
            }
        }
    }

    /// One feed the page names, one element: its title and address, marked selected when it is the one chosen.
    private func linkRow(_ link: FeedLink, at index: Int) -> some View {
        Button {
            model.chosenLinkIndex = index
        } label: {
            HStack {
                Text(FeedWording.linkTitle(link))
                    .phonePrimaryText()
                    .phoneWholeWords()
                Spacer()
                // For sight alone: the selected trait says it.
                Image(systemName: model.chosenLinkIndex == index ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
        }
        .disabled(model.isWorking)
        .accessibilityAddTraits(model.chosenLinkIndex == index ? .isSelected : [])
        .accessibilityFocused($focus, equals: .link(index))
        .id(PhoneAddFeedElement.link(index))
    }

    // MARK: - Search

    /// The Search field and its button, then what the last search found: its podcasts, that it found none, or why it failed.
    private var searchSection: some View {
        Section {
            TextField(FeedWording.searchLabel, text: $model.searchTerm)
                .submitLabel(.search)
                .onSubmit { model.search() }
                .disabled(model.isWorking)
                .accessibilityLabel(FeedWording.searchLabel)
                .accessibilityHint(FeedWording.searchHint)
            PhoneActionButton(title: FeedWording.searchButtonTitle) {
                model.search()
            }
            .disabled(!model.canSearch)
            if model.isSearching {
                SheetWorkIndicator(label: FeedWording.searching)
            }
            if let note = model.searchNote {
                Text(note)
                    .phonePrimaryText()
                    .phoneWholeWords()
            }
            OperationFailureNotice(message: model.searchFailure)
            ForEach(model.searchResults) { result in
                resultRow(result)
            }
        } header: {
            // The results are the rows under this heading, which says how many when there are some.
            Text(model.searchResults.isEmpty ? FeedWording.searchLabel : FeedWording.searchResultsLabel(count: model.searchResults.count))
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// One podcast found, one element: its title, who publishes it, and how many episodes, which subscribes to it.
    private func resultRow(_ result: FeedDirectoryResult) -> some View {
        Button {
            model.subscribe(to: result)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.headline)
                    .phonePrimaryText()
                    .phoneWholeWords()
                if let details = FeedWording.searchResultDetails(result) {
                    Text(details)
                        .font(.subheadline)
                        .phoneSecondaryText()
                        .phoneWholeWords()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(model.isWorking)
        // The title and who publishes it, as the Mac's list reads a podcast; the hint says that pressing it subscribes.
        .accessibilityLabel(FeedWording.searchResultLabel(result))
        .accessibilityHint(FeedWording.subscribeToResultHint)
    }
}
