import Foundation

/// What an iOS stand-in throws for work the iPhone app cannot do yet (phase 0
/// of the iOS port): starting a helper program, opening a file in another
/// app, or anything else only the Mac's version of a type does. The Mac never
/// compiles this file. Each case's words are a full sentence, since a person
/// may hear them as an error.
enum IOSUnavailable: LocalizedError, Equatable {
    /// `feature` names the work in a short phrase that completes "… is not
    /// available on iPhone yet.", such as "Converting this kind of file".
    case feature(String)

    /// The sentence a person hears: "Converting this kind of file is not
    /// available on iPhone yet."
    var errorDescription: String? {
        switch self {
        case let .feature(name):
            return "\(name) is not available on iPhone yet."
        }
    }
}
