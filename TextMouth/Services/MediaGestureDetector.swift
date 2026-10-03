import Foundation
import os

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
///
/// ## Threads
/// MPRemoteCommand callbacks may arrive on the main queue or on one of the
/// framework's own queues (Apple does not say which), so the detector may
/// be used from any thread: everything it knows, its configuration and its
/// buffer alike, is kept under one lock, which makes it Sendable (TODO Q06).
final class MediaGestureDetector: Sendable {
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

    /// Everything the detector knows. Kept under one lock so that two rapid
    /// presses arriving on different queues cannot race `recordEvent`'s
    /// read-modify-write of the buffer and corrupt it, and so that each
    /// event is matched against one consistent configuration.
    private struct State {
        /// See `pattern`.
        var pattern: [EventType] = []
        /// See `window`.
        var window: TimeInterval = 2.0
        /// See `isEnabled`.
        var isEnabled = false
        /// Rolling buffer of recently observed events. Trimmed on every
        /// recordEvent to drop entries older than `window` from the
        /// arrival of the latest event, so the matcher only ever inspects
        /// timely sequences.
        var buffer: [(type: EventType, timestamp: Date)] = []
    }

    /// The detector's state, read and written only through `withLock`.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Configured sequence the user wants to match. A 3-element pattern
    /// requires the last 3 events in the buffer to match in order. An
    /// empty pattern always returns false (effectively disabled).
    var pattern: [EventType] {
        get { state.withLock { $0.pattern } }
        set { state.withLock { $0.pattern = newValue } }
    }

    /// Maximum elapsed time across the WHOLE pattern (first event to
    /// last event). 2 seconds is the default — long enough for a
    /// deliberate sequence but short enough that ordinary use of media
    /// keys won't collide.
    var window: TimeInterval {
        get { state.withLock { $0.window } }
        set { state.withLock { $0.window = newValue } }
    }

    /// Whether the detector should run at all. When false,
    /// `recordEvent` returns false immediately and doesn't grow the
    /// buffer — a tiny saving but more importantly a clean off-switch.
    var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

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
        // Hold the lock for the whole read-modify-write cycle.
        // recordEvent runs in microseconds even with a max-length
        // pattern, so blocking briefly here is preferable to a fancier
        // lock-free scheme.
        state.withLock { current in
            guard current.isEnabled, !current.pattern.isEmpty else { return false }

            // Trim entries older than the window measured from THIS event.
            // Using the latest event as the anchor (rather than the first
            // event in the buffer) means the user has the full window to
            // complete the gesture from the moment they started pressing.
            let cutoff = now.addingTimeInterval(-current.window)
            current.buffer.removeAll { $0.timestamp < cutoff }

            // Append after trimming so the latest event is always present
            // even if the buffer was just emptied by an extra-long pause.
            current.buffer.append((type: type, timestamp: now))

            // Cap buffer size at pattern length — older entries can't
            // contribute to a match. Keeping more would only burn memory.
            if current.buffer.count > current.pattern.count {
                current.buffer.removeFirst(current.buffer.count - current.pattern.count)
            }

            // Need at least pattern.count entries to match.
            guard current.buffer.count == current.pattern.count else { return false }

            // All entries must already be inside the window thanks to the
            // trim above; the order check is the remaining condition.
            for (index, expected) in current.pattern.enumerated() {
                if current.buffer[index].type != expected { return false }
            }

            // Match — reset so the next gesture starts fresh.
            current.buffer.removeAll()
            return true
        }
    }

    /// Reset the buffer without changing pattern / window / enabled.
    /// Useful when the gesture is reconfigured mid-sequence — drop
    /// the half-matched in-flight events so the user starts fresh.
    func reset() {
        state.withLock { $0.buffer.removeAll() }
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
