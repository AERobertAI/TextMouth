import Foundation
import os

/// The call every interface string goes through (FR39). Beside the core files because it reads the app's state
/// (`InterfaceLanguage`), which the core must not.
extension InterfaceText {
    /// The text of the line `id` in the language in use.
    ///
    /// - Parameters:
    ///   - id: The line's permanent ID, `owner.member[.case]` in lower camel case. A `StaticString`, so it can only be
    ///     a literal, which the sync tool reads.
    ///   - english: The line's English as the code holds it, with its arguments: `"Starting: \(title)"`, or
    ///     `"\(number: count) books"`.
    /// - Returns: The language's text, formatted with the interface locale; the call's own English when there is no
    ///   pack, no entry, or a text that fails its check. Safe on any thread, and never traps.
    nonisolated static func line(_ id: StaticString, _ english: Format) -> String {
        line(id, english, state: InterfaceLanguage.current)
    }

    /// The text of the line `id` in `language`, for tests and for title sets (a menu's title in another language).
    /// Under the language already in use it formats with the system's locale, else with `locale(forScope:)`.
    nonisolated static func line(_ id: StaticString, _ english: Format, language: String) -> String {
        let current = InterfaceLanguage.current
        return line(id, english, state: current.language == language ? current : InterfaceLanguage.state(forScope: language))
    }

    /// The one place a lookup meets the shared engine.
    private nonisolated static func line(_ id: StaticString, _ english: Format, state: InterfaceLanguage.State) -> String {
        InterfaceTextEngine.shared.text(id: id, english: english, language: state.language, locale: state.locale)
    }

    // MARK: - Problems

    /// Where a problem goes. The app sets it at launch to its debug log; until then a problem is dropped. The core
    /// never imports the logger.
    private static let problemHook = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// Sets where the engine reports a problem (a missing or damaged pack, an unknown ID, a text that fails its check),
    /// once each, in English.
    static func reportProblems(to hook: (@Sendable (String) -> Void)?) {
        problemHook.withLockUnchecked { $0 = hook }
    }

    /// Sends the engine's problems to the debug log, as `INTERFACE_TEXT_PROBLEM: <sentence>` event lines
    /// (`LogContentPolicyTests` lists the tag with the others). Both apps call it once at launch, before the first
    /// lookup. The sentences are English and hold no user content: an ID, a language code, and the system's reason a
    /// file could not be read.
    static func reportProblemsToDiagnosticLog() {
        reportProblems { problem in
            DiagnosticLog.event(.app, "INTERFACE_TEXT_PROBLEM: \(problem)")
        }
    }

    /// Passes `problem` to the hook the app set, if it set one.
    fileprivate static func reportProblem(_ problem: String) {
        let hook = problemHook.withLockUnchecked { $0 }
        hook?(problem)
    }
}

extension InterfaceTextEngine {
    /// The engine the apps use: the pack in the main bundle, reporting to the hook the app set.
    static let shared = InterfaceTextEngine(open: { try InterfaceTextPack.inMainBundle() }, report: { InterfaceText.reportProblem($0) })
}
