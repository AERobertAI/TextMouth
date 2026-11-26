import Foundation

/// What the iPhone's Export sheet offers and says at each stage of an export
/// (FR31), decided from plain values so the Mac's test host reads it: which
/// kinds the iPhone offers, which buttons the sheet's bar holds in which order,
/// and what its folder row says. Every word is the Mac's, called where it
/// lives (`BookExportWording`); the sheet only draws what is decided here.
enum PhoneExportOffer {
    // MARK: - What Is Offered

    /// The kinds the iPhone offers: every kind, spoken audio included, which goes on with the screen locked and the
    /// sheet closed as a continued processing task (`PhoneExportBackgroundTask`).
    static let kinds: Set<BookExportKind> = Set(BookExportKind.allCases)

    // MARK: - The Sheet's Stages

    /// Where the sheet is: the model's phase, without what it holds.
    enum Stage: Equatable, Sendable {
        /// Finding what the books hold.
        case listing
        /// Showing the kinds, ready to export.
        case ready
        /// An export is under way.
        case exporting
        /// An export has ended; the sheet stays open to say what it did.
        case finished

        /// The stage `phase` of the model is.
        init(_ phase: BookExportModel.Phase) {
            switch phase {
            case .listing: self = .listing
            case .ready: self = .ready
            case .exporting: self = .exporting
            case .finished: self = .finished
            }
        }
    }

    /// What fills the sheet's list under its bar.
    enum Content: Equatable, Sendable {
        /// "Finding what can be exported…", while the books are listed.
        case listing
        /// "There is nothing to export.", when the books hold nothing the
        /// iPhone offers.
        case nothingToExport
        /// A switch for each kind, the folder row, and what follows.
        case kinds
    }

    /// What fills the list at `stage`, when the books hold `kindCount` kinds
    /// the iPhone offers.
    static func content(stage: Stage, kindCount: Int) -> Content {
        if stage == .listing { return .listing }
        return kindCount == 0 ? .nothingToExport : .kinds
    }

    // MARK: - The Bar

    /// One button of the sheet's bar.
    struct BarButton: Equatable, Sendable {
        /// What the button does.
        enum Role: Hashable, Sendable {
            /// Closes the sheet without exporting.
            case cancel
            /// Stops the export under way.
            case stop
            /// Closes the sheet once an export has ended.
            case close
            /// Exports the kinds that are on.
            case export
        }

        /// What the button does.
        let role: Role
        /// The button's title, which is also its label.
        let title: String
        /// What VoiceOver says of what it does; empty for none.
        let hint: String
        /// Whether it can be pressed; a button that can't is dimmed.
        let isEnabled: Bool
    }

    /// The sheet's bar: its two buttons.
    struct Bar: Equatable, Sendable {
        /// Cancel, or Stop while an export runs, or Close once one has ended.
        let leading: BarButton
        /// Export.
        let export: BarButton

        /// Both, in VoiceOver's order: the leading button first.
        var buttons: [BarButton] { [leading, export] }
    }

    /// The bar at `stage`, in VoiceOver's order, which is the order the spec
    /// gives after the title: Cancel, or Stop while an export runs, or Close
    /// once one has ended; then Export. Export is dimmed unless `canExport`: a
    /// folder is chosen and an available kind is on
    /// (`BookExportModel.canExport`).
    ///
    /// While spoken audio is exported, Stop's hint says its chapters are kept (`SpeechExportWording.stopHint`); while its
    /// file is made (`isMakingSpeech`), Close takes Stop's place, since the sheet may close and the export go on, and
    /// Stop moves to its own row (`stopRow`).
    ///
    /// While another export runs (`anotherExportIsRunning`), Export is dimmed, and its hint says so and where the other's
    /// card is: a second export would end the first's card and task (`PhoneExportSession`).
    static func bar(
        stage: Stage,
        canExport: Bool,
        isExportingSpeech: Bool = false,
        isMakingSpeech: Bool = false,
        anotherExportIsRunning: Bool = false
    ) -> Bar {
        let leading: BarButton
        switch stage {
        case .listing, .ready:
            leading = BarButton(role: .cancel, title: BookExportWording.cancelTitle, hint: "", isEnabled: true)
        case .exporting where isMakingSpeech:
            leading = BarButton(role: .close, title: BookExportWording.closeTitle, hint: PhoneExportWording.closeWhileExporting, isEnabled: true)
        case .exporting:
            leading = BarButton(
                role: .stop, title: BookExportWording.stopTitle,
                hint: isExportingSpeech ? SpeechExportWording.stopHint : BookExportWording.stopHint, isEnabled: true
            )
        case .finished:
            leading = BarButton(role: .close, title: BookExportWording.closeTitle, hint: "", isEnabled: true)
        }
        let export = BarButton(
            role: .export,
            title: BookExportWording.exportTitle,
            hint: anotherExportIsRunning ? PhoneExportWording.anotherExportRuns : BookExportWording.exportHint,
            isEnabled: canExport && !anotherExportIsRunning
        )
        return Bar(leading: leading, export: export)
    }

