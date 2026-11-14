import Foundation
import XCTest

/// Why each unchecked concurrency escape in the app is safe (TODO Q02). The
/// compiler checks neither an `@unchecked Sendable` type nor a
/// `nonisolated(unsafe)` variable, so the comment beside each, naming the
/// lock, queue, actor, or thread that confines it, is all that tells the
/// next reader why it is safe and what must stay true. These tests read the
/// app's sources, as LogContentPolicyTests does for log lines, so a new
/// escape without that comment fails here rather than slipping past review.
final class UncheckedConcurrencyPolicyTests: XCTestCase {

    /// How many unchecked declarations of each kind the app holds. The pin
    /// changes with the code, in the same commit: up for a new declaration,
    /// once it names what confines it, and down for one made checked.
    private static let pinnedCounts: [UncheckedConcurrencyScanner.Kind: Int] = [
        .uncheckedSendable: 30,
        .nonisolatedUnsafe: 16,
    ]

    // MARK: - The Source

    /// Every `@unchecked Sendable` type and `nonisolated(unsafe)` variable in
    /// the app names what confines it in a comment on the three lines above
    /// it.
    func testEveryUncheckedDeclarationNamesWhatConfinesIt() throws {
        let declarations = try Self.appDeclarations()

        // A scanner that found nothing would pass without checking anything.
        XCTAssertFalse(declarations.isEmpty, "no unchecked declarations found")
        for declaration in declarations where !declaration.namesItsConfinement {
            XCTFail(
                "\(declaration) says nothing of what confines it. The compiler checks no \(declaration.kind.rawValue), "
                    + "so say why it is safe in a comment on the three lines above it, naming the lock, queue, actor, "
                    + "or thread that confines it, as in: /// `@unchecked Sendable`: every variable is read and "
                    + "changed only under `lock`."
            )
        }
    }

    /// The number of each kind is pinned, so a declaration removed is
    /// noticed as well as one added.
    func testTheNumberOfEachKindIsPinned() throws {
        let declarations = try Self.appDeclarations()

        for kind in UncheckedConcurrencyScanner.Kind.allCases {
            let found = declarations.filter { $0.kind == kind }
            let pinned = Self.pinnedCounts[kind] ?? 0
            XCTAssertEqual(
                found.count,
                pinned,
                "The app holds \(found.count) \(kind.rawValue) declarations, not \(pinned). Change the pin in "
                    + "UncheckedConcurrencyPolicyTests together with the code. Found: "
                    + found.map(\.description).joined(separator: ", ")
            )
        }
    }

    // MARK: - The Scanner

    /// The scanner finds each kind of declaration in code, not in comments
    /// or string literals, and reads only the comments on the three lines
    /// above it, a comment ending a line of code included. A comment further
    /// up, or on the declaration's own line, is out of reach.
    func testTheScannerFindsDeclarationsAndReadsTheCommentsAboveThem() {
        let sample = """
        /// Every variable is read and changed only under `lock`.
        final class Locked: @unchecked Sendable {}

        /// Holds one value, which never changes.
        final class Unexplained: @unchecked Sendable {}

        // Confined to saveQueue.
        nonisolated(unsafe) private static var pending = 0
        nonisolated(unsafe) private static var generation = 0

        /// Read on the main thread only.
        ///
        ///
        ///
        struct TooFarAbove: @unchecked Sendable {}

        /// Copied in blocks, by a factor of two.
        final class FalseFriends: @unchecked Sendable {}

        /// Its handler runs on the MainActor.
        @MainActor
        final class Observer: NSObject, @unchecked Sendable {}

        private static let lock = NSLock() // The lock that guards closed.
        nonisolated(unsafe) private static var closed: Set<String> = []

        /// A comment may mention @unchecked Sendable or nonisolated(unsafe).
        let quoted = "nonisolated(unsafe) and @unchecked Sendable, in a string // with slashes"

        nonisolated(unsafe) private var sameLine = 0 // Guarded by lock, but on its own line.
        """

        let found = UncheckedConcurrencyScanner.declarations(in: sample, file: "Sample.swift")

        XCTAssertEqual(found.map(\.description), [
            "Sample.swift:2: @unchecked Sendable",
            "Sample.swift:5: @unchecked Sendable",
            "Sample.swift:8: nonisolated(unsafe)",
            "Sample.swift:9: nonisolated(unsafe)",
            "Sample.swift:15: @unchecked Sendable",
            "Sample.swift:18: @unchecked Sendable",
            "Sample.swift:22: @unchecked Sendable",
            "Sample.swift:25: nonisolated(unsafe)",
            "Sample.swift:30: nonisolated(unsafe)",
        ])
        XCTAssertEqual(found.filter { !$0.namesItsConfinement }.map(\.line), [5, 15, 18, 30])
    }

    /// A comment names what confines a declaration when one of its words
    /// begins with "lock", "queue", "actor", "thread", or "mutex", with
    /// identifiers split where their case changes; a word that only holds
    /// one, such as "blocks", names nothing.
    func testAWordNamesAConfinementByHowItBegins() {
        let naming = [
            "only under `lock`", "under stateLock", "an NSLock", "an OSAllocatedUnfairLock", "the lock-guarded count",
            "so the flag is locked", "Confined to bookInfoSaveQueue.", "on the main queue", "on the main actor",
            "@MainActor", "on the thread listing", "documented thread-safe", "a Mutex",
        ]
        let notNaming = ["in blocks", "by a factor of two", "while unlocked", "every property is a constant", ""]

        for comment in naming {
            XCTAssertTrue(UncheckedConcurrencyScanner.namesConfinement(comment), comment)
        }
        for comment in notNaming {
            XCTAssertFalse(UncheckedConcurrencyScanner.namesConfinement(comment), comment)
        }
    }

