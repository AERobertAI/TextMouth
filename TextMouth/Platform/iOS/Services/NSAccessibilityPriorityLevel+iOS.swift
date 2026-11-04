// Phase 0 stand-in: on the Mac, NSAccessibilityPriorityLevel is AppKit's
// enumeration of how urgently VoiceOver speaks an announcement, and
// VoiceOverAnnouncer passes it along with the message. iOS has no such type,
// so shared code (the announcer and the engine's callers, which write `.high`
// and `.medium`) names this one, with the Mac's cases and raw values.
// VoiceOverAnnouncer maps it to iOS's own speech priority when it posts.

/// How urgent an announcement is: the Mac's AppKit values, kept on iOS so
/// shared code compiles unchanged.
enum NSAccessibilityPriorityLevel: Int, Sendable {
    /// Spoken after everything queued.
    case low = 10
    /// Spoken after the current speech.
    case medium = 50
    /// Spoken at once.
    case high = 90
}