    // MARK: - The Stop Row

    /// The Stop row under the progress while the spoken audio file is made, where the bar's leading button is Close; nil
    /// otherwise, when Stop is in the bar. Its hint says the chapters spoken are kept.
    static func stopRow(stage: Stage, isMakingSpeech: Bool) -> BarButton? {
        guard stage == .exporting, isMakingSpeech else { return nil }
        return BarButton(role: .stop, title: BookExportWording.stopTitle, hint: SpeechExportWording.stopHint, isEnabled: true)
    }

    // MARK: - Focus as the Export Moves

    /// A row of the sheet's progress that VoiceOver's focus can be on, and be sent to, as an export moves.
    enum ProgressFocus: Equatable, Sendable {
        /// The progress row, while an export runs.
        case progress
        /// The Stop row, while the spoken audio file is made (`stopRow`).
        case stopRow
        /// What the export did, once it has ended.
        case finished
    }

    /// Where VoiceOver's focus goes as the export moves to `stage`, making the spoken audio file or not
    /// (`isMakingSpeech`): nowhere, unless it is on a row of the progress (`focused`) that has just gone, as the Stop row
    /// goes once the spoken audio file is made, where the sheet itself sends focus as that file begins, and the progress
    /// row once the export has ended. Then it goes to what takes that row's place: the progress row while the export
    /// goes on (a file of the same book can follow the spoken audio), and what the export did once it has ended. Focus
    /// left on a row that has gone rests on nothing, and VoiceOver may then read anything, cutting off the end's sentence,
    /// which is announced as it comes; focus anywhere else stays where the person put it.
    static func focusAfterProgressMoves(from focused: ProgressFocus?, stage: Stage, isMakingSpeech: Bool) -> ProgressFocus? {
        let hasGone: Bool
        switch focused {
        case .stopRow?:
            hasGone = stopRow(stage: stage, isMakingSpeech: isMakingSpeech) == nil
        case .progress?:
            hasGone = stage != .exporting
        case .finished?, nil:
            hasGone = false
        }
        guard hasGone else { return nil }
        return progressRow(at: stage)
    }

    /// The row of the progress that takes the place of one that has gone, at `stage`: the progress row while the export
    /// goes on, what it did once it has ended, and none before an export. The sheet asks again as its focus moves, 0.35
    /// seconds on, since a short file after the spoken audio can end the export within that wait.
    static func progressRow(at stage: Stage) -> ProgressFocus? {
        switch stage {
        case .exporting: return .progress
        case .finished: return .finished
        case .listing, .ready: return nil
        }
    }

    // MARK: - The Share Button

    /// Share…, the button after an export that sends the files it wrote to another app or person: its title and its hint.
    struct ShareButton: Equatable, Sendable {
        /// What it is called, which VoiceOver reads.
        let title: String
        /// What VoiceOver says of what it does.
        let hint: String
    }

    /// The Share… button at `stage`, shown once an export has ended with at least one file written (`exportedCount`):
    /// there is nothing to send otherwise, and nothing while an export runs.
    static func shareButton(stage: Stage, exportedCount: Int) -> ShareButton? {
        guard stage == .finished, exportedCount > 0 else { return nil }
        return ShareButton(title: PhoneExportWording.share, hint: PhoneExportWording.shareHint)
    }

