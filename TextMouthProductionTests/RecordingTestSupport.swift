import AVFoundation
import os
import XCTest
@testable import TextMouth

// Fakes shared by the recording tests, so each exists once. No test of
// recording ever reaches a microphone or macOS's permission prompt: each
// hands the recorder one of these instead.

// MARK: - Microphone Permission

/// A microphone permission that answers as a test tells it, and counts how
/// often it was asked, so a test can tell that a recording asked once, or
/// never. Asking while nobody has answered changes the answer it holds, as
/// macOS's prompt does: to authorized for a yes, and for a no to denied, or
/// to restricted when `restrictsWhenAsked` says something forbade asking.
final class FakeMicrophonePermission: Sendable {
    /// What the permission holds: the answer, how a question is answered,
    /// and how many were asked. Behind a lock, since the recorder asks from
    /// whatever thread its task runs on.
    private struct State {
        var status: AudioInputAuthorization
        var answer: Bool
        var restrictsWhenAsked: Bool
        var questions = 0
    }

    /// The state, read and changed only under its lock.
    private let state: OSAllocatedUnfairLock<State>

    /// A permission holding `status`, which answers a question with
    /// `answer` while nobody has answered.
    init(_ status: AudioInputAuthorization, whenAsked answer: Bool = false, restrictsWhenAsked: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(
            status: status,
            answer: answer,
            restrictsWhenAsked: restrictsWhenAsked
        ))
    }

    /// How many times the permission was asked.
    var questions: Int {
        state.withLock { $0.questions }
    }

    /// The answer it holds now.
    var status: AudioInputAuthorization {
        state.withLock { $0.status }
    }

    /// The permission to hand a recorder.
    var permission: AudioInputPermission {
        AudioInputPermission(
            status: { [self] in status },
            request: { [self] in
                state.withLock { state in
                    state.questions += 1
                    if state.status == .notDetermined {
                        state.status = state.answer
                            ? .authorized
                            : (state.restrictsWhenAsked ? .restricted : .denied)
                    }
                    return state.status == .authorized
                }
            }
        )
    }
}
