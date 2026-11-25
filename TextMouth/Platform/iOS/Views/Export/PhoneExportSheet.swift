import SwiftUI
import UniformTypeIdentifiers

/// The iPhone's Export sheet (FR31): the Mac's Export dialog rebuilt for the
/// phone over the same `BookExportModel`, in the Mac's words, for one book (a
/// folder's books come in a later phase).
///
/// VoiceOver's order: the title; Cancel (or Stop while an export runs, or
/// Close once one has ended) and Export, in the bar; "What to export", a
/// heading, then a switch for each kind, each followed, while it is on, by its
/// Convert to row and its options; the folder row; while an export runs, its
/// progress; and what the last export did. Focus lands on the first kind
/// 0.35 seconds after the books are listed, as the Mac's dialog starts on its
/// first checkbox, and returns to the row that opened a choice sheet or the
/// folder picker when it closes.
///
/// While an export runs the sheet cannot be swiped away, and VoiceOver's
/// escape gesture presses Stop, as Escape does on the Mac. Once it has ended
/// the sheet stays open and shows what it did, where the Mac's dialog closes:
/// on the phone, what is announced can also be read. The question about a
/// chapter nested too deeply (FR24) is an alert over the sheet.
///
/// Every word is the Mac's (`BookExportWording`, `PhoneExportOffer`); what is
/// decided about the bar, the stages, and the folder row is the plain types',
/// which the Mac's test host tests. Nothing here has run on a phone: VoiceOver's
/// order and focus, the folder picker over a sheet, and the alert are on the
/// hand-check list.
struct PhoneExportSheet: View {
    /// What VoiceOver's focus can be asked to go to.
    private enum Focus: Hashable {
        /// The switch of a kind.
        case kind(BookExportKind)
        /// The Convert to row of a kind.
        case format(BookExportKind)
        /// The folder row.
        case folder
    }

    /// A kind's Convert to choices, shown in a sheet of their own.
    private struct FormatSheet: Identifiable {
        /// The kind the choices are for.
        let kind: BookExportKind
        var id: String { kind.rawValue }
    }

    /// The dialog's state and the export, over the book's row as the library
    /// holds it.
    @StateObject private var model: BookExportModel
    /// The preferences the folder is kept in.
    private let defaults: UserDefaults
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Where VoiceOver's focus is asked to go.
    @AccessibilityFocusState private var focus: Focus?
    /// Whether the system's folder picker shows.
    @State private var isPickingFolder = false
    /// The Convert to choices on show, if any.
    @State private var formatSheet: FormatSheet?
    /// The kind whose Convert to choices were last opened, which focus returns
    /// to when they close.
    @State private var formatOpener: BookExportKind?

    /// A sheet exporting `books`, as `library` holds them when Export is
    /// pressed. `beginHold` is what keeps the app running while an export
    /// does, a background task that locking the screen does not cut off.
    init(
        books: [Book],
        library: LibraryViewModel,
        beginHold: @escaping @MainActor (_ name: String) -> (@MainActor () -> Void),
        defaults: UserDefaults = TextMouthRuntime.current.preferences
    ) {
        self.defaults = defaults
        let folder = Self.startingFolder(in: defaults)
        _model = StateObject(wrappedValue: BookExportModel(
            books: books,
            library: library,
            destination: folder?.url,
            deepChapterPrompting: .standard,
            offering: PhoneExportOffer.kinds,
            destinationIsChosen: folder != nil,
            delivery: .coordinatedCopy,
            memoryGuard: PhoneExportMemoryCheck.live,
            holdWhileExporting: { url in
                // The folder's scope and a background task, for as long as the
                // export runs.
                let letGoOfFolder = PhoneExportFolder(url: url).holdAccess()
                let endHold = beginHold("Exporting books") // l10n: no (a background task's name, in the system's diagnostics only)
                return {
                    endHold()
                    letGoOfFolder()
                }
            }
        ))
    }

    /// The folder the sheet starts with: the one kept, or, in a debug build
    /// launched by a UI test that names one, that folder (with no picker to
    /// drive). Nil when there is none, and the folder row asks for one.
    private static func startingFolder(in defaults: UserDefaults) -> PhoneExportFolder? {
        #if DEBUG
        if let folder = PhoneLaunchRequest.exportFolder(ProcessInfo.processInfo.environment) {
            return PhoneExportFolder(url: folder)
        }
        #endif
        return PhoneExportFolder.kept(in: defaults)
    }