    // MARK: - The Library's Card

    /// What the card at the top of the Library says of an export that goes on with its sheet closed: the sheet's title,
    /// the progress words with Stop while it runs, and the Mac's sentence with Close once it has ended.
    struct Card: Equatable, Sendable {
        /// The card's heading, the sheet's title ("Export Moby-Dick").
        let title: String
        /// The progress while it runs; what it did once it has ended.
        let status: String
        /// How far the export has come, from 0 to 1; nil once it has ended or while it is not known.
        let fraction: Double?
        /// Stop, while the export runs.
        let stop: BarButton?
        /// Close, once it has ended.
        let close: BarButton?
    }

    /// The card for an export at `stage`, nil while no export is under way or ended. `progressText` and `fraction` are the
    /// model's (`BookExportModel.progressText`, `progressFraction`), `finishedWords` its end's sentence.
    static func card(stage: Stage, title: String, progressText: String?, fraction: Double?, finishedWords: String?) -> Card? {
        switch stage {
        case .listing, .ready:
            return nil
        case .exporting:
            let stop = BarButton(role: .stop, title: BookExportWording.stopTitle, hint: SpeechExportWording.stopHint, isEnabled: true)
            return Card(title: title, status: progressText ?? "", fraction: fraction, stop: stop, close: nil)
        case .finished:
            let close = BarButton(role: .close, title: BookExportWording.closeTitle, hint: "", isEnabled: true)
            return Card(title: title, status: finishedWords ?? "", fraction: nil, stop: nil, close: close)
        }
    }

    // MARK: - The Spoken Audio Rows

    /// The choice sheets the spoken audio rows open: the format, and where the audio begins and ends.
    enum SpeechChoice: String, Identifiable, Sendable {
        case format
        case from
        case through

        var id: String { rawValue }
    }

    /// One spoken audio row of the sheet: what it is, and the words VoiceOver reads from it.
    struct SpeechRow: Equatable, Sendable {
        /// What the row is, which says how the sheet draws it.
        enum Control: Equatable, Sendable {
            /// A button that opens a choice sheet.
            case choice(SpeechChoice)
            /// The speed, a slider.
            case speed
            /// The pitch, a slider.
            case pitch
            /// A line of words: the MP3 note, the missing headings, the voice, the licence. Its label is the words.
            case note
        }

        /// What the row is.
        let control: Control
        /// The row's label, or, for a note, its words.
        let label: String
        /// The row's value, with its unit; nil for a note.
        let value: String?
        /// What VoiceOver says of what the row does; empty for a note.
        let hint: String
    }

    /// How far the Pitch slider moves in one step, as the reader's and Settings' pitch sliders move.
    static let pitchStep = 0.1

    /// The spoken audio rows for `state`, in the Mac's order (`SpeechExportOptionsView`): the format, the MP3 note while a
    /// range of more than 255 headings is MP3, From and To (or the line saying the whole book is exported), the speed and
    /// the pitch, the voice, and the licence line, each in the iPhone's words where they differ.
    @MainActor
    static func speechRows(_ state: SpeechExportOptionsState) -> [SpeechRow] {
        func title(of items: [SpeechExportOptionsState.Item], tag: String) -> String {
            items.first { $0.tag == tag }?.title ?? ""
        }
        func note(_ words: String) -> SpeechRow {
            SpeechRow(control: .note, label: words, value: nil, hint: "")
        }
        var rows = [
            SpeechRow(control: .choice(.format), label: SpeechExportWording.formatLabel, value: state.format.title, hint: SpeechExportWording.formatHint)
        ]
        if let mp3Note = state.mp3ChapterNote { rows.append(note(mp3Note)) }
        if state.hasHeadings {
            rows.append(SpeechRow(
                control: .choice(.from), label: SpeechExportWording.fromLabel,
                value: title(of: state.fromItems, tag: state.fromTag), hint: SpeechExportWording.fromHint
            ))
            rows.append(SpeechRow(
                control: .choice(.through), label: SpeechExportWording.throughLabel,
                value: title(of: state.throughItems, tag: state.throughTag), hint: SpeechExportWording.throughHint
            ))
        } else {
            rows.append(note(SpeechExportWording.noHeadings))
        }
        rows.append(SpeechRow(
            control: .speed, label: SpeechExportWording.speedLabel,
            value: SpeechExportWording.speedValue(state.wordsPerMinute), hint: SpeechExportWording.speedHint
        ))
        rows.append(SpeechRow(
            control: .pitch, label: SpeechExportWording.pitchLabel,
            value: SpeechExportWording.pitchValue(state.pitch), hint: SpeechExportWording.pitchHint
        ))
        rows.append(note(SpeechExportWording.voiceLine(state.voice)))
        rows.append(note(SpeechExportWording.licence))
        return rows
    }

