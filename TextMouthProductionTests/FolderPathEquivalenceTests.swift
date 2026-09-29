import XCTest
@testable import TextMouth

/// Covers the single folder-path equivalence rule and how TextMouth learns
/// which policy the library volume needs.
final class FolderPathEquivalenceTests: XCTestCase {
    /// "Café" with é as one precomposed scalar (U+00E9).
    private let composed = "Caf\u{E9}"
    /// "Café" with e followed by a combining acute accent (U+0301).
    private let decomposed = "Cafe\u{301}"

    /// Composed and decomposed spellings name one directory on every Apple
    /// volume, so both policies treat them alike and key them in NFC.
    func testUnicodeNormalizationAppliesUnderBothPolicies() {
        for rule in [FolderPathEquivalence.caseSensitive, .caseInsensitive] {
            XCTAssertTrue(rule.areEquivalent(composed, decomposed))
            XCTAssertTrue(rule.areEquivalent("Work/\(composed)", "Work/\(decomposed)"))
            let key = rule.comparisonKey(for: decomposed)
            XCTAssertFalse(key.unicodeScalars.contains("\u{301}"), "Keys must be NFC")
        }
    }

    /// Case folding applies only when the volume ignores case, and it keeps
    /// working when the two spellings also differ in normalization.
    func testCaseFoldingFollowsTheVolumePolicy() {
        let insensitive = FolderPathEquivalence.caseInsensitive
        XCTAssertTrue(insensitive.areEquivalent("Reports", "reports"))
        XCTAssertTrue(insensitive.areEquivalent("Work/REPORTS", "work/Reports"))
        XCTAssertTrue(insensitive.areEquivalent("\u{C9}cole", "e\u{301}COLE"))
        XCTAssertFalse(insensitive.areEquivalent("Reports", "Reports2"))

        let sensitive = FolderPathEquivalence.caseSensitive
        XCTAssertFalse(sensitive.areEquivalent("Reports", "reports"))
        XCTAssertEqual(sensitive.comparisonKey(for: "Reports"), "Reports")
    }

    /// Subtree matching compares whole components, maps folded spellings of a
    /// different length onto the right tail, and treats the root as containing
    /// every path.
    func testSubtreeMatchingUsesWholeComponents() {
        let insensitive = FolderSubtree(rootPath: "Work/Reports", equivalence: .caseInsensitive)
        XCTAssertEqual(insensitive.relativeComponents(of: "work/reports"), [])
        XCTAssertEqual(insensitive.relativeComponents(of: "WORK/Reports/Q1/Late"), ["Q1", "Late"])
        XCTAssertNil(insensitive.relativeComponents(of: "Work/Reports2"))
        XCTAssertNil(insensitive.relativeComponents(of: "Work"))
        XCTAssertEqual(insensitive.relocating("work/REPORTS/Q1", to: "Archive"), "Archive/Q1")
        XCTAssertEqual(insensitive.relocating("Work/Reports", to: ""), "")
        XCTAssertNil(insensitive.relocating("Other/Q1", to: "Archive"))

        let sensitive = FolderSubtree(rootPath: "Work/Reports", equivalence: .caseSensitive)
        XCTAssertNil(sensitive.relativeComponents(of: "work/reports/Q1"))
        XCTAssertEqual(sensitive.relativeComponents(of: "Work/Reports/Q1"), ["Q1"])

        // Full case folding turns ß into "ss", so the spellings differ in length.
        let folded = FolderSubtree(rootPath: "STRASSE", equivalence: .caseInsensitive)
        XCTAssertEqual(folded.relocating("Stra\u{DF}e/Maps", to: "Streets"), "Streets/Maps")

        XCTAssertTrue(FolderPathEquivalence.caseSensitive.isPath("Any/Path", inSubtreeOf: ""))
        XCTAssertFalse(FolderPathEquivalence.caseSensitive.isPath("", inSubtreeOf: "Any"))
    }

    /// When the volume cannot report its behavior, assume case-insensitive:
    /// that can only refuse a name, never let two rows share one directory.
    func testUnknownVolumeCapabilityDefaultsToCaseInsensitive() {
        XCTAssertEqual(FolderPathEquivalence(volumeSupportsCaseSensitiveNames: nil), .caseInsensitive)
        XCTAssertEqual(FolderPathEquivalence(volumeSupportsCaseSensitiveNames: false), .caseInsensitive)
        XCTAssertEqual(FolderPathEquivalence(volumeSupportsCaseSensitiveNames: true), .caseSensitive)
    }

    /// Detection reads the real volume, walking up from a directory that does
    /// not exist yet, as a brand-new library directory would not.
    func testDetectionReadsTheVolumeOfTheNearestExistingAncestor() throws {
        let temporary = FileManager.default.temporaryDirectory
        let expected = try XCTUnwrap(
            temporary.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames
        )
        let missing = temporary.appendingPathComponent(
            "Missing-\(UUID().uuidString)/Library",
            isDirectory: true
        )

        XCTAssertEqual(FolderPathEquivalence.detectCaseSensitivity(ofVolumeContaining: temporary), expected)
        XCTAssertEqual(FolderPathEquivalence.detectCaseSensitivity(ofVolumeContaining: missing), expected)
        XCTAssertEqual(
            FolderPathEquivalence.forVolume(containing: missing),
            FolderPathEquivalence(volumeSupportsCaseSensitiveNames: expected)
        )
    }

    /// The library rule follows the test root's volume, and a scoped override
    /// replaces it (restoring nested scopes) so tests can drive both policies.
    func testLibraryRuleFollowsTheLibraryVolumeAndCanBeOverridden() {
        let detected = FolderPathEquivalence.forVolume(containing: TextMouthPaths.libraryDir)
        XCTAssertEqual(FolderPathEquivalence.library, detected)

        FolderPathEquivalence.withLibraryRule(.caseSensitive) {
            XCTAssertEqual(FolderPathEquivalence.library, .caseSensitive)
            FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
                XCTAssertEqual(FolderPathEquivalence.library, .caseInsensitive)
            }
            XCTAssertEqual(FolderPathEquivalence.library, .caseSensitive)
        }
        XCTAssertEqual(FolderPathEquivalence.library, detected)
    }
}