    /// The sheet's stage.
    private var stage: PhoneExportOffer.Stage {
        PhoneExportOffer.Stage(model.phase)
    }

    var body: some View {
        NavigationStack {
            List {
                switch PhoneExportOffer.content(stage: stage, kindCount: model.choices.count) {
                case .listing:
                    ProgressView(BookExportWording.listing)
                        .progressViewStyle(.linear)
                case .nothingToExport:
                    Text(BookExportWording.nothingToExport)
                case .kinds:
                    kindsSection
                    folderSection
                }
                progressSection
                finishedSection
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { bar }
            // VoiceOver's escape gesture presses Stop while an export runs,
            // and otherwise closes the sheet, as Escape does on the Mac.
            .accessibilityAction(.escape) { escape() }
            .sheet(item: $formatSheet, onDismiss: formatSheetClosed) { shown in
                formatChoices(for: shown.kind)
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: { folderPicked($0) },
                // A cancel never reaches `onCompletion`: without this, focus would not come back.
                onCancellation: { returnFocus(to: .folder) }
            )
        }
        // No swipe may close the sheet while an export runs: Stop does.
        .interactiveDismissDisabled(model.isExporting)
        .modifier(PhoneExportQuestionAlert(prompt: model.questionPrompt))
        // However the sheet closes, an export still under way stops.
        .onDisappear { model.stop() }
        .task { await arrive() }
    }

    // MARK: - The Bar

    /// Cancel, Stop, or Close, then Export, as `PhoneExportOffer.bar` decides.
    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
        ForEach(PhoneExportOffer.bar(stage: stage, canExport: model.canExport), id: \.role) { button in
            PhoneSheetButton(title: button.title, hint: button.hint, isEnabled: button.isEnabled) {
                press(button.role)
            }
        }
    }

    /// What pressing a button of the bar does.
    private func press(_ role: PhoneExportOffer.BarButton.Role) {
        switch role {
        case .cancel, .close: dismiss()
        case .stop: model.stop()
        case .export: Task { await model.export() }
        }
    }

    /// The escape gesture: Stop while an export runs, else closing the sheet.
    private func escape() {
        if model.isExporting {
            model.stop()
        } else {
            dismiss()
        }
    }

    // MARK: - The Kinds

    /// "What to export", a heading, and a switch for each kind, with its
    /// Convert to row while it is on.
    private var kindsSection: some View {
        Section {
            ForEach(model.choices) { choice in
                Toggle(model.label(for: choice), isOn: checkedBinding(for: choice.kind))
                    .disabled(!choice.isAvailable || model.isExporting)
                    .accessibilityHint(model.hint(for: choice.kind))
                    .accessibilityFocused($focus, equals: .kind(choice.kind))
                if model.isChecked(choice.kind), !model.conversionChoices(for: choice.kind).isEmpty {
                    formatRow(for: choice.kind)
                }
                optionRows(for: choice.kind)
            }
        } header: {
            Text(BookExportWording.choicesLabel)
                .phoneSecondaryText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// A kind's switch, read from and written to the model.
    private func checkedBinding(for kind: BookExportKind) -> Binding<Bool> {
        Binding(
            get: { model.isChecked(kind) },
            set: { model.setChecked($0, for: kind) }
        )
    }

    /// The Convert to row of `kind`: a button named "Convert to" (or the
    /// kind's own name for it), valued with the choice, hinted with what the
    /// choice exports, which opens the choices.
    private func formatRow(for kind: BookExportKind) -> some View {
        let label = BookExportWording.convertToLabel(for: kind)
        let choice = model.conversionChoice(for: kind)
        return Button {
            formatOpener = kind
            formatSheet = FormatSheet(kind: kind)
        } label: {
            PhoneValueRow(name: label, value: choice?.name ?? "")
        }
        .disabled(model.isExporting)
        .accessibilityLabel(label)
        .accessibilityValue(choice?.name ?? "")
        .accessibilityHint(choice?.hint ?? "")
        .accessibilityFocused($focus, equals: .format(kind))
    }

    /// The options of the writer chosen beside `kind`, while it takes any:
    /// braille's rows for a BRF or a PEF.
    @ViewBuilder
    private func optionRows(for kind: BookExportKind) -> some View {
        EmptyView()
    }

    /// The sheet of `kind`'s Convert to choices, each with its hint.
    private func formatChoices(for kind: BookExportKind) -> some View {
        PhoneChoiceSheet(
            title: BookExportWording.convertToLabel(for: kind),
            choices: model.conversionChoices(for: kind).map { PhoneChoice(id: $0.id, label: $0.name, hint: $0.hint) },
            selected: model.conversionID(for: kind),
            onChoose: { model.setConversionID($0, for: kind) }
        )
    }

    /// The choices closed: focus returns to the row that opened them.
    private func formatSheetClosed() {
        guard let kind = formatOpener else { return }
        formatOpener = nil
        returnFocus(to: .format(kind))
    }

    // MARK: - The Folder

    /// The folder row: "Choose Folder…" until a folder is chosen, then
    /// "Export to:" and its name; it opens the system's folder picker.
    private var folderSection: some View {
        let row = PhoneExportOffer.folderRow(
            folderName: model.isDestinationChosen ? PhoneExportFolder.name(of: model.destination) : nil
        )
        return Section {
            Button {
                isPickingFolder = true
            } label: {
                Text(row.label)
                    .phonePrimaryText()
            }
            .disabled(model.isExporting)
            .accessibilityLabel(row.label)
            .accessibilityHint(row.hint)
            .accessibilityFocused($focus, equals: .folder)
        }
    }

    /// The picker returned a folder, or failed: a folder is kept for every
    /// later export and becomes the destination; focus returns to the row,
    /// which now names it. A failure of the picker says nothing more than the
    /// system did.
    private func folderPicked(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let folder = urls.first {
            PhoneExportFolder.keep(folder, in: defaults)
            model.chooseDestination(folder)
        }
        returnFocus(to: .folder)
    }

    // MARK: - Progress and the End

    /// The export's progress while one runs: a progress view labelled with the
    /// Mac's words, "Exporting 3 of 40 items…", whose value VoiceOver gives as
    /// a percent.
    @ViewBuilder
    private var progressSection: some View {
        if let text = model.progressText {
            Section {
                Group {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction, total: 1) { Text(text) }
                    } else {
                        ProgressView { Text(text) }
                    }
                }
                .progressViewStyle(.linear)
                .accessibilityLabel(text)
            }
        }
    }

