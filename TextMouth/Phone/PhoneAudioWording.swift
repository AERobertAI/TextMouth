import Foundation

/// The words the iPhone's audio session says to the listener.
enum PhoneAudioWording {
    /// Said when Play can't take the audio, as during a phone call: the session
    /// refused to activate, so nothing would be heard (the engineer's review,
    /// F7). The book stays as it was, and Play tries again.
    static let cannotPlayNow = "Can't play now: a call or another app is using the audio."
}
