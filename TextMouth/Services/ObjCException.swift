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

    /// What a call raised, as a Swift error: the exception's name and reason,
    /// for the debug log.
    struct Raised: Error, Equatable {
        /// The exception's name, such as `NSInvalidArgumentException`.
        let name: String
        /// The reason it gave, when it gave one.
        let reason: String?

        /// What `exception` raised.
        init(_ exception: NSException) {
            self.init(name: exception.name.rawValue, reason: exception.reason)
        }

        /// Names and reasons, as the log and a failed render say them.
        init(name: String, reason: String?) {
            self.name = name
            self.reason = reason
        }

        /// The name and the reason, as `<name>: <reason>`, or "no reason
        /// given" when the exception gave none.
        var summary: String {
            "\(name): \(reason ?? "no reason given")" // l10n: no (debug log text)
        }
    }

    /// Runs `make`, which creates something through a framework API that
    /// raises an Objective-C exception for arguments it refuses (the
    /// initializers of AVAssetReader and AVAssetWriter outputs and inputs do,
    /// for sample layouts they don't take), and returns what it made.
    ///
    /// - Parameter make: The call that may raise.
    /// - Throws: `Raised`, naming the exception, when `make` raised.
    static func making<Value>(_ make: () -> Value) throws -> Value {
        var made: Value?
        if let exception = catching({ made = make() }) {
            throw Raised(exception)
        }
        // Without an exception `make` ran to its end, so `made` is set.
        guard let made else { throw Raised(name: "NoValue", reason: nil) }
        return made
    }

    /// The one-line form of a caught exception for the log, as
    /// `SPEECH_PLAYER_EXCEPTION: <name>: <reason>`: the name and the
    /// reason, or "no reason given" when the exception has none.
    static func logLine(tag: String, for exception: NSException) -> String {
        "\(tag): \(Raised(exception).summary)"
    }
}