    // MARK: - Helpers

    /// Every unchecked declaration in the app's sources, each file named by
    /// its path in the app's source folder.
    private static func appDeclarations() throws -> [UncheckedConcurrencyScanner.Declaration] {
        try AppSourceFile.all().flatMap { UncheckedConcurrencyScanner.declarations(in: $0.text, file: $0.path) }
    }
}

// MARK: - The Unchecked Declaration Scanner

/// Finds the app's unchecked concurrency escapes in Swift source, with the
/// comments on the lines above each. A line scanner, not a parser: a
/// comment begins at the first `//` outside a string literal, whether it
/// fills its line or ends a line of code, and a string literal's contents
/// never count as code, so a declaration's words quoted in a string are not
/// taken for one. String literals spanning lines, and block comments, are
/// not recognized; the app's declarations use neither.
private enum UncheckedConcurrencyScanner {

    /// A kind of declaration the compiler does not check.
    enum Kind: String, CaseIterable {
        /// A type the compiler takes as `Sendable` on the code's word.
        case uncheckedSendable = "@unchecked Sendable"
        /// A variable the compiler lets any thread reach on the code's word.
        case nonisolatedUnsafe = "nonisolated(unsafe)"

        /// How code spells the kind, with any spacing between `@unchecked`
        /// and `Sendable`.
        var pattern: String {
            switch self {
            case .uncheckedSendable: return #"@unchecked\s+Sendable\b"#
            case .nonisolatedUnsafe: return #"\bnonisolated\(unsafe\)"#
            }
        }
    }

    /// One unchecked declaration, and the comments on the lines above it.
    struct Declaration: CustomStringConvertible {
        /// What kind it is.
        let kind: Kind
        /// The file it is in, by its path in the app's source folder.
        let file: String
        /// The line it is on, counted from 1.
        let line: Int
        /// The comments on the `reach` lines above it, in order.
        let commentsAbove: String

        /// Whether those comments name a lock, queue, actor, or thread.
        var namesItsConfinement: Bool {
            UncheckedConcurrencyScanner.namesConfinement(commentsAbove)
        }

        var description: String { "\(file):\(line): \(kind.rawValue)" }
    }

    /// How many lines above a declaration the comment naming what confines
    /// it may be.
    static let reach = 3

    /// What a word begins with when it names what confines a declaration.
    static let confinementWords = ["lock", "queue", "actor", "thread", "mutex"]

    /// A string literal on one line: its quotes and what is between them,
    /// escaped quotes included.
    static let stringLiteralPattern = #""(?:[^"\\]|\\.)*""#

    // MARK: Finding Declarations

    /// The unchecked declarations in `source`, the text of the file named
    /// `file`, in the order of their lines.
    static func declarations(in source: String, file: String) -> [Declaration] {
        let lines = source.components(separatedBy: "\n")
        var found: [Declaration] = []
        // Only a line holding one of the two spellings can declare anything,
        // so the rest are passed over unread.
        for (index, line) in lines.enumerated() where line.contains("@unchecked") || line.contains("nonisolated(") {
            let code = code(of: line)
            for kind in Kind.allCases where code.range(of: kind.pattern, options: .regularExpression) != nil {
                let above = lines[max(0, index - reach)..<index].compactMap { comment(of: $0) }
                found.append(Declaration(kind: kind, file: file, line: index + 1, commentsAbove: above.joined(separator: "\n")))
            }
        }
        return found
    }

    /// The code on `line`: what comes before its comment, if it has one,
    /// with the contents of its string literals left out.
    static func code(of line: String) -> String {
        let beforeComment = commentStart(in: line).map { String(line[..<$0]) } ?? line
        return beforeComment.replacingOccurrences(of: stringLiteralPattern, with: "\"\"", options: .regularExpression)
    }

    /// The comment on `line`, from its `//` to the line's end, or nil when
    /// it has none.
    static func comment(of line: String) -> String? {
        commentStart(in: line).map { String(line[$0...]) }
    }

    /// Where the comment on `line` begins: its first `//` outside a string
    /// literal, or nil when it has none.
    static func commentStart(in line: String) -> String.Index? {
        var isInString = false
        var isEscaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isInString {
                // A backslash escapes the next character, a quote included.
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if line[index...].hasPrefix("//") {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    // MARK: Reading Comments

    /// Whether `comment` names a lock, queue, actor, or thread: whether any
    /// of its words begins with one of `confinementWords`.
    static func namesConfinement(_ comment: String) -> Bool {
        words(in: comment).contains { word in
            confinementWords.contains { word.hasPrefix($0) }
        }
    }

    /// The words of `text`, lowercased, each identifier split where its
    /// case changes: "NSLock" gives "ns" and "lock", and "saveQueue" gives
    /// "save" and "queue".
    static func words(in text: String) -> [String] {
        // The pattern is a constant, so a failure is a mistake in this file.
        let word = try! NSRegularExpression(pattern: "[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")
        let characters = text as NSString
        return word.matches(in: text, range: NSRange(location: 0, length: characters.length)).map { match in
            characters.substring(with: match.range).lowercased()
        }
    }
}
