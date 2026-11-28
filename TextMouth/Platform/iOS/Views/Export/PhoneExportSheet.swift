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
/// folder picker when it closes. Focus on a row of the progress that goes as
/// the export moves, the Stop row above all, goes to what takes its place.
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
    enum Focus: Hashable {
        /// The switch of a kind.
        case kind(BookExportKind)
        /// The Convert to row of a kind.
        case format(BookExportKind)
        /// The folder row.
        case folder
        /// A braille row of a kind that opens a choice sheet.
        case braille(BookExportKind, PhoneExportOffer.BrailleChoice)
        /// A spoken audio row that opens a choice sheet.
        case speech(PhoneExportOffer.SpeechChoice)
        /// Share…, after an export.
        case share
        /// The Stop row, while the spoken audio file is made.
        case stopRow
        /// The progress row, while an export runs.
        case progress
        /// What the last export did.
        case finished

        /// The focus on `row` of the progress, which `PhoneExportOffer.focusAfterProgressMoves` names.
        init(_ row: PhoneExportOffer.ProgressFocus) {
            switch row {
            case .progress: self = .progress
            case .stopRow: self = .stopRow
            case .finished: self = .finished
            }
        }

        /// The row of the progress this is, nil for any other.
        var progressRow: PhoneExportOffer.ProgressFocus? {
            switch self {
            case .progress: return .progress
            case .stopRow: return .stopRow
            case .finished: return .finished
            case .kind, .format, .folder, .braille, .speech, .share: return nil
            }
        }
    }

    /// What of the export's progress the sheet shows: its stage, and whether the spoken audio file is being made, which
    /// brings the Stop row. Watched as one value, so that a change of both at once moves focus once.
    private struct ProgressShape: Equatable {
        let stage: PhoneExportOffer.Stage
        let isMakingSpeech: Bool
    }

    /// What the share sheet is given: the files an export wrote, and what lets go of their folder's scope.
    private struct SharedFiles: Identifiable {
        let id = UUID()
        /// The files written.
        let files: [URL]
        /// Lets go of the folder's security scope, once the share sheet is done.
        let letGo: @MainActor () -> Void
    }

    /// A choice sheet of the options rows, which the sheet presents from its list and not from a row (a row can scroll
    /// away, and take its presenter with it): a braille row's, or a spoken audio row's.
    private enum ChoiceRequest: Identifiable {
        case braille(PhoneBrailleExportRequest)
        case speech(PhoneSpeechExportRequest)

        var id: String {
            switch self {
            case .braille(let request): return "braille." + request.id
            case .speech(let request): return "speech." + request.id
            }
        }
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
    /// The export under way, which goes on with the sheet closed while the spoken audio file is made. Observed, so that
    /// Export, dimmed while another export runs, lights again when that one ends.
    @ObservedObject private var session: PhoneExportSession
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
    /// The files being shared, while the share sheet shows, with the folder's scope held for as long as it does: the
    /// files are in the folder the person chose, outside the app.
    @State private var sharing: SharedFiles?
    /// The options choice on show, if any. Presented from the list, not from a row (`PhoneBrailleExportRows`).
    @State private var choiceRequest: ChoiceRequest?
    /// Counts the changes the braille options announce, which is what draws the braille rows again.
    @State private var brailleChanges = 0
    /// The options row whose choices were last opened, which focus returns to when they close.
    @State private var choiceOpener: Focus?
    /// Whether a move of focus off a row of the progress that went is waiting its 0.35 seconds: a change of the progress
    /// meanwhile asks for no second move, since the one waiting picks its row as it fires.
    @State private var isMovingOffAGoneRow = false

    /// A sheet exporting `books`, as `library` holds them when Export is
    /// pressed. `beginHold` is what keeps the app running while an export
    /// does, a background task that locking the screen does not cut off.
    init(
        books: [Book],
        library: LibraryViewModel,
        beginHold: @escaping @MainActor (_ name: String) -> (@MainActor () -> Void),
        defaults: UserDefaults = TextMouthRuntime.current.preferences,
        session: PhoneExportSession = .shared
    ) {
        self.defaults = defaults
        self.session = session
        // Made once, when the sheet first appears: the kept folder's bookmark is resolved on the main thread, which
        // every redraw of the screen behind the sheet would otherwise do again.
        _model = StateObject(wrappedValue: Self.makeModel(books: books, library: library, beginHold: beginHold, defaults: defaults))
    }

    /// The model exporting `books`, starting with the folder kept, or the one a debug launch names.
    private static func makeModel(
        books: [Book],
        library: LibraryViewModel,
        beginHold: @escaping @MainActor (_ name: String) -> (@MainActor () -> Void),
        defaults: UserDefaults
    ) -> BookExportModel {
        let folder = startingFolder(in: defaults)
        return BookExportModel(
            books: books,
            library: library,
            destination: folder?.url,
            deepChapterPrompting: .standard,
            offering: PhoneExportOffer.kinds,
            destinationIsChosen: folder != nil,
            destinationName: folder?.name,
            delivery: .coordinatedCopy,
            memoryGuard: PhoneExportMemoryCheck.live,
            holdWhileExporting: { url in
                // The folder's scope and a background task, for as long as the
                // export runs.
                let letGoOfFolder = PhoneExportFolder.holdAccess(to: url)
                let endHold = beginHold("Exporting books") // l10n: no (a background task's name, in the system's diagnostics only)
                return {
                    endHold()
                    letGoOfFolder()
                }
            }
        )
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
            .sheet(item: $formatSheet, onDismiss: formatSheetClosed) { shown in
                formatChoices(for: shown.kind)
            }
            // The options' choices are presented, and the braille options heard, here and not on a row: a row can
            // scroll away, and take its presenter with it, at a large text size or on a small phone.
            .sheet(item: $choiceRequest, onDismiss: optionChoicesClosed) { request in
                optionChoices(for: request)
            }
            .onReceive(model.optionsChanged) { _ in brailleChanges &+= 1 }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: { folderPicked($0) },
                // A cancel never reaches `onCompletion`: without this, focus would not come back.
                onCancellation: { returnFocus(to: .folder) }
            )
        }
        // VoiceOver's escape gesture presses the bar's first button: Stop while an export runs, Close while the spoken audio
        // file is made, and otherwise Cancel or Close, as Escape does on the Mac. It is on the whole sheet and not on its
        // list, since focus stays in the bar once Export is pressed, and the bar is no part of the list.
        .accessibilityAction(.escape) { escape() }
        // No swipe may close the sheet while an export runs, unless it is making the spoken audio file, which goes on
        // without it: Stop does.
        .interactiveDismissDisabled(model.isExporting && !model.isMakingSpeech)
        .onChange(of: progressShape) { old, new in progressMoved(from: old, to: new) }
        .modifier(PhoneExportQuestionAlert(prompt: model.questionPrompt))
        // However the sheet closes, an export still under way stops, but one making the spoken audio file, which goes on
        // with a card in the Library.
        .onDisappear {
            if !session.letsGo(on: model) { model.stop() }
            session.sheetClosed(model)
        }
        .task { await arrive() }
    }

    // MARK: - The Bar

    /// Cancel, Stop, or Close, then Export, as `PhoneExportOffer.bar` decides.
    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
        let buttons = currentBar
        PhoneSheetButton(title: buttons.leading.title, hint: buttons.leading.hint, isEnabled: buttons.leading.isEnabled) {
            press(buttons.leading.role)
        }
        PhoneSheetButton(title: buttons.export.title, hint: buttons.export.hint, isEnabled: buttons.export.isEnabled) {
            press(buttons.export.role)
        }
    }

    /// The bar as the model's state decides it.
    private var currentBar: PhoneExportOffer.Bar {
        PhoneExportOffer.bar(
            stage: stage, canExport: model.canExport,
            isExportingSpeech: model.isExportingSpeech, isMakingSpeech: model.isMakingSpeech,
            anotherExportIsRunning: session.isBusy(for: model)
        )
    }

    /// What pressing a button of the bar does.
    private func press(_ role: PhoneExportOffer.BarButton.Role) {
        switch role {
        case .cancel, .close: dismiss()
        case .stop: model.stop()
        // The session runs the export, so that a spoken audio export has the system's continued task.
        case .export: Task { [session, model] in await session.export(model) }
        }
    }

    /// The escape gesture: Stop while an export runs, throughout, even where Close has taken Stop's place in the bar:
    /// stopping is the safe meaning of a gesture that says to get out, and it keeps what was spoken. Otherwise it is the
    /// bar's first button, Cancel or Close.
    private func escape() {
        if model.isExporting {
            model.stop()
        } else {
            press(currentBar.leading.role)
        }
    }

    /// The progress the sheet shows now.
    private var progressShape: ProgressShape {
        ProgressShape(stage: stage, isMakingSpeech: model.isMakingSpeech)
    }

    /// The export moved on. As the spoken audio file begins, Close takes Stop's place in the bar: focus moves to the Stop
    /// row, so that it never rests on a button whose meaning changed under it, and VoiceOver is then told that the sheet
    /// may close, once the focus has moved, so that what it reads of the row queues the words rather than cuts them off.
    /// Otherwise focus on a row of the progress that has just gone, the Stop row above all, which the sheet itself sent
    /// focus to, moves to what took its place (`PhoneExportOffer.focusAfterProgressMoves`). `focus` still names the row
    /// here: the row goes from VoiceOver's view only once this update is drawn. The row it moves to is picked as the focus
    /// moves, 0.35 seconds on (`PhoneExportOffer.progressRow(at:)`): a short file after the spoken audio can end the
    /// export within that wait, and the progress row with it.
    private func progressMoved(from old: ProgressShape, to new: ProgressShape) {
        if new.isMakingSpeech, !old.isMakingSpeech {
            returnFocus(to: .stopRow) { PhoneAnnouncer.say(PhoneExportWording.canCloseNow) }
            return
        }
        guard !isMovingOffAGoneRow,
              PhoneExportOffer.focusAfterProgressMoves(
                  from: focus?.progressRow, stage: new.stage, isMakingSpeech: new.isMakingSpeech
              ) != nil
        else { return }
        isMovingOffAGoneRow = true
        returnFocus(toWhicheverIs: {
            isMovingOffAGoneRow = false
            return PhoneExportOffer.progressRow(at: stage).map(Focus.init)
        })
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
        if kind == .spokenAudio {
            if model.isChecked(.spokenAudio) {
                PhoneSpeechExportRows(
                    making: model.speechOptionsMaking,
                    isExporting: model.isExporting,
                    focus: $focus,
                    open: { choice in
                        choiceOpener = .speech(choice)
                        choiceRequest = .speech(PhoneSpeechExportRequest(choice: choice))
                    }
                )
            }
        } else if let state = model.optionsState(for: kind), state.brailleOptions != nil {
            PhoneBrailleExportRows(
                kind: kind,
                state: state,
                choosesLineEnds: state.writerID == BRFExportWriter().id,
                isExporting: model.isExporting,
                revision: brailleChanges,
                focus: $focus,
                open: { choice in
                    choiceOpener = .braille(kind, choice)
                    choiceRequest = .braille(PhoneBrailleExportRequest(kind: kind, choice: choice))
                }
            )
        }
    }

    /// The sheet of the choice `request` asks for.
    @ViewBuilder
    private func optionChoices(for request: ChoiceRequest) -> some View {
        switch request {
        case .braille(let request):
            if let state = model.optionsState(for: request.kind) {
                PhoneBrailleExportChoices(state: state, choice: request.choice)
            }
        case .speech(let request):
            if let state = model.speechOptions {
                PhoneSpeechExportChoices(state: state, choice: request.choice)
            }
        }
    }

    /// An options choice closed: focus returns to the row that opened it.
    private func optionChoicesClosed() {
        guard let opener = choiceOpener else { return }
        choiceOpener = nil
        returnFocus(to: opener)
    }

    /// Stop, a row under the progress while the spoken audio file is made, where Close has taken its place in the bar: its
    /// hint says the chapters spoken are kept.
    @ViewBuilder
    private var stopRow: some View {
        if let stop = PhoneExportOffer.stopRow(stage: stage, isMakingSpeech: model.isMakingSpeech) {
            Button(stop.title) { model.stop() }
                .accessibilityHint(stop.hint)
                .accessibilityFocused($focus, equals: .stopRow)
        }
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
            folderName: model.isDestinationChosen ? model.shownFolderName : nil
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
        if case .success(let urls) = result, let picked = urls.first {
            // The name is read under the folder's scope, once, here (`PhoneExportFolder`), and kept for the row
            // and for the end of every export. A folder no bookmark could be made of is still this session's.
            let folder = PhoneExportFolder.keep(picked, in: defaults) ?? PhoneExportFolder(url: picked)
            model.chooseDestination(folder.url, named: folder.name)
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
                .accessibilityFocused($focus, equals: .progress)
                stopRow
            }
        }
    }

    /// What the last export did, in the Mac's sentence, until the next
    /// begins; or why Export refused the folder, which the Mac's dialog keeps
    /// in the same place.
    @ViewBuilder
    private var finishedSection: some View {
        if let words = model.finishedWords ?? model.summary {
            Section {
                Text(words)
                    .accessibilityFocused($focus, equals: .finished)
                shareButton
            }
        }
    }

    /// Share… under what the export did, once it has written a file: it opens the system's share sheet for the files just
    /// written, which are in the folder the person chose, so the folder's scope is held while it shows.
    @ViewBuilder
    private var shareButton: some View {
        if case .finished(let outcome) = model.phase,
           let share = PhoneExportOffer.shareButton(stage: stage, exportedCount: outcome.exported.count) {
            Button(share.title) {
                let letGo = PhoneExportFolder.holdAccess(to: outcome.destination)
                sharing = SharedFiles(files: outcome.exported, letGo: letGo)
            }
            .accessibilityHint(share.hint)
            .accessibilityFocused($focus, equals: .share)
            // Apple asks for a popover on an iPad, anchored to the button; on an iPhone it adapts to a sheet.
            .popover(item: $sharing) { shared in
                PhoneShareSheet(files: shared.files) {
                    shared.letGo()
                    sharing = nil
                }
            }
            .onChange(of: sharing == nil) { _, closed in
                if closed { returnFocus(to: .share) }
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
    /// alert has closed, or the row it was on has gone, after 0.35 seconds, by
    /// setting the focus state to nothing and then to the target, since setting
    /// the value it holds does nothing; then runs `afterwards`, as an
    /// announcement that is to follow what VoiceOver reads of the target.
    private func returnFocus(to target: Focus, then afterwards: (@MainActor () -> Void)? = nil) {
        returnFocus(toWhicheverIs: { target }, then: afterwards)
    }

    /// `returnFocus(to:then:)` for a target picked as the focus moves, when the wait is over: `target` gives it then, or
    /// nil for none, and nothing moves.
    private func returnFocus(toWhicheverIs target: @escaping @MainActor () -> Focus?, then afterwards: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            guard let row = target() else { return }
            focus = nil
            await Task.yield()
            focus = row
            afterwards?()
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
                    .keyboardShortcut(choice == .exportAsWritten ? .defaultAction : nil)
                }
            } message: { question in
                Text(question.message)
            }
        }
    }
}
