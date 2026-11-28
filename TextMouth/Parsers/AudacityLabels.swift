import Foundation

/// An Audacity label file (FMT06), read and written: UTF-8 text, a label a
/// line, its start, its end, and its text, separated by tabs, the times in
/// seconds (Audacity's manual, "Importing and Exporting Labels"). Equal
/// times make a point, others a region. A line that starts with a backslash
/// holds the spectral selection of the label before it (its low and high
/// frequencies), which TextMouth has no use for, and is passed over.
///
/// Reading is lenient where files differ: a comma as the decimal separator
/// (as Audacity writes in some locales), CR, LF, or CRLF, a byte-order mark,
/// and text with tabs in it. A line that is no label (a time that is no
/// number, a negative one) is passed over; an end before its start is
/// taken as the start, a point. Writing gives what Audacity writes: six
/// decimals with a point, and text on one line.
enum AudacityLabels {
    /// One label.
    struct Label: Equatable, Sendable {
        /// Where it begins, in seconds.
        let start: TimeInterval
        /// Where it ends, in seconds: its start for a point.
        let end: TimeInterval
        /// Its text; empty when it has none.
        let text: String

        /// Whether it marks a point rather than a region.
        var isPoint: Bool { end == start }
    }

    /// The largest label file read: 1 MiB, tens of thousands of labels.
    static let maximumByteCount = 1_048_576

    /// The extension of a label file as Audacity exports one.
    static let fileExtension = "txt"

    // MARK: - Reading

    /// The labels in `text`, in its order.
    static func parse(_ text: String) -> [Label] {
        lines(of: text).compactMap { line in
            guard case .label(let label) = kind(of: line) else { return nil }
            return label
        }
    }

    /// Whether `text` is a label file: it holds at least one label, and
    /// every line that is not blank is a label or a spectral selection. A
    /// text file of anything else (a track's lyrics, a book's notes) is not.
    static func isLabelFile(_ text: String) -> Bool {
        var labels = 0
        for line in lines(of: text) {
            switch kind(of: line) {
            case .label: labels += 1
            case .spectral: continue
            case .other: return false
            }
        }
        return labels > 0
    }

    /// The labels of the file at `url`, when it is a label file
    /// (`isLabelFile(_:)`): at most `maximumByteCount` bytes, decoded as a
    /// text file is (`SmallTextFile`). Nil for a file that is no label file,
    /// is larger, or cannot be read.
    static func labels(inFileAt url: URL) -> [Label]? {
        guard let text = (try? SmallTextFile.text(at: url, byteLimit: maximumByteCount)) ?? nil,
              isLabelFile(text) else { return nil }
        return parse(text)
    }

    /// What one line of a label file is.
    private enum LineKind {
        case label(Label)
        case spectral
        case other
    }

    /// The lines of `text` that are not blank: a leading byte-order mark
    /// dropped, each line ending at CR, LF, or CRLF.
    private static func lines(of text: String) -> [Substring] {
        let withoutMark = text.hasPrefix("\u{FEFF}") ? text.dropFirst() : Substring(text)
        // Swift reads CRLF as one Character, so one test per kind of break
        // is enough.
        return withoutMark.split { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            .filter { !$0.allSatisfy(\.isWhitespace) }
    }

    /// What `line` is: a spectral selection when it starts with a backslash,
    /// a label when its first two tab-separated fields are times, the rest
    /// (tabs and all) its text; anything else otherwise.
    private static func kind(of line: Substring) -> LineKind {
        if line.first == "\\" { return .spectral }
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, let start = seconds(fields[0]), let end = seconds(fields[1]) else { return .other }
        let text = fields.count == 3 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : ""
        return .label(Label(start: start, end: max(start, end), text: text))
    }

    /// The seconds `field` spells: a finite number, 0 or more, with a point
    /// or a comma before its fraction; nil for anything else.
    private static func seconds(_ field: Substring) -> TimeInterval? {
        let trimmed = field.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        // Digits and one point only: `Double(_:)` alone would take a sign,
        // an exponent, "nan", and "inf".
        guard !trimmed.isEmpty, trimmed.filter({ $0 == "." }).count <= 1,
              trimmed.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
              let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    // MARK: - Writing

    /// A label file's text for `labels`, a label a line as Audacity writes
    /// them: the start and end in seconds to six decimals with a point,
    /// whatever the Mac's region, then the text, its tabs and line breaks
    /// made spaces, so each label stays one line of three fields.
    static func text(of labels: [Label]) -> String {
        labels.map { label in
            let text = label.text.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "\t", with: " ")
            return "\(time(label.start))\t\(time(max(label.start, label.end)))\t\(text)\n"
        }.joined()
    }

    /// `seconds` to six decimals with a point; a time that is no finite
    /// number of seconds above zero is the start.
    static func time(_ seconds: TimeInterval) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds.isFinite && seconds > 0 ? seconds : 0)
    }
}
