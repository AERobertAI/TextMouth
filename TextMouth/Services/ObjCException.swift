import Foundation
import ObjCExceptionCatcher

/// A way to call a framework API that may raise an Objective-C exception.
///
/// Swift cannot catch such an exception, so one raised inside a framework
/// call ends the process; the call is made through here instead. This is
/// the only Swift file that imports the catcher's module.
enum ObjCException {
    /// Runs `body` and returns the Objective-C exception it raised, or nil
    /// when it returned normally. The block is not kept: it runs before
    /// this returns.
    ///
    /// - Parameter body: The call that may raise.
    static func catching(_ body: () -> Void) -> NSException? {
        TMCatchException(body)
    }

    /// The one-line form of a caught exception for the log, as
    /// `SPEECH_PLAYER_EXCEPTION: <name>: <reason>`: the name and the
    /// reason, with a reason the exception lacks left out.
    static func logLine(tag: String, for exception: NSException) -> String {
        "\(tag): \(exception.name.rawValue): \(exception.reason ?? "no reason given")"
    }
}
