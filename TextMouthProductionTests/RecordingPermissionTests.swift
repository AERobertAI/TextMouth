import AVFoundation
import XCTest
@testable import TextMouth

/// The microphone permission a recording asks for (FR04): asked once when
/// nobody has answered, never again after a no, and every no an error the
/// Record window can speak, so nothing is recorded when it is denied. Every
/// test hands in an answer of its own (`FakeMicrophonePermission`), so
/// macOS's prompt never appears while the suite runs.
final class RecordingPermissionTests: XCTestCase {

    // MARK: - Asking

    /// With permission already given, a recording starts without asking.
    func testAnAllowedMicrophoneIsUsedWithoutAsking() async throws {
        let fake = FakeMicrophonePermission(.authorized)

        try await fake.permission.ensureAccess()

        XCTAssertEqual(fake.questions, 0)
    }

    /// Nobody has answered yet: the first recording asks, once, and a yes
    /// lets it record.
    func testAnUnansweredQuestionIsAskedOnceAndAYesRecords() async throws {
        let fake = FakeMicrophonePermission(.notDetermined, whenAsked: true)

        try await fake.permission.ensureAccess()
        try await fake.permission.ensureAccess()

        XCTAssertEqual(fake.questions, 1, "the second recording found the answer given and did not ask again")
        XCTAssertEqual(fake.status, .authorized)
    }

    /// A no given in the prompt just now is an error saying so.
    func testANoJustGivenIsReportedAsDenied() async {
        let fake = FakeMicrophonePermission(.notDetermined, whenAsked: false)

        await assertThrows(.denied, from: fake.permission)
        XCTAssertEqual(fake.questions, 1)
    }

    /// A no given before, in the prompt or in System Settings, is reported
    /// at once: macOS shows its prompt only once, so asking again is futile.
    func testAnEarlierNoIsReportedWithoutAskingAgain() async {
        let fake = FakeMicrophonePermission(.denied)

        await assertThrows(.denied, from: fake.permission)
        XCTAssertEqual(fake.questions, 0)
    }

    /// A restriction the user cannot lift here is reported without asking.
    func testARestrictionIsReportedWithoutAsking() async {
        let fake = FakeMicrophonePermission(.restricted)

        await assertThrows(.restricted, from: fake.permission)
        XCTAssertEqual(fake.questions, 0)
    }

    /// A restriction found only when asking is reported as a restriction,
    /// not as the user's no.
    func testARestrictionFoundWhenAskingIsReportedAsARestriction() async {
        let fake = FakeMicrophonePermission(.notDetermined, whenAsked: false, restrictsWhenAsked: true)

        await assertThrows(.restricted, from: fake.permission)
        XCTAssertEqual(fake.questions, 1)
    }

    // MARK: - The System's Answer

    /// AVFoundation's statuses become the answers TextMouth acts on.
    func testAVFoundationStatusesMapToAnswers() {
        XCTAssertEqual(AudioInputAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(AudioInputAuthorization(.authorized), .authorized)
        XCTAssertEqual(AudioInputAuthorization(.denied), .denied)
        XCTAssertEqual(AudioInputAuthorization(.restricted), .restricted)
    }

    /// The system's permission can show macOS's prompt in the app, but in a
    /// process hosting tests only when the opt-in microphone test was asked
    /// for: a test that forgot its own answer gets a no, never the prompt.
    func testOnlyTheOptInLetsATestHostAsk() {
        XCTAssertTrue(AudioInputPermission.mayAsk(isHostedTest: false, environment: [:]))
        XCTAssertFalse(AudioInputPermission.mayAsk(isHostedTest: true, environment: [:]))
        XCTAssertFalse(AudioInputPermission.mayAsk(isHostedTest: true, environment: ["TEXTMOUTH_MICROPHONE": "0"]))
        XCTAssertTrue(AudioInputPermission.mayAsk(isHostedTest: true, environment: ["TEXTMOUTH_MICROPHONE": "1"]))
        XCTAssertEqual(AudioInputPermission.microphoneTestVariable, "TEXTMOUTH_MICROPHONE")
    }

    // MARK: - Words

    /// Each refusal says what is wrong, and a no says where to change it;
    /// only a no can be changed in System Settings.
    func testTheErrorsSayWhatIsWrongAndWhatToDo() {
        XCTAssertEqual(
            AudioInputPermissionError.denied.errorDescription,
            "TextMouth isn't allowed to use the microphone. To record, turn on TextMouth in System Settings, "
                + "Privacy & Security, Microphone."
        )
        XCTAssertEqual(
            AudioInputPermissionError.restricted.errorDescription,
            "This Mac doesn't allow TextMouth to use the microphone: a device management profile or Screen Time "
                + "restricts it."
        )
        XCTAssertTrue(AudioInputPermissionError.denied.canBeChangedInSystemSettings)
        XCTAssertFalse(AudioInputPermissionError.restricted.canBeChangedInSystemSettings)
    }

    /// The address the Record window opens after a no is System Settings'
    /// Microphone privacy list.
    func testThePrivacySettingsAddressNamesTheMicrophoneList() throws {
        let url = try XCTUnwrap(AudioInputPermission.privacySettingsURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.hasSuffix("Privacy_Microphone"))
    }

    // MARK: - What the App Declares

    /// The app tells macOS, in a plain sentence its prompt shows, why it
    /// wants the microphone and that recordings go into the library.
    /// Without this key macOS ends an app at its first use of a microphone.
    func testTheAppSaysWhyItUsesTheMicrophone() throws {
        let reason = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        XCTAssertTrue(reason.contains("library"), reason)
        XCTAssertTrue(reason.contains("only while you record"), reason)
    }

    /// The app's entitlements include audio input, which Apple asks every
    /// app that captures audio to have, and which the Hardened Runtime
    /// requires. The hosted tests build without signing, so the file the
    /// build signs with is read from the source folder.
    func testTheAppIsEntitledToAudioInput() throws {
        let file = AppSourceFile.folder.appendingPathComponent("Resources/TextMouth.entitlements")
        let data = try Data(contentsOf: file)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, false)
    }

    // MARK: - Helpers

    /// Asserts that `permission` refuses with `expected`.
    private func assertThrows(
        _ expected: AudioInputPermissionError,
        from permission: AudioInputPermission,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await permission.ensureAccess()
            XCTFail("access was granted, expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AudioInputPermissionError, expected, file: file, line: line)
        }
    }
}