    /// What the last export did, in the Mac's sentence, until the next
    /// begins.
    @ViewBuilder
    private var finishedSection: some View {
        if let words = model.finishedWords {
            Section {
                Text(words)
            }
        }
    }

    // MARK: - Focus

    /// Lists the books, then puts VoiceOver's focus on the first kind 0.35
    /// seconds later, as the Mac's dialog starts on its first checkbox.
    private func arrive() async {
        await model.load()
        guard let first = model.choices.first?.kind else { return }
        try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
        guard !Task.isCancelled else { return }
        focus = .kind(first)
    }

    /// Returns VoiceOver's focus to `target` once a sheet, a picker, or an
    /// alert has closed, after 0.35 seconds, by setting the focus state to
    /// nothing and then to the target, since setting the value it holds does
    /// nothing.
    private func returnFocus(to target: Focus) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = target
        }
    }
}

// MARK: - The Question About a Chapter Nested Too Deeply

/// Puts the export's question about a chapter nested too deeply (FR24) as an
/// alert over the sheet, while the model has one pending: the Mac's title and
/// message, which says what each button does since an iOS alert's buttons
/// have no hints, and the Mac's buttons. Any dismissal without a button, such
/// as VoiceOver's escape gesture, is Cancel Export.
private struct PhoneExportQuestionAlert: ViewModifier {
    /// The model's prompt; nil where nothing is asked.
    let prompt: PhoneExportQuestionPrompt?

    func body(content: Content) -> some View {
        if let prompt {
            content.modifier(Showing(prompt: prompt))
        } else {
            content
        }
    }

    /// The alert, observing the prompt.
    private struct Showing: ViewModifier {
        @ObservedObject var prompt: PhoneExportQuestionPrompt

        func body(content: Content) -> some View {
            content.alert(
                prompt.pending?.title ?? "",
                isPresented: Binding(
                    get: { prompt.pending != nil },
                    set: { if !$0 { prompt.dismiss() } }
                ),
                presenting: prompt.pending
            ) { question in
                ForEach(question.choices, id: \.self) { choice in
                    // Export as Written is the default: it only writes a new
                    // file and removes nothing. Cancel Export is the cancel role.
                    Button(choice.title, role: choice == .cancelExport ? .cancel : nil) {
                        prompt.answer(choice)
                    }
                }
            } message: { question in
                Text(question.message)
            }
        }
    }
}
