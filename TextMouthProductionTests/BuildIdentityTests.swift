import XCTest
@testable import TextMouth

final class BuildIdentityTests: XCTestCase {
    func testIdentityReadsEveryEmbeddedBuildField() {
        let identity = BuildIdentity(
            info: [
                "CFBundleShortVersionString": "0.1.2",
                "CFBundleVersion": "20260730130000",
                "TextMouthGitCommit": "abc1234",
                "TextMouthBuildDate": "2026-07-30T17:00:00Z",
                "TextMouthBuildConfiguration": "Release",
            ],
            executablePath: "/workspace/build/TextMouth.app/Contents/MacOS/TextMouth"
        )

        XCTAssertEqual(identity.version, "0.1.2")
        XCTAssertEqual(identity.buildNumber, "20260730130000")
        XCTAssertEqual(identity.gitCommit, "abc1234")
        XCTAssertEqual(identity.buildDate, "2026-07-30T17:00:00Z")
        XCTAssertEqual(identity.configuration, "Release")
        XCTAssertEqual(
            identity.executablePath,
            "/workspace/build/TextMouth.app/Contents/MacOS/TextMouth"
        )
    }

    func testIdentityRejectsUnexpandedBuildSettings() {
        let identity = BuildIdentity(
            info: [
                "TextMouthGitCommit": "$(TEXTMOUTH_GIT_COMMIT)",
                "TextMouthBuildDate": "$(TEXTMOUTH_BUILD_DATE)",
            ],
            executablePath: nil
        )

        XCTAssertEqual(identity.gitCommit, "unknown")
        XCTAssertEqual(identity.buildDate, "unknown")
        XCTAssertEqual(identity.executablePath, "unknown")
    }

    func testDiagnosticLineContainsFieldsNeededToDetectStaleProcess() {
        let identity = BuildIdentity(
            info: [
                "CFBundleShortVersionString": "0.1.2",
                "CFBundleVersion": "42",
                "TextMouthGitCommit": "deadbee",
                "TextMouthBuildDate": "2026-07-30T17:00:00Z",
                "TextMouthBuildConfiguration": "Debug",
            ],
            executablePath: "/Applications/TextMouth.app/Contents/MacOS/TextMouth"
        )

        XCTAssertTrue(identity.diagnosticLine.contains("version=0.1.2"))
        XCTAssertTrue(identity.diagnosticLine.contains("build=42"))
        XCTAssertTrue(identity.diagnosticLine.contains("configuration=Debug"))
        XCTAssertTrue(identity.diagnosticLine.contains("commit=deadbee"))
        XCTAssertTrue(identity.diagnosticLine.contains("builtAt=2026-07-30T17:00:00Z"))
        XCTAssertTrue(identity.diagnosticLine.contains("executable=/Applications/TextMouth.app"))
    }
}

