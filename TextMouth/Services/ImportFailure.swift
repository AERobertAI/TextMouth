import Foundation

/// The step an import was taking when it failed. A failure names it, so the
/// reader learns what TextMouth was doing with the file when it stopped:
/// reading it, copying it, reading its text or audio, or saving its record.
enum ImportStep: Equatable, Sendable {
    /// Checking that the file is in a format TextMouth reads.
    case checkingFormat
    /// Reading the original file, as computing its checksum does.
    case readingSource
    /// Creating the hidden package the import builds the book in.
    case preparingPackage
    /// Copying the original, or writing entered text, into that package.
    case copying
    /// Extracting a ZIP archive's audio into the package.
    case extractingArchive
    /// Checking the manifest.json an archive of audio tracks carries, before
    /// the book is read by it (`AudioManifestCheck`).
    case readingManifest
    /// Converting a DAISY book's audio into TextMouth's audio layout.
    case convertingAudio
    /// Converting the audio the import converts to .m4a (B06, FMT09), `done`
    /// of `total` tracks so far: after the archive's extraction and its
    /// manifest's check, before the audio is read, since such audio is
    /// never handed to a player.
    case convertingImportedAudio(done: Int, of: Int)
    /// Checking a .tmb package and the book it holds.
    case checkingPackage
    /// Reading the book's text into its content.md cache, as the reader will.
    case readingText
    /// Reading the text of a book read page by page, `done` of `total` pages
    /// so far: pictures of pages and comic book archives (FMT34), whose
    /// pages text recognition reads one at a time, up to seconds each. It is
    /// a part of reading the text, named the same, which the overlay counts
    /// as it counts the tracks it converts; a failure meanwhile is reading
    /// the text's (`readingText`).
    case readingPages(done: Int, of: Int)
    /// Reading the book's audio chapters, as the reader will.
    case readingAudio
    /// Writing the book's bookInfo.json and reading it back.
    case savingRecord
    /// Giving the package its final name in the library folder.
    case publishing
    /// Taking back into the library a package Remove from Library Only kept.
    case reinstating

    /// What the import was doing, as the phrase that follows a book's name
    /// in the import overlay, in lowercase: "reading its text", "copying it
    /// into the library". `activity` is the same words starting a sentence.
    var phrase: String {
        switch self {
        case .checkingFormat:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, checking its format") and, capitalized by the app, starts a failure ("Checking its format failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.checkingFormat", "checking its format")
        case .readingSource:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, reading the file") and, capitalized by the app, starts a failure ("Reading the file failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.readingSource", "reading the file")
        case .preparingPackage:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, creating its package") and, capitalized by the app, starts a failure ("Creating its package failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.preparingPackage", "creating its package")
        case .copying:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, copying it into the library") and, capitalized by the app, starts a failure ("Copying it into the library failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.copying", "copying it into the library")
        case .extractingArchive:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, extracting the archive") and, capitalized by the app, starts a failure ("Extracting the archive failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.extractingArchive", "extracting the archive")
        case .readingManifest:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, reading its manifest") and, capitalized by the app, starts a failure ("Reading its manifest failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.readingManifest", "reading its manifest")
        case .convertingAudio:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, converting its DAISY audio") and, capitalized by the app, starts a failure ("Converting its DAISY audio failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.convertingAudio", "converting its DAISY audio")
        case .convertingImportedAudio:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, converting its audio") and, capitalized by the app, starts a failure ("Converting its audio failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.convertingImportedAudio", "converting its audio")
        case .checkingPackage:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, checking the package") and, capitalized by the app, starts a failure ("Checking the package failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.checkingPackage", "checking the package")
        case .readingText, .readingPages:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, reading its text") and, capitalized by the app, starts a failure ("Reading its text failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.readingText", "reading its text")
        case .readingAudio:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, reading its audio") and, capitalized by the app, starts a failure ("Reading its audio failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.readingAudio", "reading its audio")
        case .savingRecord:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, saving its bookInfo.json file") and, capitalized by the app, starts a failure ("Saving its bookInfo.json file failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.savingRecord", "saving its bookInfo.json file")
        case .publishing:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, adding it to the library folder") and, capitalized by the app, starts a failure ("Adding it to the library folder failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.publishing", "adding it to the library folder")
        case .reinstating:
            // Translators: What an import was doing with a file when it stopped, as a phrase that follows the name of a book in the import overlay ("“Moby Dick.epub”, returning it to the library") and, capitalized by the app, starts a failure ("Returning it to the library failed: ..."). Starts with a lowercase letter and has no full stop.
            return InterfaceText.line("importStep.phrase.reinstating", "returning it to the library")
        }
    }

