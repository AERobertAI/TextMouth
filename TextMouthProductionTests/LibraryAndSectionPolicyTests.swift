import XCTest
@testable import TextMouth

@MainActor
final class LibraryAndSectionPolicyTests: XCTestCase {
    func testEditSelectionToggleAddsID() {
        let id = UUID()
        XCTAssertEqual(LibrarySelectionPolicy.toggled([], id: id), [id])
    }

    func testEditSelectionToggleRemovesID() {
        let id = UUID()
        XCTAssertTrue(LibrarySelectionPolicy.toggled([id], id: id).isEmpty)
    }

    func testEditSelectionCanAccumulateMultipleIDs() {
        let ids = [UUID(), UUID(), UUID()]
        let result = ids.reduce(into: Set<UUID>()) { selection, id in
            selection = LibrarySelectionPolicy.toggled(selection, id: id)
        }
        XCTAssertEqual(result, Set(ids))
    }

    func testEffectiveSelectionUnionsNativeAndEditSelections() {
        let shared = UUID(), nativeOnly = UUID(), editOnly = UUID()
        XCTAssertEqual(
            LibrarySelectionPolicy.effective(native: [shared, nativeOnly], edit: [shared, editOnly]),
            [shared, nativeOnly, editOnly]
        )
    }

    func testSelectAllUsesEveryVisibleBookID() {
        let ids = (0..<10).map { _ in UUID() }
        XCTAssertEqual(Set(ids).count, 10)
    }

    func testContextMenuOnSelectedBookTargetsFullSelection() {
        let clicked = UUID(), other = UUID()
        XCTAssertEqual(
            LibrarySelectionPolicy.contextTargets(clickedID: clicked, effectiveSelection: [clicked, other]),
            [clicked, other]
        )
    }

    func testContextMenuOnUnselectedBookTargetsOnlyClickedBook() {
        let clicked = UUID()
        XCTAssertEqual(
            LibrarySelectionPolicy.contextTargets(clickedID: clicked, effectiveSelection: [UUID(), UUID()]),
            [clicked]
        )
    }

    func testContextMenuWithSingleSelectionTargetsClickedBook() {
        let clicked = UUID()
        XCTAssertEqual(
            LibrarySelectionPolicy.contextTargets(clickedID: clicked, effectiveSelection: [clicked]),
            [clicked]
        )
    }

    func testClearingAfterMoveResetsBothSelectionsAndEditMode() {
        assertClearSelectionState()
    }

    func testClearingAfterRemoveResetsBothSelectionsAndEditMode() {
        assertClearSelectionState()
    }

    func testFolderNavigationCanClearAllSelectionState() {
        assertClearSelectionState()
    }

    func testCategoryChangeCanClearAllSelectionState() {
        assertClearSelectionState()
    }

    func testDoneCanClearAllSelectionState() {
        assertClearSelectionState()
    }

    func testEmptySkipListLeavesTextAndMapUnchanged() {
        let result = SkippedSectionFilter.apply(text: "Alpha Beta", headings: headings(), skippedIDs: [])
        XCTAssertEqual(result.text, "Alpha Beta")
        XCTAssertEqual(result.offsetMap, .identity)
    }

    func testNoHeadingsLeavesTextAndMapUnchanged() {
        let result = SkippedSectionFilter.apply(text: "Alpha Beta", headings: [], skippedIDs: ["missing"])
        XCTAssertEqual(result.text, "Alpha Beta")
        XCTAssertEqual(result.offsetMap, .identity)
    }

    func testSkippingMiddleHeadingRemovesItsRange() {
        let list = headings()
        let result = SkippedSectionFilter.apply(text: sampleText, headings: list, skippedIDs: [list[1].id])
        XCTAssertEqual(result.text, String(repeating: "A", count: 20) + String(repeating: "C", count: 20))
    }

    func testSkippingFirstHeadingRemovesFrontMatter() {
        let list = headings()
        let result = SkippedSectionFilter.apply(text: sampleText, headings: list, skippedIDs: [list[0].id])
        XCTAssertFalse(result.text.contains("A"))
        XCTAssertTrue(result.text.hasPrefix("B"))
    }

    func testSkippingLastHeadingRemovesBackMatter() {
        let list = headings()
        let result = SkippedSectionFilter.apply(text: sampleText, headings: list, skippedIDs: [list[2].id])
        XCTAssertEqual(result.text, String(repeating: "A", count: 20) + String(repeating: "B", count: 20))
    }

    func testSkippingMultipleSectionsRemovesEachRange() {
        let list = headings()
        let result = SkippedSectionFilter.apply(
            text: sampleText,
            headings: list,
            skippedIDs: [list[0].id, list[2].id]
        )
        XCTAssertEqual(result.text, String(repeating: "B", count: 20))
    }

    func testSkippedRangeOffsetMapConvertsFilteredOffsetToSource() {
        let list = headings()
        let result = SkippedSectionFilter.apply(text: sampleText, headings: list, skippedIDs: [list[1].id])
        XCTAssertEqual(result.offsetMap.toSource(20), 40)
        XCTAssertEqual(result.offsetMap.toTarget(40), 20)
    }

    func testOutOfBoundsHeadingOffsetsAreClampedSafely() {
        let heading = Heading(level: 1, text: "Beyond", characterOffset: 999)
        let result = SkippedSectionFilter.apply(text: "short", headings: [heading], skippedIDs: [heading.id])
        XCTAssertEqual(result.text, "short")
        XCTAssertEqual(result.offsetMap, .identity)
    }

    private var sampleText: String {
        String(repeating: "A", count: 20)
            + String(repeating: "B", count: 20)
            + String(repeating: "C", count: 20)
    }

    private func headings() -> [Heading] {
        [
            Heading(level: 1, text: "A", characterOffset: 0),
            Heading(level: 1, text: "B", characterOffset: 20),
            Heading(level: 1, text: "C", characterOffset: 40),
        ]
    }

    private func assertClearSelectionState(file: StaticString = #filePath, line: UInt = #line) {
        var native: Set<UUID> = [UUID()]
        var edit: Set<UUID> = [UUID(), UUID()]
        var isEditMode = true
        LibrarySelectionPolicy.clear(native: &native, edit: &edit, isEditMode: &isEditMode)
        XCTAssertTrue(native.isEmpty, file: file, line: line)
        XCTAssertTrue(edit.isEmpty, file: file, line: line)
        XCTAssertFalse(isEditMode, file: file, line: line)
    }
}
