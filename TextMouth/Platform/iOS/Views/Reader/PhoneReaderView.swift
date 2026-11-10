import SwiftUI
import UIKit

/// The reader's screen: Book content, Play, and a grid of three columns and
/// five rows, in the spec's order and layout (the spec, under "The reader").
///
/// The view is thin. It reads the session's snapshot, which changes only
/// when the book's title, playing, or loading does, never as the place moves;
/// every word comes from `PhoneReaderModel` when VoiceOver asks; and every
/// control is a UIKit view (`PhoneControl`, `PhoneBookContent`). The screen
/// is never keyed by book, so focus survives the next book.
///
/// Nothing here has run on iOS. Unverified, and on the hand-check list: the
/// flick order down the column, focus landing on Play at every open, and
/// that a person can find Play by touch.
struct PhoneReaderView: View {
    /// The owner of the reader.
    @ObservedObject var session: PhoneSession

    /// The sheet open over the reader, if any.
    @State private var sheet: PhoneReaderSheet?
    /// The control that opened it, which focus returns to when it closes.
    @State private var sheetOpener: PhoneReaderControl?
    /// The bookmark with a note that Add bookmark asks about removing.
    @State private var bookmarkToRemove: Bookmark?
    /// Whether the load failure has VoiceOver's focus.
    @AccessibilityFocusState private var failureFocused: Bool

    /// At accessibility text sizes the grid becomes one column.
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Book content's height: about six lines of body text at any size.
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 150
    /// Play's height, the same in every book.
    @ScaledMetric(relativeTo: .title2) private var playHeight: CGFloat = 88

