import SwiftUI
import UIKit

/// Book content: the book's text, as the Mac's reader has it above the
/// playback controls, and how a braille reader reads the book (the spec,
/// under "Book content"; the engineering review's F16).
///
/// A read-only text view, so VoiceOver gives it Lines, Words, and Characters
/// on the rotor, a cursor on a braille display, and panning, without further
/// code. Its passage starts at the sentence at the reading position; what
/// changes it, and when, is `PhonePassagePolicy`'s.
///
/// Nothing here has run on iOS. Unverified, and on the hand-check list:
/// whether a selectable text view's selection follows VoiceOver's cursor or a
/// router key; how the Sentences rotor behaves; paging by three-finger swipe.
struct PhoneBookContent: UIViewRepresentable {
    /// The reader's model, whose reader the text is read from.
    let model: PhoneReaderModel
    /// What the screen shows of the book now, from the session's snapshot:
    /// a change of book, of loading, or of playing reaches the text here.
    let snapshot: PhoneReaderSnapshot?
    /// Whether Settings' Follow in Braille is on, asked at each tick.
    let followsInBraille: @MainActor () -> Bool

    func makeUIView(context: Context) -> PhoneBookTextView {
        let view = PhoneBookTextView()
        view.attach(model: model, followsInBraille: followsInBraille)
        view.snapshotChanged(to: snapshot)
        return view
    }

    func updateUIView(_ view: PhoneBookTextView, context: Context) {
        view.attach(model: model, followsInBraille: followsInBraille)
        view.snapshotChanged(to: snapshot)
    }

    /// Stops the tick and the observers as the view goes.
    static func dismantleUIView(_ view: PhoneBookTextView, coordinator: ()) {
        view.detach()
    }
}

/// The text view under Book content.
final class PhoneBookTextView: UITextView {
    /// The reader's model.
    private weak var model: PhoneReaderModel?
    /// Whether Follow in Braille is on.
    private var followsInBraille: @MainActor () -> Bool = { false }

    /// What the text shows: the passage of a chapter, or a stand-in such as
    /// "Loading Moby-Dick".
    private struct Shown: Equatable {
        /// The book shown.
        let bookID: UUID
        /// The chapter the passage is from, or nil for a stand-in.
        let chapter: Int?
        /// The passage's place in the chapter, as UTF-16 offsets.
        let range: Range<Int>
        /// The words shown.
        let text: String
    }

    /// What the text shows now.
    private var shown: Shown?
    /// Whether VoiceOver's focus is on the text.
    private(set) var hasFocus = false
    /// The snapshot last seen, to tell a load's end and a pause.
    private var lastSnapshot: PhoneReaderSnapshot?
    /// The passage offset the Sentences rotor last reached, for Listen from
    /// Here; forgotten when the passage changes.
    private var rotorSentence: Int?
    /// Whether this view turned off the screen's sleep, which it puts back.
    private var endScreenHold: (@MainActor () -> Void)?
    /// The 10-second tick while the app is active and the view on screen.
    private var tick: Timer?
    /// The app's activity observers.
    private var observers: [NSObjectProtocol] = []
    /// Whether the app went to the background since it was last active, so
    /// that a return from Control Center isn't taken for one.
    private var wasInBackground = false

