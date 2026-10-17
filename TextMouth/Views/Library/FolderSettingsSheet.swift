import SwiftUI

/// The model of the Folder Settings sheet (FR19): one plain folder of the
/// library, its facts, and its two listening options. Nothing is kept here:
/// every value is read from the library each time, so a rename or a choice
/// made in another window shows, and every choice is saved through the
/// library at once, which stores nothing for the standard choices.
@MainActor
final class FolderSettingsModel: ObservableObject, Identifiable {
    /// The folder shown.
    let folderID: UUID
    /// The library holding the folder.
    let library: LibraryViewModel
    /// Which feeds have their folders inside the folder, for its facts.
    let feedFolders: LibraryFeedFolders
    /// The reading speed its time remaining is worked out at.
    let wordsPerMinute: Double
    /// The preferences the global "When book ends" is read from.
    private let defaults: UserDefaults

    /// Folder Settings for the folder `folderID` of `library`.
    init(
        folderID: UUID,
        library: LibraryViewModel,
        feedFolders: LibraryFeedFolders,
        wordsPerMinute: Double,
        defaults: UserDefaults = .standard
    ) {
        self.folderID = folderID
        self.library = library
        self.feedFolders = feedFolders
        self.wordsPerMinute = wordsPerMinute
        self.defaults = defaults
    }

    /// The folder as the library holds it now, so a rename shows; nil once
    /// it is gone.
    var folder: BookFolder? {
        library.library.folders.first { $0.id == folderID }
    }

    /// The folder's facts as Speak Info gathers them; nil once it is gone.
    var facts: FolderInfoFacts? {
        folder.map {
            FolderInfoFacts($0, library: library, feedFolders: feedFolders, wordsPerMinute: wordsPerMinute)
        }
    }

    /// The folder's options as they are saved: the standard ones for a
    /// folder with none of its own.
    private var options: ListeningOptions {
        library.listeningOptions(ofFolder: folderID) ?? .standard
    }

    /// What happens when a book of the folder ends; nil is "Use the global
    /// setting". A choice is saved at once.
    var continuation: ReadingList.Continuation? {
        get { options.continuation }
        set {
            var changed = options
            changed.continuation = newValue
            library.setListeningOptions(changed, ofFolder: folderID)
        }
    }

    /// Whether listening passes over the folder's finished books when it
    /// goes on to another. A choice is saved at once.
    var skipsFinished: Bool {
        get { options.skipsFinished }
        set {
            var changed = options
            changed.skipsFinished = newValue
            library.setListeningOptions(changed, ofFolder: folderID)
        }
    }

    /// The global "When book ends" setting, which "Use the global setting"
    /// follows and names.
    var globalEndOfBookBehavior: EndOfBookBehavior {
        SettingsPolicy.endOfBookBehavior.storedValue(in: defaults)
    }
}

/// The Folder Settings sheet (FR19): the folder's name as its heading, its
/// facts as read-only labelled values, the two listening options, and Done.
///
/// Each fact is one element to VoiceOver ("Books, 12 books, 3 unopened")
/// and plain text to a braille display. The pop-up button and the checkbox
/// are built as the Reading List's options bar builds its, so the keyboard
/// and VoiceOver reach them as they reach any other. Return and Escape both
/// press Done: nothing in the sheet takes typing, and every choice is
/// already saved.
struct FolderSettingsSheet: View {
    /// The folder shown.
    @ObservedObject var model: FolderSettingsModel
    /// The library, observed so a rename or a choice from another window
    /// shows.
    @ObservedObject private var library: LibraryViewModel
    /// The feeds' folders, observed so the count of feeds follows.
    @ObservedObject private var feedFolders: LibraryFeedFolders
    /// Closes the sheet.
    let onDone: () -> Void

    /// The sheet for `model`; `onDone` closes it.
    init(model: FolderSettingsModel, onDone: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _library = ObservedObject(wrappedValue: model.library)
        _feedFolders = ObservedObject(wrappedValue: model.feedFolders)
        self.onDone = onDone
    }

    /// What the folder's items are called: books.
    private let noun = ListeningOptionsWording.Noun.book

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let folder = model.folder, let facts = model.facts {
                Text(folder.name)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                // A fixed frame with a scrolling body: a sheet that
                // outgrows its window would crash a hosted test.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(FolderSettingsWording.facts(of: facts, parentPath: folder.parentPath), id: \.label) { fact in
                            FeedInfoValue(label: fact.label, value: fact.value)
                        }
                        Divider()
                        listeningOptions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(FolderSettingsWording.folderGone)
                Spacer()
            }
            HStack {
                Spacer()
                // Return presses Done; Escape reaches it through the key
                // equivalent below, since a button carries one shortcut.
                Button(FolderSettingsWording.done, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
        .navigationTitle(FolderSettingsWording.title)
        .background(SilentKeyEquivalent(key: .escape, action: onDone))
    }

    /// The "Listening" heading and the two options, each saved as it is
    /// chosen.
    private var listeningOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FolderSettingsWording.listeningHeading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            let label = ListeningOptionsWording.continuationLabel(noun)
            let hint = ListeningOptionsWording.continuationHint(noun)
            // The label is spoken from the control itself, as in the
            // Reading List's options bar: a pop-up button takes no label
            // from the picker's title.
            Picker(label, selection: Binding(
                get: { model.continuation },
                set: { model.continuation = $0 }
            )) {
                ForEach(ListeningOptions.continuationChoices, id: \.self) { choice in
                    Text(ListeningOptionsWording.continuationTitle(choice, noun: noun, global: model.globalEndOfBookBehavior))
                        .tag(choice)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(hint)
            .accessibilityLabel(label)
            .accessibilityHint(hint)

            let skipLabel = ListeningOptionsWording.skipFinishedLabel(noun)
            let skipHint = ListeningOptionsWording.skipFinishedHint(noun)
            Toggle(skipLabel, isOn: Binding(
                get: { model.skipsFinished },
                set: { model.skipsFinished = $0 }
            ))
            .toggleStyle(.checkbox)
            .help(skipHint)
            .accessibilityLabel(skipLabel)
            .accessibilityHint(skipHint)
        }
    }
}
