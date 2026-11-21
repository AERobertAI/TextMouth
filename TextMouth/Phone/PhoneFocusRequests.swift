import Foundation

/// The reader's requests for VoiceOver focus that wait a moment before they
/// are made, and the rule that a listener's own move cancels them (the iPhone
/// interface spec, "Any focus event cancels a request still waiting").
///
/// A sheet or an alert that closes asks for focus to return to the control
/// that opened it, but only after 0.35 seconds (`PhoneFocusPolicy
/// .screenChangedDelay`), since a request made at once is lost to the
/// system's own work. In those 0.35 seconds the listener may already have
/// flicked on to another control, and a request that then fired would pull
/// focus from under their finger. So each request takes a ticket, VoiceOver's
/// landing on one of the reader's controls spends every ticket still waiting,
/// and a request asks for its ticket back when its time comes: it posts only
/// if the ticket is still good.
///
/// As in `PhoneFocusPolicy`, a landing on something that is not one of the
/// reader's controls, the system's Back button or the title where VoiceOver
/// wanders by itself, is not the listener's and cancels nothing: it is what
/// the returning request exists to correct.
///
/// **Unverified, and on the hand-check list:** whether VoiceOver lands on a
/// different reader control by itself as a sheet finishes closing, after the
/// request was made. If it does, the return of focus is cancelled by VoiceOver
/// rather than the listener, and focus stays where VoiceOver put it.
///
/// A plain value with no clock, so a test drives it by calls alone.
struct PhoneFocusRequests: Equatable, Sendable {
    /// One request's claim on the right to post: handed out by `request()`,
    /// good until a landing spends it or `claim(_:)` uses it.
    struct Ticket: Hashable, Sendable {
        /// The request's number, counted from 1 in the order made.
        fileprivate let number: Int
    }

    /// The number the next ticket takes.
    private var nextNumber = 1
    /// The tickets of the requests still waiting.
    private var waiting: Set<Ticket> = []

    /// How many requests are waiting.
    var waitingCount: Int { waiting.count }

    /// Notes a request that is about to wait, and returns its ticket.
    mutating func request() -> Ticket {
        let ticket = Ticket(number: nextNumber)
        nextNumber += 1
        waiting.insert(ticket)
        return ticket
    }

    /// VoiceOver's focus landed on `control`, or, given nil, somewhere that is
    /// not one of the reader's controls. A landing on a control is the
    /// listener's: every request still waiting is cancelled.
    mutating func focusLanded(on control: PhoneControlKind?) {
        guard control != nil else { return }
        waiting.removeAll()
    }

    /// The time of the request with `ticket` has come: true, once, if no
    /// landing has cancelled it, and the request may post. False for a
    /// cancelled or an already used ticket, and the request must do nothing.
    mutating func claim(_ ticket: Ticket) -> Bool {
        waiting.remove(ticket) != nil
    }
}
