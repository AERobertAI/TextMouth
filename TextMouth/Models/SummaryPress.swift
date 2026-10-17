import Foundation

// MARK: - Brief and Full Summaries (FR12's Branch C)

/// How much a spoken summary says: the brief one Where Am I? and Speak Info
/// speak, W and Shift-Command-I, or the full one Where Am I? Full Summary
/// and Speak Full Info speak, W twice and Shift-Command-I twice (FR12,
/// section 3 of the design).
enum SummaryDetail: Equatable, Sendable {
    /// The brief summary.
    case brief
    /// The full summary.
    case full
}

/// What a press of a summary's action does, given the summary speaking, in
/// a reader (Where Am I?) and in the Library (Speak Info) alike (FR12,
/// section 3 of the design):
/// - With nothing speaking, it speaks the summary pressed for.
/// - A brief press while a summary speaks stops it, so a single press of W
///   or I after the double-press time silences a summary (question 3).
/// - A full press while the brief summary speaks switches to the full one,
///   which is how a double press's second press takes over from its first;
///   while the full summary speaks, it stops it.
/// - A press about another subject than the summary speaking, as a Library
///   row selected since, speaks the summary pressed for in its place, so a
///   summary always describes what was pressed on (REV07, Library finding
///   2).
///
/// No press depends on when the last one came: the three-second rule that
/// made a quick repeat speak the full summary is retired (question 4), so
/// the brief action always speaks the brief summary.
enum SummaryPress: Equatable, Sendable {
    /// Speak the summary pressed for, with nothing speaking.
    case speak(SummaryDetail)
    /// Stop the summary speaking, and speak nothing.
    case stop
    /// Stop the summary speaking and speak this one in its place.
    case replace(with: SummaryDetail)

    /// What a press for `pressed` does while `speaking` speaks, nil when
    /// nothing does; `sameSubject` says whether the press is about what the
    /// summary speaking describes.
    static func outcome(pressing pressed: SummaryDetail, while speaking: SummaryDetail?, sameSubject: Bool = true) -> SummaryPress {
        guard let speaking else { return .speak(pressed) }
        guard sameSubject else { return .replace(with: pressed) }
        return pressed == .full && speaking == .brief ? .replace(with: .full) : .stop
    }
}
