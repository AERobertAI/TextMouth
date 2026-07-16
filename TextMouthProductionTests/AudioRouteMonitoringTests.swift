import CoreAudio
import XCTest
@testable import TextMouth

@MainActor
final class AudioRouteMonitoringTests: XCTestCase {
    private final class DeviceState {
        var defaultID: AudioDeviceID?
        var deviceIDs: [AudioDeviceID]
        var bluetoothIDs: Set<AudioDeviceID>

        init(
            defaultID: AudioDeviceID?,
            deviceIDs: [AudioDeviceID],
            bluetoothIDs: Set<AudioDeviceID> = []
        ) {
            self.defaultID = defaultID
            self.deviceIDs = deviceIDs
            self.bluetoothIDs = bluetoothIDs
        }
    }

    private final class Clock {
        var now: Date

        init(_ now: Date = Date(timeIntervalSince1970: 1_000)) {
            self.now = now
        }
    }

    private struct Harness {
        let service: NowPlayingService
        let ownerID: UUID
        let logs: () -> [String]
        let pauseCount: () -> Int
        let setPlaying: (Bool) -> Void
    }

    func testSetupTimeBluetoothBaselineDrivesFirstDefaultOutputChange() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        XCTAssertEqual(harness.service.previousDeviceID, 42)
        XCTAssertTrue(harness.service.previousDeviceWasBluetooth)

        devices.defaultID = 99
        devices.deviceIDs = [99]
        harness.service.handleDefaultOutputChange()

