import CoreAudio
import XCTest
@testable import TextMouth

/// Which microphone a recording uses (FR04): the one TextMouth remembers,
/// apart from macOS's own input, when it is connected, and otherwise the
/// default; only real microphones, never a device carrying other apps'
/// sound; and the choice kept as `recordingInputDeviceID` in the store and
/// in config.json.
final class RecordingInputTests: XCTestCase {

    // MARK: - Choosing

    /// The remembered microphone is used when it is connected.
    func testTheRememberedMicrophoneIsUsedWhenConnected() {
        let resolution = RecordingInputChoice.resolve(
            remembered: TestMicrophones.usb.id,
            among: [TestMicrophones.builtIn, TestMicrophones.airPods, TestMicrophones.usb],
            systemDefault: TestMicrophones.airPods.id
        )
        XCTAssertEqual(resolution, RecordingInputChoice.Resolution(device: TestMicrophones.usb, rememberedIsMissing: false))
    }

    /// A remembered microphone that is gone falls back to macOS's default
    /// input, and says it is missing so the window can tell the user.
    func testAMissingMicrophoneFallsBackToTheDefaultAndSaysSo() {
        let resolution = RecordingInputChoice.resolve(
            remembered: TestMicrophones.usb.id,
            among: [TestMicrophones.builtIn, TestMicrophones.airPods],
            systemDefault: TestMicrophones.airPods.id
        )
        XCTAssertEqual(resolution, RecordingInputChoice.Resolution(device: TestMicrophones.airPods, rememberedIsMissing: true))
    }

    /// With none chosen yet, macOS's default input is used, and nothing is
    /// missing.
    func testWithNoChoiceTheDefaultIsUsed() {
        let resolution = RecordingInputChoice.resolve(
            remembered: "",
            among: [TestMicrophones.builtIn, TestMicrophones.airPods],
            systemDefault: TestMicrophones.airPods.id
        )
        XCTAssertEqual(resolution, RecordingInputChoice.Resolution(device: TestMicrophones.airPods, rememberedIsMissing: false))
    }

    /// When the default is not a microphone TextMouth lists, the first one
    /// is used; with none connected, there is none.
    func testTheFirstMicrophoneStandsInForADefaultNotListed() {
        XCTAssertEqual(
            RecordingInputChoice.resolve(remembered: "", among: [TestMicrophones.builtIn], systemDefault: "virtual-device").device,
            TestMicrophones.builtIn
        )
        XCTAssertEqual(
            RecordingInputChoice.resolve(remembered: TestMicrophones.usb.id, among: [], systemDefault: nil),
            RecordingInputChoice.Resolution(device: nil, rememberedIsMissing: true)
        )
    }

    /// Two microphones of the same name are numbered, so they can be told
    /// apart by ear and on a braille display.
    func testMicrophonesSharingANameAreNumbered() {
        let first = AudioInputDevice(id: "usb-1", name: "USB Microphone")
        let second = AudioInputDevice(id: "usb-2", name: "USB Microphone")
        XCTAssertEqual(
            RecordingInputChoice.distinctlyNamed([first, TestMicrophones.builtIn, second]).map(\.name),
            ["USB Microphone", "MacBook Air Microphone", "USB Microphone (2)"]
        )
    }

    // MARK: - Only Microphones

    /// Devices that carry other apps' sound (virtual devices such as
    /// Background Music or a conferencing app's audio, and aggregates) are
    /// never offered; built-in, USB, Bluetooth, and Continuity ones are.
    func testOnlyMicrophonesAreOffered() {
        let excluded = [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate]
        let included = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                        kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt,
                        kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless]
        for transport in excluded {
            XCTAssertFalse(SystemRecordingInputCatalog.isMicrophone(transportType: Int32(bitPattern: transport)), "\(transport)")
        }
        for transport in included {
            XCTAssertTrue(SystemRecordingInputCatalog.isMicrophone(transportType: Int32(bitPattern: transport)), "\(transport)")
        }
    }

    // MARK: - Remembering

    /// The choice is kept under `recordingInputDeviceID`, empty until one
    /// is chosen.
    func testTheChoiceIsKeptByItsIdentifier() {
        let store = makeSandboxedPreferences("recording-input")
        let preference = RecordingInputChoice.preference
        XCTAssertEqual(preference.key, "recordingInputDeviceID")
        XCTAssertEqual(preference.read(from: store), "")

        preference.write(TestMicrophones.usb.id, to: store)

        XCTAssertEqual(store.string(forKey: "recordingInputDeviceID"), TestMicrophones.usb.id)
        XCTAssertEqual(preference.read(from: store), TestMicrophones.usb.id)
        XCTAssertTrue(RecordingPreferences.keys.contains("recordingInputDeviceID"))
    }

    // MARK: - config.json

    /// config.json carries the choice by name: TextMouth writes it, applies
    /// it, and reads an empty, missing, or unreadable value as "keep the
    /// choice in force", as it reads any empty text there.
    @MainActor
    func testTheChoiceIsMirroredInConfigJSON() throws {
        let store = makeSandboxedPreferences("recording-input-config")
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
        RecordingInputChoice.preference.write(TestMicrophones.airPods.id, to: store)

        var written = ConfigService.AppConfig()
        settings.writePreferences(into: &written)
        XCTAssertEqual(try configObject(written)["recordingInputDeviceID"] as? String, TestMicrophones.airPods.id)

        settings.applyConfigChanges(try config(#"{"recordingInputDeviceID": "\#(TestMicrophones.usb.id)"}"#))
        XCTAssertEqual(RecordingInputChoice.preference.read(from: store), TestMicrophones.usb.id)

        for json in [#"{"recordingInputDeviceID": ""}"#, "{}", #"{"recordingInputDeviceID": null}"#,
                     #"{"recordingInputDeviceID": 7}"#] {
            XCTAssertEqual(try config(json).recordingInputDeviceID, "", json)
            settings.applyConfigChanges(try config(json))
            XCTAssertEqual(RecordingInputChoice.preference.read(from: store), TestMicrophones.usb.id, json)
        }
    }

    /// A choice made in the Record window, which writes the store, is saved
    /// to config.json with the next save, as the settings model hears every
    /// change of a preference it mirrors.
    @MainActor
    func testAChoiceMadeInTheRecordWindowIsSavedToConfigJSON() throws {
        let store = makeSandboxedPreferences("recording-input-save")
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store,
            configService: service
        )

        RecordingInputChoice.preference.write(TestMicrophones.builtIn.id, to: store)
        service.flushScheduledSave()

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["recordingInputDeviceID"] as? String, TestMicrophones.builtIn.id)
        withExtendedLifetime(settings) {}
    }

    // MARK: - Helpers

    /// Decodes config.json text as `ConfigService` does.
    private func config(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }

    /// The JSON object config.json holds for `config`.
    private func configObject(_ config: ConfigService.AppConfig) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigService.fileData(for: config)) as? [String: Any])
    }
}
