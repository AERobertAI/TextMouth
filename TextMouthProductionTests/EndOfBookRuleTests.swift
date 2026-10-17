import XCTest
@testable import TextMouth

/// Which setting wins at the end of a book (FR19, task B2): the book's own
/// end behavior, the feed's or folder's options, or the global setting; the
/// direction listening goes on in; and the skip and pre-download choices
/// that ride along. Pure: no reader, no library.
final class EndOfBookRuleTests: XCTestCase {

    /// Every global setting, so a test can prove a layer wins over each.
    private let allGlobals = EndOfBookBehavior.allCases

    // MARK: - The book's own behavior

    /// The book's own behavior wins over the options and the global setting,
    /// and always goes down.
    func testTheBooksOwnBehaviorWinsOverTheOptionsAndTheGlobal() {
        for local in EndOfBookBehavior.allCases {
            for continuation in [nil] + ReadingList.Continuation.allCases.map(Optional.some) {
                for global in allGlobals {
                    let rule = EndOfBookRule.resolve(
                        localRawValue: local.rawValue,
                        options: ListeningOptions(continuation: continuation),
                        global: global
                    )
                    XCTAssertEqual(rule.behavior, local, "local \(local), options \(String(describing: continuation)), global \(global)")
                    XCTAssertEqual(rule.direction, .down)
                }
            }
        }
    }

    /// A saved name that matches no behavior is ignored, as the reader's
    /// `effectiveEndOfBookBehavior` always ignored it.
    func testAnUnknownLocalNameIsIgnored() {
        let withOptions = EndOfBookRule.resolve(
            localRawValue: "Fly to the Moon",
            options: ListeningOptions(continuation: .playBookAbove),
            global: .loop
        )
        XCTAssertEqual(withOptions.behavior, .continueNext)
        XCTAssertEqual(withOptions.direction, .up)

        let withoutOptions = EndOfBookRule.resolve(localRawValue: "", options: nil, global: .loop)
        XCTAssertEqual(withoutOptions.behavior, .loop)
        XCTAssertEqual(withoutOptions.direction, .down)
    }

    // MARK: - The options

    /// Each of the options' three continuations wins over each of the four
    /// global settings.
    func testTheOptionsContinuationWinsOverEveryGlobal() {
        let expected: [ReadingList.Continuation: (EndOfBookBehavior, ReadingList.Direction)] = [
            .playBookBelow: (.continueNext, .down),
            .playBookAbove: (.continueNext, .up),
            .stop: (.stop, .down),
        ]
        for (continuation, outcome) in expected {
            for global in allGlobals {
                let rule = EndOfBookRule.resolve(
                    localRawValue: nil,
                    options: ListeningOptions(continuation: continuation),
                    global: global
                )
                XCTAssertEqual(rule.behavior, outcome.0, "\(continuation) over \(global)")
                XCTAssertEqual(rule.direction, outcome.1, "\(continuation) over \(global)")
            }
        }
    }

    /// Options with no continuation, "Use the global setting", leave the
    /// global setting in force, going down.
    func testOptionsWithNoContinuationFollowTheGlobal() {
        for global in allGlobals {
            let rule = EndOfBookRule.resolve(
                localRawValue: nil,
                options: ListeningOptions(continuation: nil, skipsFinished: false),
                global: global
            )
            XCTAssertEqual(rule.behavior, global)
            XCTAssertEqual(rule.direction, .down)
        }
    }

    /// With no options at all, the global setting is in force, going down.
    func testNoOptionsFollowTheGlobal() {
        for global in allGlobals {
            let rule = EndOfBookRule.resolve(localRawValue: nil, options: nil, global: global)
            XCTAssertEqual(
                rule,
                EndOfBookRule(behavior: global, direction: .down, skipsFinished: true, predownloadsNext: true)
            )
        }
    }

    // MARK: - Skip finished and pre-download

    /// Skip finished and pre-download are the options' own under each
    /// winner: the book's, the options', and the global setting.
    func testSkipAndPredownloadComeFromTheOptionsWhicheverLayerWins() {
        let options = ListeningOptions(continuation: nil, skipsFinished: false, predownloadsNext: false)

        let underLocal = EndOfBookRule.resolve(localRawValue: EndOfBookBehavior.loop.rawValue, options: options, global: .stop)
        XCTAssertEqual(underLocal.behavior, .loop)
        XCTAssertFalse(underLocal.skipsFinished)
        XCTAssertFalse(underLocal.predownloadsNext)

        var withContinuation = options
        withContinuation.continuation = .playBookAbove
        let underOptions = EndOfBookRule.resolve(localRawValue: nil, options: withContinuation, global: .stop)
        XCTAssertEqual(underOptions.behavior, .continueNext)
        XCTAssertFalse(underOptions.skipsFinished)
        XCTAssertFalse(underOptions.predownloadsNext)

        let underGlobal = EndOfBookRule.resolve(localRawValue: nil, options: options, global: .continueNext)
        XCTAssertEqual(underGlobal.behavior, .continueNext)
        XCTAssertFalse(underGlobal.skipsFinished)
        XCTAssertFalse(underGlobal.predownloadsNext)
    }

    /// Each choice is read on its own: one off leaves the other on.
    func testSkipAndPredownloadAreIndependent() {
        let skipOff = EndOfBookRule.resolve(localRawValue: nil, options: ListeningOptions(skipsFinished: false), global: .stop)
        XCTAssertFalse(skipOff.skipsFinished)
        XCTAssertTrue(skipOff.predownloadsNext)

        let downloadOff = EndOfBookRule.resolve(localRawValue: nil, options: ListeningOptions(predownloadsNext: false), global: .stop)
        XCTAssertTrue(downloadOff.skipsFinished)
        XCTAssertFalse(downloadOff.predownloadsNext)
    }

    /// Both are on when there are no options.
    func testSkipAndPredownloadAreOnWithNoOptions() {
        let rule = EndOfBookRule.resolve(localRawValue: nil, options: nil, global: .stop)
        XCTAssertTrue(rule.skipsFinished)
        XCTAssertTrue(rule.predownloadsNext)
    }

    // MARK: - Standard options

    /// The standard options change nothing: the rule is the one with no
    /// options, under every local name and every global setting.
    func testStandardOptionsChangeNothing() {
        let locals: [String?] = [nil, "Fly to the Moon"] + EndOfBookBehavior.allCases.map { $0.rawValue }
        for local in locals {
            for global in allGlobals {
                XCTAssertEqual(
                    EndOfBookRule.resolve(localRawValue: local, options: .standard, global: global),
                    EndOfBookRule.resolve(localRawValue: local, options: nil, global: global),
                    "local \(String(describing: local)), global \(global)"
                )
            }
        }
    }
}