        XCTAssertTrue(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 1)
        XCTAssertEqual(harness.service.previousDeviceID, 99)
        XCTAssertFalse(harness.service.previousDeviceWasBluetooth)
    }

    func testBluetoothDefaultDepartureWhilePausedArmsWithoutDoublePause() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: false)
        harness.service.refreshPreviousDeviceInfo()

        devices.defaultID = 99
        devices.deviceIDs = [99]
        harness.service.handleDefaultOutputChange()

        XCTAssertTrue(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 0)
        XCTAssertTrue(harness.logs().contains { $0.contains("action=remain-paused") })
    }

    func testNonBluetoothDefaultDepartureDoesNotArmSuppression() {
        let devices = DeviceState(defaultID: 99, deviceIDs: [99, 101])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.defaultID = 101
        devices.deviceIDs = [101]
        harness.service.handleDefaultOutputChange()

        XCTAssertFalse(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 0)
        XCTAssertTrue(harness.logs().contains { $0.contains("outgoing-not-bluetooth") })
    }

    func testRemovedBluetoothDeviceArmsSuppressionAndClearsCachedState() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.deviceIDs = [99]
        harness.service.handleDeviceListChange()

        XCTAssertTrue(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 1)
        XCTAssertEqual(harness.service.previousDeviceID, 0)
        XCTAssertFalse(harness.service.previousDeviceWasBluetooth)
        XCTAssertTrue(harness.logs().contains {
            $0.contains("trigger=cached-bluetooth-device-removed")
        })
    }

    func testBluetoothDeviceStillInListOnlyRefreshesBaseline() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.deviceIDs.append(101)
        harness.service.handleDeviceListChange()

        XCTAssertFalse(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 0)
        XCTAssertEqual(harness.service.previousDeviceID, 42)
    }

    func testNoCachedDeviceDoesNotTreatAnUnrelatedListChangeAsDisconnect() {
        let devices = DeviceState(defaultID: nil, deviceIDs: [])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.defaultID = 99
        devices.deviceIDs = [99]
        harness.service.handleDeviceListChange()

        XCTAssertFalse(harness.service.isRouteCommandSuppressed)
        XCTAssertEqual(harness.pauseCount(), 0)
        XCTAssertEqual(harness.service.previousDeviceID, 99)
    }

    func testStaleDefaultDeviceIsNotCachedWhenMissingFromActiveList() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices)

        harness.service.refreshPreviousDeviceInfo()

        XCTAssertEqual(harness.service.previousDeviceID, 0)
        XCTAssertFalse(harness.service.previousDeviceWasBluetooth)
        XCTAssertTrue(harness.logs().contains { $0.contains("defaultID=42 live=false") })
    }

    func testEmptyDeviceListQueryTrustsCurrentDefaultAsDefensiveFallback() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices)

        harness.service.refreshPreviousDeviceInfo()

        XCTAssertEqual(harness.service.previousDeviceID, 42)
        XCTAssertTrue(harness.service.previousDeviceWasBluetooth)
    }

    func testListChangeAfterDrainReestablishesBluetoothBaselineOnReconnect() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices)
        harness.service.refreshPreviousDeviceInfo()

        devices.deviceIDs = [99]
        harness.service.handleDeviceListChange()
        XCTAssertEqual(harness.service.previousDeviceID, 0)

        devices.deviceIDs = [42, 99]
        harness.service.handleDeviceListChange()

        XCTAssertEqual(harness.service.previousDeviceID, 42)
        XCTAssertTrue(harness.service.previousDeviceWasBluetooth)
    }

    func testDeviceListThenDefaultOutputNotificationsPauseOnlyOnce() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.deviceIDs = [99]
        harness.service.handleDeviceListChange()
        harness.setPlaying(false)

        devices.defaultID = 99
        harness.service.handleDefaultOutputChange()

        XCTAssertEqual(harness.pauseCount(), 1)
        XCTAssertTrue(harness.service.isRouteCommandSuppressed)
    }

    func testDisablingMonitoringClearsSuppressionAndIgnoresQueuedCallbacks() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let harness = makeHarness(devices: devices, playing: true)
        harness.service.refreshPreviousDeviceInfo()

        devices.defaultID = 99
        devices.deviceIDs = [99]
        harness.service.handleDefaultOutputChange()
        XCTAssertTrue(harness.service.isRouteCommandSuppressed)

        harness.service.updateBluetoothSettings(enabled: false, delay: 2)
        XCTAssertFalse(harness.service.isRouteCommandSuppressed)
        let pausesBeforeQueuedCallback = harness.pauseCount()
        harness.service.handleDeviceListChange()

        XCTAssertEqual(harness.pauseCount(), pausesBeforeQueuedCallback)
        XCTAssertTrue(harness.logs().contains { $0.contains("monitoring-disabled") })
    }

    func testChangingDelayControlsTheNextSuppressionDeadline() {
        let devices = DeviceState(defaultID: 42, deviceIDs: [42, 99], bluetoothIDs: [42])
        let clock = Clock()
        let harness = makeHarness(devices: devices, clock: clock)
        harness.service.refreshPreviousDeviceInfo()
        harness.service.updateBluetoothSettings(enabled: true, delay: 7)

        devices.defaultID = 99
        devices.deviceIDs = [99]
        harness.service.handleDefaultOutputChange()
        clock.now = clock.now.addingTimeInterval(6.999)
        XCTAssertTrue(harness.service.isRouteCommandSuppressed)
        clock.now = clock.now.addingTimeInterval(0.001)
        XCTAssertFalse(harness.service.isRouteCommandSuppressed)
    }

    func testEnablingMonitoringOnTestCoordinatorDoesNotInstallCoreAudioListeners() {
        let devices = DeviceState(defaultID: 99, deviceIDs: [99])
        let harness = makeHarness(devices: devices, monitoring: false)

        harness.service.updateBluetoothSettings(enabled: true, delay: 2)

        XCTAssertFalse(harness.service.isListeningForDeviceChanges)
        XCTAssertTrue(harness.logs().contains { $0.contains("settings enabled=true") })
    }

    private func makeHarness(
        devices: DeviceState,
        clock: Clock = Clock(),
        playing: Bool = false,
        monitoring: Bool = true
    ) -> Harness {
        var messages: [String] = []
        var pauseCalls = 0
        var isPlaying = playing
        let ownerID = UUID()
        let service = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { messages.append($0) },
            now: { clock.now },
            defaultOutputDevice: { devices.defaultID },
            audioDeviceIDs: { devices.deviceIDs },
            isBluetoothDevice: { devices.bluetoothIDs.contains($0) }
        )
        service.setup(
            ownerID: ownerID,
            onPlay: { isPlaying = true },
            onPause: { isPlaying = false },
            onAudioRouteChangePause: {
                pauseCalls += 1
                isPlaying = false
            },
            onTogglePlayPause: { isPlaying.toggle() },
            onSkipForward: {},
            onSkipBackward: {},
            isCurrentlyPlaying: { isPlaying },
            bluetoothMonitoring: monitoring,
            bluetoothDelay: 2
        )
        service.activate(ownerID: ownerID)
        return Harness(
            service: service,
            ownerID: ownerID,
            logs: { messages },
            pauseCount: { pauseCalls },
            setPlaying: { isPlaying = $0 }
        )
    }
}
