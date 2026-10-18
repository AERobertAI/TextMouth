import Foundation

// MARK: - The Formats

/// The formats Apple's `/usr/bin/textutil` reads for TextMouth (FMT13): the
/// rich text family and the word processors' documents that are not
/// TextMouth's own to read. The raw value of each case is the name
/// textutil's `-format` option takes.
///
/// The format is always named to textutil and never left for it to guess:
/// with no `-format`, textutil reads random bytes named ".doc" as plain
/// text and hands garbage back, while `-format doc` refuses them.
enum TextutilInputFormat: String, CaseIterable, Sendable {
    /// Rich Text Format.
    case rtf
    /// Rich text with attachments: a folder, not a file.
    case rtfd
    /// Word 97-2003: a .doc, and a .dot, which textutil reads as a .doc.
    case doc
    /// OpenDocument text: an .odt, and an .ott, which textutil reads as an .odt.
    case odt
    /// Word 2003 XML, whatever its file name.
    case wordml

    /// The kind of document, in the words a refusal uses.
    var documentName: String {
        switch self {
        case .rtf: return "rich text document"
        case .rtfd: return "rich text document with attachments"
        case .doc: return "Word 97-2003 document"
        case .odt: return "OpenDocument text document"
        case .wordml: return "Word 2003 XML document"
        }
    }

    /// The indefinite article that goes before `documentName`: "an" before
    /// a vowel sound ("OpenDocument"), "a" before the rest.
    var article: String {
        self == .odt ? "an" : "a"
    }
}

// MARK: - The Converter

/// Reads a document through `textutil`, in a child process under the
/// watchdog (`WatchedProcess`), and returns the HTML textutil writes from it.
///
/// Apple's readers for these formats can hang or crash, so TextMouth never
/// runs them in its own process: a hang or a crash costs the child, never
/// the app or the import. This is the same arrangement `OggAudioConverter`
/// makes for afconvert. This type only runs the child and reads what it
/// wrote; what the HTML means, and where it is imported, are the business of
/// the code that calls it.
///
/// Measured on October 18, 2026: every sample converts in 0.02 to 0.05
/// second, peaking at 12 to 18 MB of memory; a 3.3 MB RTF takes 1.1 seconds
/// and 59 MB.
enum TextutilConverter {
    // MARK: Failures

