import Foundation

/// Detects a configurable sequence of media-control events within a
/// time window, intended for AirPods / Bluetooth-headphone gestures
/// that wouldn't ordinarily mean anything on their own.
///
/// ## Why this exists
/// Restarting an expired sleep timer normally requires opening the
/// timer sheet and clicking a preset, or pressing a keyboard shortcut.
/// Both options assume the user is at the keyboard. A gesture pattern
/// like "previous-track three times within two seconds" is something
/// most users never do accidentally, and AirPods support previous /
/// next / play-pause out of the box — so the gesture works hands-free
/// from across the room.
///
/// ## How it matches
/// `recordEvent` adds the event to a rolling buffer with a timestamp,
/// then trims everything older than the configured time window. If
/// the trailing N events in the buffer (where N is the pattern length)
/// match the configured pattern, the detector returns `true`. The
/// caller is expected to suppress the original media command for that
/// final event (so a "prev-prev-prev" gesture only navigates back
/// twice, with the third press consumed by the gesture itself) and
/// invoke the gesture's action via the supplied notification name.
///
/// ## Why suppress the final event
/// Without suppression, the user's chosen pattern would have audible
/// side effects every time it fires — e.g. a "play, play, play" pattern
/// would start playback when the user only meant to restart the timer.
/// Suppressing the LAST event keeps the leading N-1 events intact (the
/// user got most of what they pressed) but spares them the unwanted
/// final action.
class MediaGestureDetector {
    /// The kinds of media events the detector understands. Limited to
    /// commands that MPRemoteCommandCenter delivers reliably on macOS:
    /// volume isn't included because it's not routed through the
    /// command center on this platform, and AirPods physical gestures
    /// already map onto play/pause/next/previous via system settings.
    enum EventType: String, Codable, CaseIterable {
        case play
        case pause
        case togglePlayPause
        case previousTrack
        case nextTrack
        case skipForward
        case skipBackward

        /// Display name for settings UI / VoiceOver descriptions.
        var displayName: String {
            switch self {
            case .play: return "Play"
            case .pause: return "Pause"
            case .togglePlayPause: return "Play/Pause toggle"
            case .previousTrack: return "Previous track"
            case .nextTrack: return "Next track"
            case .skipForward: return "Skip forward"
            case .skipBackward: return "Skip backward"
            }
        }
    }

    /// Configured sequence the user wants to match. A 3-element pattern
    /// requires the last 3 events in the buffer to match in order. An
    /// empty pattern always returns false (effectively disabled).
    var pattern: [EventType] = []

    /// Maximum elapsed time across the WHOLE pattern (first event to
    /// last event). 2 seconds is the default — long enough for a
    /// deliberate sequence but short enough that ordinary use of media
    /// keys won't collide.
    var window: TimeInterval = 2.0

    /// Whether the detector should run at all. When false,
    /// `recordEvent` returns false immediately and doesn't grow the
    /// buffer — a tiny saving but more importantly a clean off-switch.
    var isEnabled: Bool = false

    /// Rolling buffer of recently observed events. Trimmed on every
    /// recordEvent to drop entries older than `window` from the
    /// arrival of the latest event, so the matcher only ever inspects
    /// timely sequences.
    /// All access is serialised through `lock` because MPRemoteCommand
    /// callbacks may arrive on either the main queue or one of the
    /// framework's internal queues (Apple does not guarantee), so two
    /// rapid presses could otherwise race the read-modify-write
    /// sequence below and corrupt the buffer.
    private var buffer: [(type: EventType, timestamp: Date)] = []
    private let lock = NSLock()

    /// Cap on user-configured pattern length. The settings UI also
    /// enforces this, but the detector defends in depth: a corrupted
    /// or externally-edited config can't slow event processing to a
    /// crawl with a pathologically long pattern.
    static let maxPatternLength = 8

    /// Record an incoming media event. Returns true exactly when the
    /// trailing entries of the buffer match the configured pattern in
    /// order, ALL within the configured time window. After a match
    /// the buffer is cleared so the next match requires a fresh
    /// pattern from scratch — without this, a single trailing event
    /// would stay in the buffer and combine with new events into
    /// spurious second matches.
    @discardableResult
    func recordEvent(_ type: EventType) -> Bool {
        recordEvent(type, at: Date())
    }

    /// Timestamp-injectable form of ``recordEvent(_:)``. Keeping time as an
    /// input makes the window-boundary behavior deterministic to test while
    /// the public call site continues to use the current wall-clock time.
    @discardableResult
    func recordEvent(_ type: EventType, at now: Date) -> Bool {
        guard isEnabled, !pattern.isEmpty else { return false }

        // Hold the lock for the whole read-modify-write cycle.
        // recordEvent runs in microseconds even with a max-length
        // pattern, so blocking briefly here is preferable to a fancier
        // lock-free scheme.
        lock.lock()
        defer { lock.unlock() }

        // Trim entries older than the window measured from THIS event.
        // Using the latest event as the anchor (rather than the first
        // event in the buffer) means the user has the full window to
        // complete the gesture from the moment they started pressing.
        let cutoff = now.addingTimeInterval(-window)
        buffer.removeAll { $0.timestamp < cutoff }

        // Append after trimming so the latest event is always present
        // even if the buffer was just emptied by an extra-long pause.
        buffer.append((type: type, timestamp: now))

        // Cap buffer size at pattern length — older entries can't
        // contribute to a match. Keeping more would only burn memory.
        if buffer.count > pattern.count {
            buffer.removeFirst(buffer.count - pattern.count)
        }

        // Need at least pattern.count entries to match.
        guard buffer.count == pattern.count else { return false }

        // All entries must already be inside the window thanks to the
        // trim above; the order check is the remaining condition.
        for (index, expected) in pattern.enumerated() {
            if buffer[index].type != expected { return false }
        }

        // Match — reset so the next gesture starts fresh.
        buffer.removeAll()
        return true
    }

    /// Reset the buffer without changing pattern / window / enabled.
    /// Useful when the gesture is reconfigured mid-sequence — drop
    /// the half-matched in-flight events so the user starts fresh.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    // MARK: - Pattern <-> String Encoding

    /// Encode a pattern as a comma-separated raw-value string for
    /// settings persistence. Reverse of `Self.patternFromString`.
    static func patternToString(_ pattern: [EventType]) -> String {
        pattern.map { $0.rawValue }.joined(separator: ",")
    }

    /// Decode a pattern from the comma-separated string format used
    /// in settings. Unknown / malformed entries are dropped silently
    /// — a partly-corrupted setting yields a partly-functional pattern
    /// rather than nothing at all, and the user can fix it from the UI.
    /// Truncated to `maxPatternLength` so a malicious or accidentally
    /// huge stored value can't bloat memory or slow event processing.
    static func patternFromString(_ string: String) -> [EventType] {
        let parsed = string
            .split(separator: ",")
            .compactMap { EventType(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        if parsed.count > maxPatternLength {
            return Array(parsed.prefix(maxPatternLength))
        }
        return parsed
    }
}
