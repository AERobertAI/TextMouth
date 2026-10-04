import XCTest
@testable import TextMouth

/// The experimental transcript cleanup's rules (FR05,
/// `TranscriptCleanupRuleFile`): TextMouth's own, in the app's bundle,
/// unless the user keeps a usable copy in the data directory, read as
/// substitutions.json is: a damaged copy is kept beside itself and a copy
/// only in the cloud is never read, TextMouth's own rules standing in for
/// either; and Edit Rules… making the copy from TextMouth's own file, once.
@MainActor
final class TranscriptCleanupRuleFileTests: XCTestCase {

    // MARK: - TextMouth's Own Rules

    /// TextMouth's own rule file is in the app's bundle, usable, and
    /// conservative: whole words, each right in two places or more of the
    /// measurements, and no rule touching a number or a name.
    func testTextMouthsOwnRulesAreUsableAndConservative() throws {
        let bytes = try XCTUnwrap(TranscriptCleanupRuleFile.builtInBytes(), "the app's bundle has no transcript-cleanup.json")
        let rules = try TranscriptCleanupRuleSet.decoded(bytes)

        XCTAssertEqual(TranscriptCleanupRuleFile.builtIn(), rules)
        XCTAssertGreaterThanOrEqual(rules.version, 1)
        XCTAssertNotNil(rules.about)
        for rule in rules.rules {
            XCTAssertTrue(rule.wholeWord, rule.pattern)
            XCTAssertGreaterThanOrEqual(rule.evidence, 2, rule.pattern)
            XCTAssertFalse((rule.pattern + rule.replacement).contains(where: \.isNumber), rule.pattern)
            XCTAssertFalse((rule.pattern + rule.replacement).contains(where: \.isUppercase), rule.pattern)
            XCTAssertNotNil(rule.note, rule.pattern)
        }
    }

    // MARK: - The Rules to Use

    /// Without a copy of their own, TextMouth's own rules are used.
    func testWithoutACopyTextMouthsOwnRulesAreUsed() throws {
        let url = try makeSandboxDirectory("Cleanup Rules Missing").appendingPathComponent(TranscriptCleanupRuleFile.fileName)

        let lookup = TranscriptCleanupRuleFile.load(userCopyAt: url, builtIn: rules)

        XCTAssertEqual(lookup, TranscriptCleanupRuleFile.Lookup(rules: rules, source: .builtIn, userCopy: .none, builtInVersion: 4))
    }

    /// A usable copy of the user's own is used instead.
    func testTheUsersCopyIsUsedWhenUsable() throws {
        let url = try makeSandboxDirectory("Cleanup Rules Copy").appendingPathComponent(TranscriptCleanupRuleFile.fileName)
        let own = TranscriptCleanupRuleSet(version: 2, date: "2026-10-05", rules: [rule("tolled", "told")])
        try JSONEncoder().encode(own).write(to: url)

        let lookup = TranscriptCleanupRuleFile.load(userCopyAt: url, builtIn: rules)

        XCTAssertEqual(lookup, TranscriptCleanupRuleFile.Lookup(rules: own, source: .user, userCopy: .used, builtInVersion: 4))
    }

    /// A damaged copy is kept beside itself, once however often it is read,
    /// stays for the user to mend, and TextMouth's own rules stand in.
    func testADamagedCopyIsPreservedAndTextMouthsRulesStandIn() throws {
        let folder = try makeSandboxDirectory("Cleanup Rules Damaged")
        let url = folder.appendingPathComponent(TranscriptCleanupRuleFile.fileName)
        let damaged = Data("{\"version\": 2, \"date\": \"2026-10-05\", \"rules\": [{\"pattern\": \"\", \"replacement\": \"x\"}]}".utf8)
        try damaged.write(to: url)

        let lookup = TranscriptCleanupRuleFile.load(userCopyAt: url, builtIn: rules)
        _ = TranscriptCleanupRuleFile.load(userCopyAt: url, builtIn: rules)

        XCTAssertEqual(lookup.userCopy, .unusable("rules[0].pattern is empty"))
        XCTAssertEqual(lookup.source, .builtIn)
        XCTAssertEqual(lookup.rules, rules)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(TranscriptCleanupRuleFile.fileName + LibraryIndexQuarantine.nameMarker) }
        XCTAssertEqual(copies.count, 1, "\(copies)")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(copies[0])), damaged)
        XCTAssertEqual(try Data(contentsOf: url), damaged, "the user's copy was replaced")
    }

    /// A copy only in the cloud is never read: TextMouth's own rules stand
    /// in, and nothing is written over it.
    func testACopyOnlyInTheCloudIsNotReadOrWrittenOver() throws {
        let url = try makeSandboxDirectory("Cleanup Rules In Cloud").appendingPathComponent(TranscriptCleanupRuleFile.fileName)
        let refusing: SavedFile.Reader = { _ in throw LocalBookFiles.downloadRefusal }

        let lookup = TranscriptCleanupRuleFile.load(userCopyAt: url, reader: refusing, builtIn: rules)

        XCTAssertEqual(lookup.userCopy, .inCloud)
        XCTAssertEqual(lookup.source, .builtIn)
        XCTAssertThrowsError(try TranscriptCleanupRuleFile.prepareUserCopy(at: url, reader: refusing, builtInBytes: Data("{}".utf8))) {
            XCTAssertTrue($0 is SavedFile.InCloudError, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Edit Rules… makes the user's copy from TextMouth's own file, exactly,
    /// the first time, and leaves a copy already there as it is.
    func testEditRulesMakesTheCopyOnce() throws {
        let url = try makeSandboxDirectory("Cleanup Rules Edited").appendingPathComponent(TranscriptCleanupRuleFile.fileName)
        let builtIn = try XCTUnwrap(TranscriptCleanupRuleFile.builtInBytes())

        XCTAssertTrue(try TranscriptCleanupRuleFile.prepareUserCopy(at: url, builtInBytes: builtIn))
        XCTAssertEqual(try Data(contentsOf: url), builtIn)
        let edited = Data("{\"version\": 9}".utf8)
        try edited.write(to: url)
        XCTAssertFalse(try TranscriptCleanupRuleFile.prepareUserCopy(at: url, builtInBytes: builtIn))
        XCTAssertEqual(try Data(contentsOf: url), edited)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
            [TranscriptCleanupRuleFile.fileName],
            "a staged copy was left behind"
        )
    }

    /// The user's copy sits in the data directory, beside substitutions.json.
    func testTheUsersCopySitsBesideTheSubstitutions() {
        XCTAssertEqual(TextMouthPaths.transcriptCleanupRulesFile, TextMouthPaths.root.appendingPathComponent("transcript-cleanup.json"))
        XCTAssertEqual(
            TextMouthPaths.transcriptCleanupRulesFile.deletingLastPathComponent(),
            TextMouthPaths.substitutionsFile.deletingLastPathComponent()
        )
    }

    // MARK: - Fixtures

    /// TextMouth's own rules, as the tests stand them in: two rules, version 4.
    private let rules = TranscriptCleanupFixtures.narrationRules

    /// A whole-word rule writing its replacement for its pattern.
    private let rule = TranscriptCleanupFixtures.rule
}