    /// The one model for the session's readers.
    private var model: PhoneReaderModel {
        PhoneReaderModel.attached(to: session)
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet, onDismiss: sheetClosed) { shown in
                sheetView(shown)
            }
            .alert(
                bookmarkToRemove.map(PhoneReaderWording.removeBookmarkTitle) ?? "",
                isPresented: Binding(
                    get: { bookmarkToRemove != nil },
                    set: { if !$0 { bookmarkToRemove = nil } }
                ),
                presenting: bookmarkToRemove
            ) { _ in
                Button(PhoneReaderWording.remove, role: .destructive) {
                    model.toggleBookmark()
                }
                Button(PhoneAppWording.cancel, role: .cancel) {}
            } message: { bookmark in
                Text(bookmark.label)
            }
            // The Mac's error alert, and the Speech Stopped sheet, which waits
            // while a panel, an alert, or the error alert is over the reader.
            .modifier(PhoneReaderErrorAlert(
                alert: session.snapshot?.errorAlert,
                reader: session.reader,
                closed: errorAlertClosed
            ))
            .sheet(isPresented: speechRefusalShows, onDismiss: speechRefusalDismissed) {
                if let reader = session.reader {
                    PhoneSpeechRefusalSheet(reader: reader)
                }
            }
            // Once per arrival, never per book: the next book keeps the
            // screen, and focus stays where the listener put it.
            .task {
                await arrive()
            }
    }

    // MARK: - The Screen

    /// The column, or the Mac's load failure in place of the moving
    /// controls, with Back still working.
    @ViewBuilder
    private var content: some View {
        if let failure = loadFailure {
            ReaderLoadFailureView(message: failure)
                .accessibilityFocused($failureFocused)
                .task {
                    try? await Task.sleep(for: .milliseconds(350))
                    failureFocused = true
                }
        } else {
            ScrollView {
                column
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Book content, Play, and the grid. No `accessibilityElement(children:)`
    /// wraps it, or the UIKit views would vanish from VoiceOver.
    private var column: some View {
        VStack(spacing: 12) {
            PhoneBookContent(
                model: model,
                snapshot: session.snapshot,
                followsInBraille: { PhoneReaderView.followsInBraille }
            )
            .frame(height: textHeight)

            control(.play)
                .frame(height: playHeight)

            if typeSize.isAccessibilitySize {
                ForEach(PhoneReaderControl.grid, id: \.self) { item in
                    control(item)
                }
            } else {
                ForEach(gridRows, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { item in
                            control(item)
                        }
                    }
                }
            }
        }
    }

    /// The grid's rows, three controls to a row, in the spec's order.
    private var gridRows: [[PhoneReaderControl]] {
        stride(from: 0, to: PhoneReaderControl.grid.count, by: 3).map {
            Array(PhoneReaderControl.grid[$0..<min($0 + 3, PhoneReaderControl.grid.count)])
        }
    }

    /// The book's title, with the Mac's prefix for a book read from the
    /// Reading List.
    private var title: String {
        guard let snapshot = session.snapshot else { return "" }
        guard session.reader?.readingListPlace != nil else { return snapshot.title }
        return "\(ReadingListReaderWording.windowTitlePrefix): \(snapshot.title)"
    }

    /// Why the book couldn't load, once loading has ended.
    private var loadFailure: String? {
        guard session.snapshot?.isLoading == false else { return nil }
        return session.reader?.loadErrorMessage
    }

    // MARK: - The Controls

    /// The UIKit control for `item`, with what it does.
    private func control(_ item: PhoneReaderControl) -> some View {
        let model = model
        return PhoneControl(
            describe: { model.description(of: item) },
            activate: action(for: item),
            increment: adjustment(for: item, up: true),
            decrement: adjustment(for: item, up: false),
            perform: customActions(for: item),
            focusKind: item.focusKind,
            showsValue: item == .navigationUnit || item == .speed,
            rotors: rotors(for: item)
        )
        .frame(maxWidth: .infinity)
    }

    /// What activating `item` does.
    private func action(for item: PhoneReaderControl) -> (@MainActor () -> Void)? {
        let model = model
        switch item {
        case .bookContent, .speed:
            return nil
        case .play:
            return { model.togglePlayPause() }
        case .whereAmI:
            return { model.whereAmI() }
        case .previousHeading:
            return { model.moveOnScreen(forward: false, unit: .heading, source: .command) }
        case .nextHeading:
            return { model.moveOnScreen(forward: true, unit: .heading, source: .command) }
        case .skipBackward:
            return { model.moveOnScreen(forward: false, source: .command) }
        case .skipForward:
            return { model.moveOnScreen(forward: true, source: .command) }
        case .addBookmark:
            return {
                // A bookmark with a note asks first; one without goes at once.
                if let bookmark = model.bookmarkToConfirmRemoving {
                    bookmarkToRemove = bookmark
                } else {
                    model.toggleBookmark()
                }
            }
        case .returnToPlace:
            return { model.returnToPreviousPlace() }
        case .navigationUnit, .bookmarks, .headings, .goTo, .sleepTimer, .voice, .bookInfo:
            return {
                sheetOpener = item
                sheet = item.sheet
            }
        }
    }

    /// What `item`'s custom actions do: Where Am I?'s two, the Mac's.
    private func customActions(for item: PhoneReaderControl) -> (@MainActor (PhoneControlAction) -> Void)? {
        guard item == .whereAmI else { return nil }
        let model = model
        return { action in
            switch action {
            case .whereAmIFullSummary: model.whereAmIFullSummary()
            case .copyReadingPosition: model.copyReadingPosition()
            }
        }
    }

    /// `item`'s own rotors: Play's, while their flag is on; none otherwise.
    private func rotors(for item: PhoneReaderControl) -> (@MainActor (UIView) -> [UIAccessibilityCustomRotor])? {
        guard item == .play, Self.playRotorsEnabled else { return nil }
        let model = model
        return { element in Self.playRotors(on: element, model: model) }
    }

    /// What adjusting `item` up or down does: Play moves by the unit,
    /// Navigation unit steps through the units, Speed steps the speed.
    private func adjustment(for item: PhoneReaderControl, up: Bool) -> (@MainActor () -> Void)? {
        let model = model
        switch item {
        case .play:
            // Up is forward, as Voice Dream's and Apple's "increase" have it.
            return { model.moveOnScreen(forward: up, source: .adjustingPlay) }
        case .navigationUnit:
            return { model.adjustUnit(up: up) }
        case .speed:
            return { model.adjustSpeed(up: up) }
        default:
            return nil
        }
    }

    // MARK: - Sheets

    /// The sheet's content: Navigation unit's choices here, the panels'
    /// sheets from `PhoneReaderSheetContent`.
    @ViewBuilder
    private func sheetView(_ shown: PhoneReaderSheet) -> some View {
        if shown == .navigationUnit, let reader = session.reader {
            PhoneChoiceSheet(
                title: PhoneReaderVocabulary.navigationUnit,
                choices: model.offeredUnits(of: reader).map { PhoneChoice(id: $0, label: $0.rawValue) },
                selected: model.unitInForce(of: reader),
                onChoose: { model.choose($0) }
            )
        } else if let reader = session.reader {
            PhoneReaderSheetContent(
                sheet: shown,
                reader: reader,
                noteJumped: { [model] in model.noteJumped() },
                library: session.library,
                pauseBookForPreview: { [session] in session.pauseBookForPreview() }
            )
        }
    }

    /// A sheet closed: the text follows a jump made in it, and focus returns
    /// to the control that opened it.
    private func sheetClosed() {
        model.invalidate()
        model.placeDidMove?()
        guard let kind = sheetOpener?.focusKind else { return }
        sheetOpener = nil
        returnFocus(to: kind)
    }

    /// Returns focus to the control of `kind` after 0.35 seconds, by a layout
    /// change with that control as its argument. Sheets and alerts don't
    /// return focus by themselves. `unless` is asked then, and a true answer
    /// leaves focus where it is, as does the listener's landing on any of the
    /// reader's controls meanwhile (`PhoneFocusRequests`).
    private func returnFocus(to kind: PhoneControlKind, unless skip: @escaping @MainActor () -> Bool = { false }) {
        PhoneFocusRegistry.shared.requestFocus(on: kind, after: PhoneFocusPolicy.screenChangedDelay, unless: skip)
    }

    /// The Speech Stopped sheet went away: focus returns to Play (the spec,
    /// "While the book is loading, or can't load"), unless the sheet was only
    /// put aside, for a panel or the report is still kept, since focus is
    /// then on what came over it.
    private func speechRefusalDismissed() {
        returnFocus(to: .play) { [session] in
            sheet != nil || session.snapshot?.hasSpeechRefusalReport == true
        }
    }

    /// The error alert closed: focus returns to Play unless a retry that
    /// failed again has presented a fresh alert, which VoiceOver is on
    /// (`PhoneErrorAlertPlan.returnsFocusToPlay`).
    private func errorAlertClosed() {
        returnFocus(to: .play) { [session] in
            !PhoneErrorAlertPlan.returnsFocusToPlay(errorAlertNow: session.snapshot?.errorAlert)
        }
    }

    /// Whether the Speech Stopped sheet shows: while the reader keeps a
    /// report and nothing else is over the reader. Closed by its own Close,
    /// or by the system putting it away, which closes the report too.
    private var speechRefusalShows: Binding<Bool> {
        Binding(
            get: {
                PhoneSpeechRefusalPresentation.shows(
                    hasReport: session.snapshot?.hasSpeechRefusalReport == true,
                    panelSheetShows: sheet != nil,
                    errorAlertShows: session.snapshot?.errorAlert != nil,
                    otherAlertShows: bookmarkToRemove != nil
                )
            },
            set: { shown in
                // Put aside for a panel or an alert, SwiftUI doesn't call
                // this; a swipe down does, and closes the report.
                if !shown { session.reader?.closeSpeechRefusalReport() }
            }
        )
    }

    // MARK: - Arrival

    /// A book opened: focus lands on Play by `PhoneFocusPolicy`, and the
    /// title is said after it with low priority. A load that takes more than
    /// 5 seconds says "Loading Moby-Dick" once, with low priority.
    private func arrive() async {
        guard let snapshot = session.snapshot else { return }
        await PhoneReaderArrival().run()
        PhoneAnnouncer.say(snapshot.title)
        guard session.snapshot?.isLoading == true else { return }
        try? await Task.sleep(for: .seconds(5))
        // Leaving the screen cancels this task, and `try?` swallows the
        // cancellation, so without this a book still loading and kept open
        // would be announced over the Library as the listener leaves.
        guard !Task.isCancelled else { return }
        if session.snapshot?.bookID == snapshot.bookID, session.snapshot?.isLoading == true {
            PhoneAnnouncer.say(PhoneReaderVocabulary.loading(snapshot.title))
        }
    }

    // MARK: - The Rotors on Play

    /// The one flag the rotors on Play sit behind: off, the safe choice, until
    /// a first run shows a move inside a rotor's search can be silent and
    /// happens only when the listener flicks. A search VoiceOver makes when
    /// nobody flicked would move the place unasked (the spec, under "The
    /// rotors"; the engineering review's F20). Adjusting Play and Next
    /// Heading are the design; this is a second way.
    static let playRotorsEnabled = false

    /// Play's rotors: Headings as the system's heading rotor, then Pages and
    /// Bookmarks, each where the book has them. A flick down moves forward,
    /// as on every rotor, and a flick up back; each returns Play itself, so
    /// focus stays there and nothing is read but what the move says, or nil
    /// with nothing that way, which is VoiceOver's boundary sound.
    private static func playRotors(on play: UIView, model: PhoneReaderModel) -> [UIAccessibilityCustomRotor] {
        model.playRotorUnits.map { unit in
            let search = { [weak play, weak model] (predicate: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? in
                guard let play, let model else { return nil }
                let moved = model.moveOnScreen(forward: predicate.searchDirection == .next, unit: unit, source: .command)
                return moved ? UIAccessibilityCustomRotorItemResult(targetElement: play, targetRange: nil) : nil
            }
            switch unit {
            case .heading:
                return UIAccessibilityCustomRotor(systemType: .heading, itemSearch: search)
            case .page:
                return UIAccessibilityCustomRotor(name: PhoneReaderWording.pagesRotor, itemSearch: search)
            default:
                return UIAccessibilityCustomRotor(name: PhoneReaderVocabulary.bookmarks, itemSearch: search)
            }
        }
    }

    /// Whether Settings' Follow in Braille is on, read from preferences.
    private static var followsInBraille: Bool {
        TextMouthRuntime.current.preferences.bool(forKey: PhoneDefaults.followInBrailleKey)
    }
}

/// Runs `PhoneFocusPolicy`'s arrival on the reader: `.screenChanged` with
/// Play at 0.35 seconds, `.layoutChanged` with Play once at 1.2 seconds if
/// focus has reached none of the reader's controls, and nothing after 3
/// seconds or after focus has landed on one of them, which is the listener's.
@MainActor
private final class PhoneReaderArrival {
    /// The rules, with the arrival's time.
    private var policy = PhoneFocusPolicy(arrivedAt: ProcessInfo.processInfo.systemUptime)
    /// The focus observer, while the arrival runs.
    private var observer: NSObjectProtocol?

    /// Runs the arrival to its end: at most 3 seconds.
    func run() async {
        // Told on the main queue, then claims the main actor. Only the
        // element's identity crosses, which is Sendable. The observer holds
        // the arrival until the defer below removes it, as the run ends.
        observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { notification in
            let landed = (notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject)
                .map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self.landed(onElementWithID: landed)
            }
        }
        defer {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        while let next = policy.nextCheck {
            let wait = max(0, next - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { return }
            switch policy.action(at: ProcessInfo.processInfo.systemUptime) {
            case .postScreenChanged?:
                UIAccessibility.post(notification: .screenChanged, argument: PhoneFocusRegistry.shared.view(for: .play))
            case .postLayoutChanged?:
                UIAccessibility.post(notification: .layoutChanged, argument: PhoneFocusRegistry.shared.view(for: .play))
            case nil:
                break
            }
        }
    }

    /// VoiceOver's focus landed on the element with identity `id`: once on
    /// any reader control, the arrival is over.
    private func landed(onElementWithID id: ObjectIdentifier?) {
        policy.focusLanded(on: PhoneFocusRegistry.shared.kind(ofElementWithID: id))
    }
}