    /// How a failure names this step: the subject of a sentence that ends
    /// "failed", such as "Reading its text failed". The step's `phrase`
    /// starting a sentence.
    var activity: String {
        phrase.capitalizingFirstLetter
    }

    /// The step in English for the debug log, which stays English whatever
    /// language the interface speaks, begun in lowercase: "reading its text".
    var logPhrase: String {
        switch self {
        case .checkingFormat: return "checking its format" // l10n: no (debug log)
        case .readingSource: return "reading the file" // l10n: no (debug log)
        case .preparingPackage: return "creating its package" // l10n: no (debug log)
        case .copying: return "copying it into the library" // l10n: no (debug log)
        case .extractingArchive: return "extracting the archive" // l10n: no (debug log)
        case .readingManifest: return "reading its manifest" // l10n: no (debug log)
        case .convertingAudio: return "converting its DAISY audio" // l10n: no (debug log)
        case .convertingImportedAudio: return "converting its audio" // l10n: no (debug log)
        case .checkingPackage: return "checking the package" // l10n: no (debug log)
        case .readingText, .readingPages: return "reading its text" // l10n: no (debug log)
        case .readingAudio: return "reading its audio" // l10n: no (debug log)
        case .savingRecord: return "saving its bookInfo.json file" // l10n: no (debug log)
        case .publishing: return "adding it to the library folder" // l10n: no (debug log)
        case .reinstating: return "returning it to the library" // l10n: no (debug log)
        }
    }
}

/// Why an import failed: the file, the step under way, and the error that
/// stopped it. Every import path throws this once it has removed whatever it
/// staged, so the library presents every failure the same way, and nothing
/// is ever done to the original file after one (TODO S02).
struct ImportFailure: LocalizedError {
    /// The name of the file, archive, or package that was being imported.
    let fileName: String
    /// The step that failed.
    let step: ImportStep
    /// The error that stopped that step.
    let underlying: any Error

    /// What went wrong, without the file's name: "Reading its text failed:
    /// …". A ZIP batch's summary lists it after the name of the file.
    var reason: String {
        #if os(iOS)
        // A file the phone can't import yet is told as the spec words it,
        // naming the file and the next step, never as a failed step.
        if let refusal = underlying as? PhoneImportRefusal {
            return refusal.sentence(naming: PhoneImportWording.displayName(ofFileNamed: fileName))
        }
        return Self.failedSentence(step: step, because: Self.description(of: underlying))
        #else
        Self.failedSentence(step: step, because: Self.description(of: underlying))
        #endif
    }

    /// "Reading its text failed: <why>": the step, then why it failed, as one
    /// localized sentence.
    private static func failedSentence(step: ImportStep, because why: String) -> String {
        // Translators: Why an import failed: the step it was at, then the reason. %1$@ is the step starting a sentence, such as "Reading its text" or "Copying it into the library", and %2$@ the reason, a sentence of the system's or the app's.
        InterfaceText.line("importFailure.failedSentence", "\(step.activity) failed: \(why)")
    }

    /// The same reason in English, for the debug log, which stays English
    /// whatever language the interface speaks.
    var logReason: String {
        "\(step.logPhrase.capitalizingFirstLetter) failed: \(Self.logDescription(of: underlying))" // l10n: no (debug log)
    }

    /// The whole sentence an alert reads: the file, then the reason.
    var errorDescription: String? {
        #if os(iOS)
        // The refusal's sentence names the file itself.
        if underlying is PhoneImportRefusal { return reason }
        return SentenceWording.joined([ImportProgressWording.failed(fileName), reason])
        #else
        SentenceWording.joined([ImportProgressWording.failed(fileName), reason])
        #endif
    }

