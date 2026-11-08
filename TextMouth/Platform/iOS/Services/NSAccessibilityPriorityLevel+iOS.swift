// Phase 0 stand-in: on the Mac, NSAccessibilityPriorityLevel is AppKit's
// enumeration of how urgently VoiceOver speaks an announcement, and
// VoiceOverAnnouncer passes it along with the message. iOS has no such type,
// so shared code (the announcer and the engine's callers, which write `.high`
// and `.medium`) names this one, with the Mac's cases and raw values.
// VoiceOverAnnouncer maps it to iOS's own speech priority when it posts.

/// How urgent an announcement is: the Mac's AppKit values, kept on iOS so
/// shared code compiles unchanged. On iOS, VoiceOverAnnouncer posts high and
/// medium at UIKit's default priority, which "will interrupt existing speech,
/// but [is] interruptible if a new speech utterance is started", and low at
/// UIKit's low, which is "queued and spoken when other speech utterances have
/// completed" (UIAccessibilityConstants.h). The few words that must not be
/// cut off take `PhoneAnnouncer.important`, which posts at UIKit's high.
enum NSAccessibilityPriorityLevel: Int, Sendable {
    /// On the Mac, spoken after everything queued; on iOS, queued until
    /// VoiceOver's current speech has finished.
    case low = 10
    /// On the Mac, spoken after the current speech; on iOS, posted at the
    /// default priority, which interrupts it.
    case medium = 50
    /// On the Mac, spoken at once; on iOS, posted at the default priority,
    /// which interrupts the current speech and can itself be cut off.
    case high = 90
}
