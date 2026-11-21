import Foundation

/// What a move on the iPhone's reader says, and where (the spec, under "What a
/// move says"; the engineering review's F2).
///
/// Every move takes one path, whether it came from adjusting Play, a skip
/// button, Next Heading, a rotor, or the AirPods: the shared code moves, and
/// what it would have said is collected rather than posted. This type sorts
/// what was collected, and decides what Play's value holds and what is
/// announced, from the state after the move. It is pure, so every case is a
/// test on the Mac.
///
/// The rules, in short:
/// - **While the book plays,** a move by sentence, paragraph, or seconds, or a
///   text book's heading or subheading, says nothing: the book, starting at
///   the new place, is what's heard. A page, a bookmark, and an audiobook's
///   heading or subheading say the Mac's short word, which the book's own
///   words can't.
/// - **While paused,** the words go in Play's value, and after anything but
///   adjusting Play they're also announced, since no adjustment answers then.
///   A heading, page, or bookmark says the Mac's word; a text book's
///   sentence, paragraph, or seconds say the sentence at the new place; an
///   audiobook's seconds say the Mac's "Moved to" with the time.
/// - **Nothing that way** says so, playing or paused: the Mac's own word when
///   it had one ("This book has no pages."), else "No next heading." and its
///   kin.
/// - **Anything else the shared code said** during the move still passes, in
///   its order and at its priority: a sleep timer stopping, the book ending.
struct PhoneMoveFeedback: Equatable {
    /// Where a move came from, which decides whether its words are announced
    /// while paused.
    enum Source: Equatable, Sendable {
        /// Adjusting Play: VoiceOver reads Play's new value as the answer, so
        /// a paused move's words go there alone.
        case adjustingPlay
        /// A skip button, a heading button, a rotor, or the AirPods: nothing
        /// answers by itself, so a paused move's words are also announced.
        case command
    }

    /// One move, as it was made and as it left the book.
    struct Move: Equatable {
        /// The unit moved by.
        let unit: SkipUnit
        /// Whether it moved forward.
        let forward: Bool
        /// Where it came from.
        let source: Source
        /// Whether the place changed: the cursor before and after.
        let moved: Bool
        /// Whether the book plays after the move, waiting counted as playing:
        /// a backward skip from a finished book starts it, so the state
        /// before the move can't decide.
        let isPlayingAfter: Bool
        /// Whether the book is an audiobook.
        let isAudioBook: Bool
        /// What the shared code said during the move, oldest first.
        let collected: [VoiceOverAnnouncement]
        /// A text book's words at the new place, from the place to the end
        /// of its sentence (`PhoneReaderWording.sentence(in:from:)`); nil for
        /// an audiobook, or where only whitespace follows.
        let sentenceAtPlace: String?
        /// An audiobook's time in its recording at the new place; nil for a
        /// text book.
        let timeAtPlace: TimeInterval?
    }

    /// What Play's value holds after the move, until Play or the next move;
    /// nil while the book plays, when the value is empty.
    let playValue: String?
    /// What's announced, in order, each at its priority.
    let announcements: [VoiceOverAnnouncement]

    /// A move's own words as an announcement, at high priority, which the
    /// phone's announcer maps to one a flick can interrupt (the spec, under
    /// "Announcements"): what a move's words should be. The priority's type
    /// is AppKit's on the Mac, so this file never names it.
    static func ownWords(_ message: String) -> VoiceOverAnnouncement {
        VoiceOverAnnouncement(message: message, priority: .high)
    }

    /// Decides what `move` says.
    static func deciding(_ move: Move) -> PhoneMoveFeedback {
        // The move's own word is the last one a structural move said, after
        // anything its jump said first (a timer ended at a heading's end);
        // a move by seconds has no words of its own, so everything passes.
        // A move that went nowhere has none either: what it said, such as
        // "This book has no pages.", is its answer.
        let ownsLastWord = move.moved && !move.unit.isTimeBased
        let passing = ownsLastWord ? Array(move.collected.dropLast()) : (move.moved ? move.collected : [])
        let macWord = ownsLastWord ? move.collected.last?.message : nil

        guard move.moved else {
            // Nothing that way: the Mac's word, when it said one, else the
            // spec's. Said whether paused or playing.
            let words = move.collected.last?.message ?? PhoneReaderWording.nothingThatWay(
                unit: move.unit,
                forward: move.forward
            )
            let earlier = Array(move.collected.dropLast())
            return answer(words, passing: earlier, move: move)
        }

        if move.isPlayingAfter {
            // The book is the feedback, unless its own words can't say where
            // the move landed.
            guard sayWhilePlaying(move.unit, isAudioBook: move.isAudioBook), let macWord else {
                return PhoneMoveFeedback(playValue: nil, announcements: passing)
            }
            return PhoneMoveFeedback(
                playValue: nil,
                announcements: passing + [ownWords(macWord)]
            )
        }

        guard let words = pausedWords(for: move, macWord: macWord) else {
            return PhoneMoveFeedback(playValue: nil, announcements: passing)
        }
        return answer(words, passing: passing, move: move)
    }

    /// Whether a move by `unit` says its word while the book plays: a page,
    /// a bookmark, and an audiobook's heading or subheading, whose landing
    /// the book's own words can't name.
    static func sayWhilePlaying(_ unit: SkipUnit, isAudioBook: Bool) -> Bool {
        switch unit {
        case .page, .bookmark: return true
        case .heading, .subheading: return isAudioBook
        default: return false
        }
    }

    /// What a paused move that went somewhere says: the Mac's word for a
    /// heading, subheading, page, or bookmark; the sentence at the new place
    /// for a text book's sentence, paragraph, or seconds, the Mac's word
    /// standing in where no sentence follows; the Mac's "Moved to" and the
    /// time for an audiobook's seconds.
    private static func pausedWords(for move: Move, macWord: String?) -> String? {
        switch move.unit {
        case .heading, .subheading, .page, .bookmark:
            return macWord
        case .sentence, .paragraph:
            return move.sentenceAtPlace ?? macWord
        default:
            if move.isAudioBook {
                return move.timeAtPlace.map { BookSearchWording.movedTo(time: $0, location: nil) }
            }
            return move.sentenceAtPlace
        }
    }

    /// The feedback for `words`, the move's answer: in Play's value while
    /// paused, and announced as well whenever no adjustment answers, which is
    /// after a command, or while the book plays.
    private static func answer(_ words: String, passing: [VoiceOverAnnouncement], move: Move) -> PhoneMoveFeedback {
        let own = ownWords(words)
        if move.isPlayingAfter {
            return PhoneMoveFeedback(playValue: nil, announcements: passing + [own])
        }
        let announced = move.source == .command ? passing + [own] : passing
        return PhoneMoveFeedback(playValue: words, announcements: announced)
    }
}
