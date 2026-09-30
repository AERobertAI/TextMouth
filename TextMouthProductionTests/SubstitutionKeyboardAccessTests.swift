import XCTest
@testable import TextMouth

/// Keyboard- and VoiceOver-operable substitution editing and reordering
/// (TODO A03): one-step moves in the rule service.
@MainActor
final class SubstitutionKeyboardAccessTests: XCTestCase {
    // MARK: - One-step moves

    /// One step reaches the neighbouring index. There is no step past either
    /// end of the list, and none from a position outside it.
    func testMoveDirectionFindsTheNeighbouringIndex() {
        let cases: [(index: Int, count: Int, up: Int?, down: Int?)] = [
            (index: 0, count: 3, up: nil, down: 1),
            (index: 1, count: 3, up: 0, down: 2),
            (index: 2, count: 3, up: 1, down: nil),
            (index: 0, count: 1, up: nil, down: nil),
            (index: 0, count: 0, up: nil, down: nil),
            (index: -1, count: 3, up: nil, down: nil),
            (index: 3, count: 3, up: nil, down: nil),
        ]
        for step in cases {
            let context = "from \(step.index) of \(step.count)"
            XCTAssertEqual(SubstitutionRuleMoveDirection.up.destination(from: step.index, count: step.count), step.up, "Up \(context)")
            XCTAssertEqual(SubstitutionRuleMoveDirection.down.destination(from: step.index, count: step.count), step.down, "Down \(context)")
        }
    }

    /// Moving one step swaps a rule with its neighbour, leaves every other
    /// rule where it was, and saves the new order in full.
    func testMoveRuleOneStepSwapsNeighboursAndSavesTheOrder() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 4)
        let service = TextSubstitutionService(rules: rules)

        XCTAssertEqual(service.moveRule(id: rules[2].id, direction: .up), 1)
        XCTAssertEqual(service.rules.map(\.name), ["A", "C", "B", "D"])
        XCTAssertEqual(try sandbox.savedRules(), service.rules)

        XCTAssertEqual(service.moveRule(id: rules[2].id, direction: .down), 2)
        XCTAssertEqual(service.rules, rules)
        XCTAssertEqual(try sandbox.savedRules(), rules)

        XCTAssertEqual(service.moveRule(id: rules[0].id, direction: .down), 1)
        XCTAssertEqual(service.rules.map(\.name), ["B", "A", "C", "D"])
        XCTAssertEqual(try sandbox.savedRules(), service.rules)
    }

    /// Nothing moves, and nothing is saved, for a step past either end of
    /// the list or for a rule the list does not hold.
    func testMoveRuleRefusesStepsPastTheEndsWithoutSaving() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 3)
        let service = TextSubstitutionService(rules: rules)
        try sandbox.removeSavedRules()

        XCTAssertNil(service.moveRule(id: rules[0].id, direction: .up))
        XCTAssertNil(service.moveRule(id: rules[2].id, direction: .down))
        XCTAssertNil(service.moveRule(id: UUID(), direction: .down))

        XCTAssertEqual(service.rules, rules)
        XCTAssertFalse(sandbox.hasSavedRules, "A refused move must not save")
    }

    // MARK: - Helpers

    /// `count` distinct plain rules named "A", "B", "C", and so on.
    private func makeRules(count: Int) -> [SubstitutionRule] {
        ["A", "B", "C", "D", "E", "F"].prefix(count).map { name in
            SubstitutionRule(name: name, pattern: name.lowercased(), replacement: name)
        }
    }
}

/// Keeps the hosted test root's substitutions.json as each test found it.
///
/// An injected `TextSubstitutionService` saves to that same file, so a test
/// that changes rules records the file first and puts it back afterwards.
/// The hosted app's shared rules stay in memory and never reread the file.
private struct SubstitutionFileSandbox {
    /// Raised when the rules file is not inside the isolated test root.
    struct UnisolatedRulesFile: Error {
        let path: String
    }

    /// substitutions.json in the hosted test root.
    let url: URL
    /// The file's bytes when captured, or nil when it did not exist.
    private let originalData: Data?

    /// Records the rules file, refusing to touch one outside the temporary
    /// directory where hosted tests keep their isolated data root.
    static func capture() throws -> SubstitutionFileSandbox {
        let url = TextMouthPaths.substitutionsFile
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            throw UnisolatedRulesFile(path: url.path)
        }
        return SubstitutionFileSandbox(url: url, originalData: try? Data(contentsOf: url))
    }

    /// Whether a rules file exists now.
    var hasSavedRules: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The rules as last saved, in saved order.
    func savedRules() throws -> [SubstitutionRule] {
        try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: url))
    }

    /// Deletes the rules file, so a test can tell whether anything saves.
    func removeSavedRules() throws {
        if hasSavedRules {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Puts back the original bytes, or removes the file if there was none.
    func restore() {
        if let originalData {
            try? originalData.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
