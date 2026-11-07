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
    /// Reading the book's audio chapters, as the reader will.
    case readingAudio
    /// Writing the book's bookInfo.json and reading it back.
    case savingRecord
    /// Giving the package its final name in the library folder.
    case publishing
    /// Taking back into the library a package Remove from Library Only kept.
    case reinstating

    /// How a failure names this step: the subject of a sentence that ends
    /// "failed", such as "Reading its text failed".
    var activity: String {
        switch self {
        case .checkingFormat: return "Checking its format"
        case .readingSource: return "Reading the file"
        case .preparingPackage: return "Creating its package"
        case .copying: return "Copying it into the library"
        case .extractingArchive: return "Extracting the archive"
        case .readingManifest: return "Reading its manifest"
        case .convertingAudio: return "Converting its DAISY audio"
        case .convertingImportedAudio: return "Converting its audio"
        case .checkingPackage: return "Checking the package"
        case .readingText: return "Reading its text"
        case .readingAudio: return "Reading its audio"
        case .savingRecord: return "Saving its bookInfo.json file"
        case .publishing: return "Adding it to the library folder"
        case .reinstating: return "Returning it to the library"
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
        #endif
        return "\(step.activity) failed: \(Self.description(of: underlying))"
    }

    /// The whole sentence an alert reads: the file, then the reason.
    var errorDescription: String? {
        #if os(iOS)
        // The refusal's sentence names the file itself.
        if underlying is PhoneImportRefusal { return reason }
        #endif
        return "Could not import “\(fileName)”. \(reason)"
    }

    /// The single debug-log line recording this failure:
    /// `IMPORT_FAILED: <file>: <reason>`. A line break in the name or in
    /// the reason becomes a space, so the entry stays on one line.
    var logLine: String {
        "IMPORT_FAILED: \(fileName): \(reason)"
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
    static let outOfSpaceDescription = "There isn’t enough free space on the disk."

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
            ImportCancellation.log(fileName, stopped: "while \(run.step.activity.lowercased())")
            throw cancelled
        } catch {
            let failure = ImportFailure(fileName: fileName, step: run.step, underlying: error)
            failure.log()
            throw failure
        }
    }
}