    // MARK: - The Folder Row

    /// The folder row's words, a button that opens the system's folder
    /// picker.
    struct FolderRow: Equatable, Sendable {
        /// What the row shows and VoiceOver reads: "Choose Folder…" until a
        /// folder is chosen, then "Export to: Downloads".
        let label: String
        /// What VoiceOver says of what it does.
        let hint: String
    }

    /// The folder row for the folder named `folderName`, nil while none is
    /// chosen.
    static func folderRow(folderName: String?) -> FolderRow {
        FolderRow(
            label: folderName.map { BookExportWording.destination(folderName: $0) } ?? BookExportWording.chooseFolderTitle,
            hint: BookExportWording.chooseFolderHint
        )
    }

    // MARK: - The Braille Rows

    /// The choice sheets the braille rows open: the braille code, and a BRF's line ends and file characters.
    enum BrailleChoice: String, Identifiable, Sendable {
        case code
        case lineEnds
        case fileCode

        var id: String { rawValue }
    }

    /// One braille row of the sheet: what it is, and the words VoiceOver reads from it.
    struct BrailleRow: Equatable, Sendable {
        /// What the row is, which says how the sheet draws it.
        enum Control: Equatable, Sendable {
            /// A button that opens a choice sheet.
            case choice(BrailleChoice)
            /// The cells in a line, a stepper.
            case cellsPerLine
            /// The lines on a page, a stepper.
            case linesPerPage
            /// Whether pages are numbered, a switch.
            case pageNumbers
        }

        /// What the row is.
        let control: Control
        /// The row's label.
        let label: String
        /// The row's value, with its unit; nil for a switch, which says its own.
        let value: String?
        /// What VoiceOver says of what the row does.
        let hint: String
    }

    /// The braille rows for `options`, in the Mac's order: the braille code, the cells in a line, the lines on a page,
    /// whether pages are numbered, and, for a BRF (`choosesLineEnds`), the line ends and the braille file characters.
    static func brailleRows(_ options: BrailleExportOptions, choosesLineEnds: Bool) -> [BrailleRow] {
        var rows = [
            BrailleRow(
                control: .choice(.code), label: BrailleSettingsWording.codeLabel,
                value: PhoneSettingsModel.brailleTableValue(options.table), hint: BrailleExportWording.codeHint
            ),
            BrailleRow(
                control: .cellsPerLine, label: BrailleExportWording.cellsLabel,
                value: BrailleExportWording.cellsValue(options.page.cellsPerLine), hint: BrailleExportWording.cellsHint
            ),
            BrailleRow(
                control: .linesPerPage, label: BrailleExportWording.linesLabel,
                value: BrailleExportWording.linesValue(options.page.linesPerPage), hint: BrailleExportWording.linesHint
            ),
            BrailleRow(
                control: .pageNumbers, label: BrailleExportWording.numbersLabel,
                value: nil, hint: BrailleExportWording.numbersHint
            )
        ]
        if choosesLineEnds {
            rows.append(BrailleRow(
                control: .choice(.lineEnds), label: BrailleExportWording.lineEndsLabel,
                value: BrailleExportWording.name(of: options.lineEnd), hint: BrailleExportWording.lineEndsHint
            ))
            rows.append(BrailleRow(
                control: .choice(.fileCode), label: BrailleSettingsWording.fileCodeLabel,
                value: options.fileCode.name, hint: BrailleExportWording.fileCodeHint
            ))
        }
        return rows
    }
}
