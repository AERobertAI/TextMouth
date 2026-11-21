import Foundation

// MARK: - EPUBCheck

/// Runs `epubcheck` where it is installed, so a test can check an export
/// against EPUB's own validator without depending on it: a test that needs it
/// skips where it is absent (`XCTSkipUnless`), and one that ran it and got no
/// answer fails, since a validator that cannot say is not a pass.
enum EPUBCheck {
    /// Where Homebrew puts it.
    static let path = "/opt/homebrew/bin/epubcheck"
    /// The longest a run may take before it is stopped.
    static let timeoutSeconds: TimeInterval = 180

    /// Whether the validator is installed.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// What a run came to.
    enum Outcome: Equatable {
        /// The validator is not installed.
        case absent
        /// It was installed and gave no answer: it would not start, did not
        /// finish in time, or ended without its summary line. The reason is
        /// a sentence.
        case noAnswer(String)
        /// It said how many messages it found: its summary line, with the first
        /// of its messages when it found any, and whether it found no fatal
        /// error, error, or warning.
        case answered(summary: String, isClean: Bool)

        /// Whether the outcome is one a test accepts for an export: the
        /// validator was absent, or it answered and found nothing.
        var isAcceptable: Bool {
            switch self {
            case .absent: return true
            case .noAnswer: return false
            case .answered(_, let isClean): return isClean
            }
        }

        /// A sentence for a table of results or a failure's message.
        var summary: String {
            switch self {
            case .absent: return "not installed"
            case .noAnswer(let reason): return "no answer: \(reason)"
            case .answered(let summary, _): return summary
            }
        }
    }

    /// Validates the EPUB at `url`, writing the validator's output into
    /// `folder`.
    static func run(on url: URL, in folder: URL) -> Outcome {
        guard isInstalled else { return .absent }
        let output = folder.appendingPathComponent("epubcheck.txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else {
            return .noAnswer("no place to write its output")
        }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [url.path]
        process.standardOutput = handle
        process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .noAnswer("it would not start")
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return .noAnswer("it did not finish in \(Int(timeoutSeconds)) seconds")
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("Messages:") }) else {
            return .noAnswer("its output has no summary line: \(text.prefix(300))")
        }
        let isClean = line.contains("0 fatals / 0 errors / 0 warnings")
        // A failing run shows its messages, not only the count.
        let messages = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("ERROR") || $0.hasPrefix("WARNING") || $0.hasPrefix("FATAL") }
            .prefix(8).joined(separator: " | ")
        return .answered(summary: isClean ? line : "\(line) \(messages)", isClean: isClean)
    }
}