    /// The single debug-log line recording this failure:
    /// `IMPORT_FAILED: <file>: <reason>`. A line break in the name or in
    /// the reason becomes a space, so the entry stays on one line.
    var logLine: String {
        "IMPORT_FAILED: \(fileName): \(logReason)"
            .components(separatedBy: .newlines)
            .joined(separator: " ")
    }

    /// Records this failure as an import event, in the console and the
    /// debug log.
    func log() {
        DiagnosticLog.event(.import, logLine)
    }

    /// The reason `error` gives for a failed import, without a file name:
    /// an `ImportFailure`'s own reason, or any other error's description,
    /// which is `outOfSpaceDescription` for a full disk.
    static func reason(for error: any Error) -> String {
        (error as? ImportFailure)?.reason ?? description(of: error)
    }

    /// What is said when a copy fails for lack of space. The system's own
    /// sentence names the hidden staged package (".import-<id>.tmb"), an
    /// internal name the listener never chose and VoiceOver would read out.
    static var outOfSpaceDescription: String {
        // Translators: Why an import failed when the disk is full. Said instead of the system's own sentence, which names a hidden internal file.
        InterfaceText.line("importFailure.outOfSpaceDescription", "There isn’t enough free space on the disk.")
    }

    /// Whether `error`, or an error it wraps under `NSUnderlyingErrorKey` at
    /// any depth, says the volume is full: Cocoa's
    /// `NSFileWriteOutOfSpaceError` or POSIX `ENOSPC`.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let inner = nsError.userInfo[NSUnderlyingErrorKey] as? any Error { return isOutOfSpace(inner) }
        return false
    }

    /// How a failed step's error is worded: the plain sentence for a full
    /// disk, the error's own description for anything else.
    private static func description(of error: any Error) -> String {
        isOutOfSpace(error) ? outOfSpaceDescription : error.localizedDescription
    }

    /// How a failed step's error is worded in English for the debug log: the
    /// plain sentence for a full disk, an error that words itself for the log
    /// (`LogDescribing`) by its `logDescription`, anything else by its own
    /// description.
    static func logDescription(of error: any Error) -> String {
        if isOutOfSpace(error) { return "There isn’t enough free space on the disk." } // l10n: no (debug log)
        return (error as? any LogDescribing)?.logDescription ?? error.localizedDescription
    }
}

/// Lets a test act on the package an import is building as each step that
/// works on it begins: make the package read-only, report a full disk, or
/// stop the import before it is published. It is passed the step and the
/// package's directory; an error it throws fails the import at that step,
/// exactly as a real failure there would.
typealias ImportStepObserver = (_ step: ImportStep, _ package: URL) throws -> Void

/// One import in progress: the file a failure would name, the step under
/// way, and the observer told as each step on the package begins.
struct ImportRun {
    /// The name of the file being imported.
    let fileName: String
    /// The step under way, which a failure is attributed to.
    private(set) var step: ImportStep = .checkingFormat
    /// Told as each step that works on the package begins; nil outside tests.
    let observer: ImportStepObserver?

    /// Starts `step`. A step that works on the package names its directory,
    /// and the observer, if any, is told before the step does anything.
    mutating func begin(_ step: ImportStep, in package: URL? = nil) throws {
        self.step = step
        if let package, let observer {
            try observer(step, package)
        }
    }

    /// Runs `body` as the import of `fileName`. Any error it throws becomes
    /// an `ImportFailure` naming the step `body` had begun, which is logged
    /// once and rethrown. A failure from an import nested inside this one
    /// (one ZIP member, say) already names its own file and step and was
    /// already logged, so it passes through unchanged.
    static func perform<Value>(
        importing fileName: String,
        observer: ImportStepObserver? = nil,
        _ body: (inout ImportRun) throws -> Value
    ) throws -> Value {
        var run = ImportRun(fileName: fileName, observer: observer)
        do {
            return try body(&run)
        } catch let failure as ImportFailure {
            throw failure
        } catch let cancelled as ImportCancelled {
            // The reader cancelled the import while a conversion ran (the
            // Cancel button killed it): not a failure, so it is passed on
            // as it is, and logged as a cancellation.
            ImportCancellation.log(fileName, stopped: "while \(run.step.logPhrase)")
            throw cancelled
        } catch {
            let failure = ImportFailure(fileName: fileName, step: run.step, underlying: error)
            failure.log()
            throw failure
        }
    }
}
