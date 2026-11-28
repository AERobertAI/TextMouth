import Foundation

/// What an iOS stand-in throws for work the iPhone app cannot do yet (phase 0
/// of the iOS port): starting a helper program, opening a file in another
/// app, or anything else only the Mac's version of a type does. The Mac never
/// compiles this file. Each case's words are a full sentence, since a person
/// may hear them as an error.
///
/// The work the iPhone's own files name has a case of its own, whose sentence
/// is whole and localized (FR34). `feature(_:)` is the English phrase that
/// other areas' callers pass until they convert; delete it when none is left.
enum IOSUnavailable: LocalizedError, LogDescribing, Equatable {
    /// `feature` names the work in a short English phrase that completes "… is
    /// not available on iPhone yet.", such as "Opening TextMouth again".
    case feature(String)
    /// An FFmpeg-free conversion the iPhone has no helper program for.
    case convertingThisKindOfFile
    /// Opening a file in another app to edit it and take it back.
    case editingInAnotherApp
    /// Showing the logs in Finder, which the iPhone has not.
    case showingLogsInFinder

    /// The sentence a person hears: "Converting this kind of file is not
    /// available on iPhone yet."
    var errorDescription: String? {
        switch self {
        case let .feature(name):
            // Whole sentences stay English until the callers' areas convert, since a
            // localized frame around an English phrase would read as a mixture.
            return "\(name) is not available on iPhone yet." // l10n: no (the callers' English phrase inside an English sentence until their areas convert)
        case .convertingThisKindOfFile:
            // Translators: Error text when the iPhone app is asked to convert an audio file in a way only the Mac's helper program can.
            return InterfaceText.line("iosUnavailable.convertingThisKindOfFile", "Converting this kind of file isn't available on iPhone yet.")
        case .editingInAnotherApp:
            // Translators: Error text when the iPhone app is asked to open a file in another app to edit it and take it back.
            return InterfaceText.line("iosUnavailable.editingInAnotherApp", "Editing in another app isn't available on iPhone yet.")
        case .showingLogsInFinder:
            // Translators: What the iPhone's Settings says when asked to show the logs in Finder, which the iPhone does not have.
            return InterfaceText.line("iosUnavailable.showingLogsInFinder", "Showing the logs in Finder isn't available on iPhone yet.")
        }
    }

    /// The error in English for the debug log, which never holds the interface language.
    var logDescription: String {
        let name: String
        switch self {
        case let .feature(phrase): name = phrase
        case .convertingThisKindOfFile: name = "Converting this kind of file" // l10n: no (the debug log's English)
        case .editingInAnotherApp: name = "Editing a file in another app" // l10n: no (the debug log's English)
        case .showingLogsInFinder: name = "Showing the logs in Finder" // l10n: no (the debug log's English)
        }
        return "\(name) is not available on iPhone yet." // l10n: no (the debug log's English)
    }
}