    /// Why a document could not be read; each sentence is read to the
    /// listener after the import's own ("Could not import ... failed: "), so
    /// none names the file.
    enum Failure: LocalizedError, Equatable {
        /// textutil could not read the file as this format: damaged, or
        /// another kind of file.
        case unreadable(TextutilInputFormat)
        /// The watchdog stopped textutil, for this reason in words
        /// (`WatchedProcess.KillReason.words`).
        case stopped(reason: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(format):
                return "This file could not be read as \(format.article) \(format.documentName). "
                    + "It may be damaged, or another kind of file."
            case let .stopped(reason):
                return "TextMouth stopped reading this document because \(reason)."
            }
        }
    }

    // MARK: The Tool

    /// What runs a conversion, and what watches it: textutil under the
    /// watchdog's rules in the app, replaced in tests by a stand-in child
    /// (a `sleep`, or a script) and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments that write the HTML of `input`,
        /// read as `format`, to `output`.
        var command: @Sendable (_ input: URL, _ format: TextutilInputFormat, _ output: URL)
            -> (executable: URL, arguments: [String])
        /// What the watchdog allows a conversion of a document of the given
        /// size in bytes.
        var limits: @Sendable (_ bytes: Int64) -> WatchedProcess.Limits
        /// How the watchdog reads the child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?

        /// Apple's own converter.
        static let textutil = Tool(
            command: { input, format, output in
                (URL(fileURLWithPath: "/usr/bin/textutil"), TextutilConverter.arguments(input: input, format: format, output: output))
            },
            limits: { TextutilConverter.limits(forBytes: $0) },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    /// The tool conversions use: Apple's textutil, unless a test binds a
    /// stand-in with `TextutilConverter.$tool.withValue(_:operation:)`, which
    /// reaches every conversion that operation makes on its own thread,
    /// however deep in an import or a reader's load it is made (a count of
    /// runs, a child that hangs). It is read on the caller's thread, as
    /// `DocumentByteLimit.current` is: a detached task does not inherit it.
    @TaskLocal static var tool: Tool = .textutil

    /// The suffix of the hidden file textutil writes: ".<UUID>.textutil.html".
    /// Named once, so a leftover can be found by it.
    static let temporarySuffix = ".textutil.html"

    /// textutil's arguments for reading `input` as `format` and writing HTML
    /// to `output`.
    static func arguments(input: URL, format: TextutilInputFormat, output: URL) -> [String] {
        [
            "-convert", "html",
            // Load no subsidiary resources and nothing from the network.
            "-noload",
            // Write no attachments beside the output (an RTFD's pictures).
            "-nostore",
            // Never guess the format: a wrong guess reads garbage as text.
            "-format", format.rawValue,
            // The HTML is UTF-8, which `html(of:as:workingIn:using:)` decodes.
            "-encoding", "UTF-8",
            "-output", output.path,
            // The end of the options, so a file name that starts with "-" is
            // never taken for one.
            "--", input.path,
        ]
    }

    /// What the watchdog allows for a document of `bytes` bytes: 30 seconds
    /// and one more for each million bytes, 1 GiB of memory (as afconvert's),
    /// and a stall allowance as long as the time allowance. textutil writes
    /// its output only at the end, so a shorter one would kill every
    /// conversion while it was still reading. The CPU allowance stays at its
    /// default, four times the wall clock.
    static func limits(forBytes bytes: Int64) -> WatchedProcess.Limits {
        let seconds = 30 + Double(bytes) / 1_000_000
        return WatchedProcess.Limits(
            maximumSeconds: seconds,
            maximumResidentBytes: 1_073_741_824,
            maximumStalledSeconds: seconds
        )
    }

    // MARK: Sizing

    /// The size of the document at `url` in bytes: a file's own size, and
    /// for a folder (an RTFD) the sum of the sizes of the regular files
    /// anywhere inside it. A symbolic link inside it is never followed, so a
    /// link cannot make a small folder read a large file outside it.
    static func documentSize(of url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard try url.resourceValues(forKeys: keys).isDirectory == true else {
            return Int64(try url.resourceValues(forKeys: keys).fileSize ?? 0)
        }
        // An unreadable entry is skipped rather than ending the walk.
        let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        )
        var total: Int64 = 0
        while let entry = walk?.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Converting

    /// The HTML textutil writes from the document at `source`, read as
    /// `format`. Synchronous, for the import and the Markdown cache, which
    /// run off the main thread. `folder` holds the hidden file textutil
    /// writes, which is removed however this ends.
    /// - Throws: `FileImportError.noTextToRead` for an empty document,
    ///   `DocumentTooLargeError` for one, or an output, past the limit
    ///   (`DocumentByteLimit`), `Failure`, and `CancellationError`.
    static func html(
        of source: URL,
        as format: TextutilInputFormat,
        workingIn folder: URL,
        using tool: Tool = TextutilConverter.tool
    ) throws -> String {
        // Size the source before anything runs. The limit is read here, on
        // the caller's thread: the detached task below does not inherit a
        // task-local, and the output is held to the same limit.
        let size = try documentSize(of: source)
        guard size > 0 else { throw FileImportError.noTextToRead }
        let limit = DocumentByteLimit.current
        try DocumentByteLimit.check(byteCount: size)

        let name = source.lastPathComponent
        let output = folder.appendingPathComponent(".\(UUID().uuidString)\(temporarySuffix)")
        defer { try? FileManager.default.removeItem(at: output) }

        let command = tool.command(source, format, output)
        let limits = tool.limits(size)
        // An import's Cancel kills the child (`ImportCancellation`). Like the
        // limit, the cancellation is read here, on the caller's thread: the
        // detached task below does not inherit task-locals.
        let cancellation = ImportCancellation.current
        let outcome: WatchedProcess.Outcome
        do {
            outcome = try AsyncBridge.waitForResult(cancelledBy: cancellation) {
                try await WatchedProcess.run(
                    command.executable,
                    arguments: command.arguments,
                    watching: output,
                    limits: limits,
                    residentMemory: tool.residentMemory
                )
            }
        } catch is CancellationError where cancellation?.isCancelled == true {
            // The reader cancelled the import: the child is gone, and the
            // import ends as a cancelled one does.
            throw ImportCancelled()
        }

        switch outcome {
        case .exited(status: 0):
            // textutil exits 0 when it cannot read a file, writing no output
            // file: a missing one means the file could not be read.
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw unreadable(format, name: name, because: "wrote nothing")
            }
        case let .exited(status):
            throw unreadable(format, name: name, because: "exited with status \(status)")
        case .couldNotStart:
            throw unreadable(format, name: name, because: "could not start")
        case let .killed(reason):
            DiagnosticLog.event(.import, "TEXTUTIL_KILLED: \(name): \(reason.words)")
            throw Failure.stopped(reason: reason.words)
        }

        // The HTML is held to the same limit before it is read. Invalid
        // bytes become the replacement character rather than failing the read.
        let written = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(written) <= limit else { throw DocumentTooLargeError(limit: limit) }
        return String(decoding: try Data(contentsOf: output), as: UTF8.self)
    }

    /// The `unreadable` failure for `format`, logged as one import event
    /// naming the file `name` and what happened.
    private static func unreadable(_ format: TextutilInputFormat, name: String, because what: String) -> Failure {
        DiagnosticLog.event(.import, "TEXTUTIL_FAILED: \(name): \(what)")
        return .unreadable(format)
    }
}
