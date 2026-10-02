import Foundation

/// What an operation the user asked for actually did, returned to the
/// workflow that asked so it can report the result where the user is
/// working (TODO A07). A sheet closes only after a success and otherwise
/// stays open with the user's input and the reason; the Storage settings
/// status line says "Done" only after a success. Nothing is assumed from
/// having made the call.
enum OperationOutcome: Equatable {
    /// The operation did what was asked. The message describes the result
    /// where the workflow reports one, such as the Storage settings status
    /// line, and is nil where success speaks for itself, such as a sheet
    /// that closes.
    case success(String?)
    /// The operation was refused, or it failed and was rolled back. The
    /// message says what failed and why, in the words of the library's
    /// error alert.
    case failure(String)

    /// A failure worded the way the library's error alert words one:
    /// "<context>: <reason>", for example "Could not move books: The file
    /// already exists."
    static func failure(_ context: String, _ error: Error) -> OperationOutcome {
        .failure("\(context): \(error.localizedDescription)")
    }

    /// Whether the operation did what was asked.
    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    /// The words that report this outcome, when there are any.
    var message: String? {
        switch self {
        case .success(let message): return message
        case .failure(let message): return message
        }
    }

    /// Why the operation failed, or nil when it succeeded.
    var failureMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }
}