    /// A read-only, selectable text view that scrolls inside a fixed height
    /// and follows the text size.
    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        font = UIFont.preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        accessibilityTextualContext = .narrative
    }

    /// Not made from a storyboard.
    required init?(coder: NSCoder) {
        return nil
    }

    /// Takes the model and the switch, and starts following the app's
    /// activity once.
    func attach(model: PhoneReaderModel, followsInBraille: @escaping @MainActor () -> Bool) {
        self.model = model
        self.followsInBraille = followsInBraille
        // Known by its kind, so a landing here ends the arrival's pull to Play.
        PhoneFocusRegistry.shared.register(self, as: .bookContent)
        model.placeDidMove = { [weak self] in
            self?.passageEvent(.movedWhilePaused)
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Each observer is told on the main queue, then claims the main actor.
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wasInBackground = true
                self?.stopTick()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startTick()
                if self.wasInBackground {
                    self.wasInBackground = false
                    self.passageEvent(.cameBack)
                }
            }
        })
        startTick()
    }

    /// Stops the tick and the observers, and gives back the screen's sleep.
    func detach() {
        stopTick()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        allowScreenSleep()
    }

    // MARK: - What Changes the Text

    /// A new snapshot: the book loaded, paused, or changed to the next one.
    func snapshotChanged(to snapshot: PhoneReaderSnapshot?) {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        guard let snapshot else { return }
        if previous?.bookID != snapshot.bookID || previous?.isLoading != snapshot.isLoading || shown == nil {
            passageEvent(.loaded)
        } else if previous?.isPlaying == true, !snapshot.isPlaying {
            passageEvent(.paused)
        }
    }

    /// Asks the policy whether `event` changes the text, and shows the
    /// passage at the reading position if it does.
    func passageEvent(_ event: PhonePassagePolicy.Event) {
        guard let model, let reader = model.reader else { return }
        let isPlaying = reader.isPlaybackUnderWay
        guard PhonePassagePolicy.changesPassage(
            on: event,
            hasFocus: hasFocus,
            isPlaying: isPlaying,
            followsInBraille: followsInBraille()
        ) else { return }
        show(passageOf: reader, chapter: reader.currentChapterIndex, at: reader.currentCharacterOffset)
    }

    /// Shows the passage of `reader`'s chapter `chapter` at `offset`, or the
    /// stand-in while there's no text to show. Compared first, so the same
    /// passage is never assigned again.
    private func show(passageOf reader: ReaderViewModel, chapter: Int, at offset: Int) {
        let next: Shown
        if let state = model?.state, let standIn = PhoneReaderControls.bookContentStandIn(in: state) {
            next = Shown(bookID: reader.book.id, chapter: nil, range: 0..<0, text: standIn)
        } else if let chapters = reader.content?.chapters, chapters.indices.contains(chapter) {
            let text = chapters[chapter].text
            let range = PhonePassagePolicy.passage(in: text, at: offset, maximumLength: ReaderViewModel.maxDisplayChars)
            next = Shown(bookID: reader.book.id, chapter: chapter, range: range, text: Self.substring(of: text, range))
        } else {
            return
        }
        guard next != shown else { return }
        shown = next
        rotorSentence = nil
        text = next.text
        selectedRange = NSRange(location: 0, length: 0)
        setContentOffset(.zero, animated: false)
    }

    /// The UTF-16 range `range` of `text`.
    private static func substring(of text: String, _ range: Range<Int>) -> String {
        let start = text.index(atUTF16Offset: range.lowerBound)
        let end = text.index(atUTF16Offset: range.upperBound)
        return String(text[start..<end])
    }

    // MARK: - The Tick

    /// Starts the 10-second tick, which follows the book while it plays and
    /// the text doesn't have focus. It runs on the main run loop, and only
    /// while the app is active and the view is on screen.
    private func startTick() {
        guard tick == nil, window != nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: PhonePassagePolicy.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.passageEvent(.playingTick)
            }
        }
    }

    /// Stops the tick.
    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    /// Starts or stops the tick as the view comes on or leaves the screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTick()
            allowScreenSleep()
        } else if UIApplication.shared.applicationState == .active {
            startTick()
        }
    }

    // MARK: - What VoiceOver Reads

    override var accessibilityLabel: String? {
        get { ReaderTextArea.accessibilityLabel }
        set {}
    }

    /// While paused, "Plays from here."; while playing, "Brings the text to
    /// the sentence being spoken.", computed when asked.
    override var accessibilityHint: String? {
        get { model?.description(of: .bookContent)?.hint }
        set {}
    }

    /// Focus arrived: the text stays as it is, the screen stays awake, since
    /// a person reading by braille may not touch the phone for minutes, and
    /// the book counts as opened, as reading it has.
    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        hasFocus = true
        keepScreenAwake()
        model?.noteReading()
    }

    /// Focus left: the screen may sleep again, and the text catches up.
    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        hasFocus = false
        allowScreenSleep()
        passageEvent(.focusLeft)
    }

    /// Activating: while paused, Listen from Here; while playing, the text
    /// comes to the sentence being spoken, and the book plays on. Apple's
    /// documentation: return true when the element handled the activation.
    override func accessibilityActivate() -> Bool {
        guard let model, let reader = model.reader else { return false }
        if reader.isPlaybackUnderWay {
            show(passageOf: reader, chapter: reader.currentChapterIndex, at: reader.currentCharacterOffset)
            return true
        }
        guard let shown, let chapter = shown.chapter else { return true }
        let moved = selectedRange.location > 0 ? selectedRange.location : nil
        let place = PhonePassagePolicy.listeningPlace(
            passageStart: shown.range.lowerBound,
            movedSelection: moved,
            rotorSentence: rotorSentence,
            passageLength: shown.range.count
        )
        model.listen(fromChapter: chapter, offset: place)
        return true
    }

    // MARK: - Paging

    /// Apple's "Scroll down one page" and "up" (a three-finger swipe, or
    /// Dots 1-4-5-6 and 3-4-5-6 with Space): the next or previous passage,
    /// across chapters. While paused, a page moves the place; while playing,
    /// only the text. Each says the new place by the page-scrolled status,
    /// the Mac's page or percent words. Returns false at either end, which
    /// is VoiceOver's boundary sound.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forward: Bool
        switch direction {
        case .down, .next: forward = true
        case .up, .previous: forward = false
        default: return false
        }
        guard let model, let reader = model.reader, let chapters = reader.content?.chapters,
              let shown, let chapter = shown.chapter,
              let target = PhonePassagePolicy.pageTarget(
                  chapters: chapters.map(\.text),
                  chapter: chapter,
                  shown: shown.range,
                  forward: forward,
                  maximumLength: ReaderViewModel.maxDisplayChars
              ) else { return false }
        if reader.isPlaybackUnderWay {
            show(passageOf: reader, chapter: target.chapter, at: target.offset)
        } else {
            model.turnPage(toChapter: target.chapter, offset: target.offset)
            show(passageOf: reader, chapter: target.chapter, at: target.offset)
        }
        UIAccessibility.post(notification: .pageScrolled, argument: pageStatus(of: reader, chapter: target.chapter, offset: target.offset))
        return true
    }

    /// The page-scrolled status for a passage at `offset` in `chapter`: the
    /// Mac's "Page 12 of 300" in a book of pages, else its percent words.
    private func pageStatus(of reader: ReaderViewModel, chapter: Int, offset: Int) -> String {
        if reader.hasSeveralPages {
            let position = reader.bookPages.position(atChapter: chapter, offset: offset)
            if !position.label.isEmpty { return position.label }
        }
        let global = reader.content?.globalOffset(chapterIndex: chapter, localOffset: offset) ?? 0
        let percent = reader.content?.percentComplete(globalOffset: global) ?? 0
        return PhoneReaderVocabulary.percent(percent)
    }

    // MARK: - The Sentences Rotor

    /// The Sentences rotor, on this element alone: it moves by sentence within
    /// the passage, returning a range in the text, as Apple's WWDC20 session
    /// on custom rotors shows. Each result is remembered for Listen from Here.
    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            [UIAccessibilityCustomRotor(name: PhoneReaderWording.sentencesRotor) { [weak self] predicate in
                self?.sentence(for: predicate)
            }]
        }
        set {}
    }

    /// The sentence the rotor reaches from where it stands, or nil at either
    /// end of the passage.
    private func sentence(for predicate: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? {
        let forward = predicate.searchDirection == .next
        let from: Int
        if let current = predicate.currentItem.targetRange, predicate.currentItem.targetElement === self {
            from = offset(from: beginningOfDocument, to: current.start)
        } else {
            from = rotorSentence ?? selectedRange.location
        }
        guard let found = PhonePassagePolicy.sentence(in: text ?? "", from: from, forward: forward),
              let start = position(from: beginningOfDocument, offset: found.lowerBound),
              let end = position(from: beginningOfDocument, offset: found.upperBound),
              let range = textRange(from: start, to: end) else { return nil }
        rotorSentence = found.lowerBound
        return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: range)
    }

    // MARK: - The Screen's Sleep

    /// Keeps the screen awake while the text has focus, by a hold on the
    /// app's one keeper of the screen's sleep (`PhoneScreenSleep`).
    private func keepScreenAwake() {
        guard endScreenHold == nil else { return }
        endScreenHold = PhoneScreenSleep.hold()
    }

    /// Lets the screen sleep again, if this view kept it awake. Only this
    /// view's hold is let go: another owner's (the import's) stays.
    private func allowScreenSleep() {
        endScreenHold?()
        endScreenHold = nil
    }
}
