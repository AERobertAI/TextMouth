import AVFoundation
import Combine
import CoreAudio

// MARK: - A Microphone

/// A microphone TextMouth can record from: the name macOS shows for it, and
/// the identifier that names it from one launch to the next.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// The device's unique identifier (`AVCaptureDevice.uniqueID`), the same
    /// each time it connects.
    let id: String
    /// Its name, as macOS shows it, such as "MacBook Air Microphone".
    let name: String
}

// MARK: - Which Microphone a Recording Uses

/// The microphone TextMouth records from: its own choice, remembered apart
/// from the input macOS uses for everything else (the user's decision of
/// October 4).
///
/// The choice is saved as `recordingInputDeviceID` in the preferences
/// store, and the settings model mirrors it in config.json. An empty value
/// means none was chosen yet: a recording then uses macOS's default input.
enum RecordingInputChoice {
    /// The remembered choice, saved as the microphone's identifier, or empty
    /// while none was chosen.
    static let preference = StoredPreference<String>(
        key: "recordingInputDeviceID",
        read: { store, key in store.string(forKey: key) ?? "" },
        write: { identifier, store, key in store.set(identifier, forKey: key) }
    )

    /// The store keys this choice keeps, for the settings model's mirror.
    static var preferenceKeys: [String] { [preference.key] }

    /// The microphone a recording uses, and whether the remembered one is
    /// missing.
    struct Resolution: Equatable, Sendable {
        /// The microphone to record from; nil when none is connected.
        let device: AudioInputDevice?
        /// Whether a microphone was remembered but is not connected now, so
        /// the recording falls back to the default and the Record window
        /// says so.
        let rememberedIsMissing: Bool
    }

    /// Which of `devices` a recording uses: `remembered` when it is
    /// connected; otherwise macOS's default input, `systemDefault`, or,
    /// when that is not among them either, the first. `remembered` is the
    /// saved identifier, empty when none was chosen.
    static func resolve(
        remembered: String,
        among devices: [AudioInputDevice],
        systemDefault: String?
    ) -> Resolution {
        if let chosen = devices.first(where: { $0.id == remembered }) {
            return Resolution(device: chosen, rememberedIsMissing: false)
        }
        let fallback = devices.first { $0.id == systemDefault } ?? devices.first
        return Resolution(device: fallback, rememberedIsMissing: !remembered.isEmpty)
    }

    /// `devices` with the name of each one that shares its name with an
    /// earlier one numbered, as "USB Microphone (2)", so VoiceOver and a
    /// braille display tell two identical microphones apart.
    static func distinctlyNamed(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        var seen: [String: Int] = [:]
        return devices.map { device in
            let count = (seen[device.name] ?? 0) + 1
            seen[device.name] = count
            return count == 1 ? device : AudioInputDevice(id: device.id, name: "\(device.name) (\(count))")
        }
    }
}

// MARK: - Listing Microphones

/// Lists the microphones connected now and says when that changes. The
/// app's is AVFoundation's (`SystemRecordingInputCatalog`); tests hand the
/// Record window a fixed list.
@MainActor
protocol RecordingInputCatalog: AnyObject {
    /// The microphones connected now, in the order macOS lists them.
    func devices() -> [AudioInputDevice]
    /// The identifier of macOS's default input, if there is one.
    func systemDefaultDeviceID() -> String?
    /// Told, on the main actor, each time a microphone connects or
    /// disconnects.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// The microphones AVFoundation finds: every audio input device, less those
/// that carry other apps' sound rather than a microphone's.
@MainActor
final class SystemRecordingInputCatalog: RecordingInputCatalog {
    var onChange: (@MainActor () -> Void)?

    /// The subscriptions to devices connecting and disconnecting, which end
    /// when the catalog goes.
    private var subscriptions: Set<AnyCancellable> = []

    /// A catalog that starts following devices at once.
    init() {
        let center = NotificationCenter.default
        // AVFoundation posts these on a thread of its own; the change is
        // handed to the main queue, where the list is read again.
        center.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: center.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            .store(in: &subscriptions)
    }

    func devices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
            .filter { $0.isConnected && Self.isMicrophone(transportType: $0.transportType) }
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func systemDefaultDeviceID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// Whether a device of `transportType` (a Core Audio transport type,
    /// as `AVCaptureDevice.transportType` gives it) can be a microphone.
    /// Virtual devices (Background Music, a conferencing app's audio,
    /// loopback drivers) and aggregates carry other apps' sound, which the
    /// user asked never to record; built-in, USB, Bluetooth, Thunderbolt,
    /// and Continuity devices are microphones.
    nonisolated static func isMicrophone(transportType: Int32) -> Bool {
        let transport = UInt32(bitPattern: transportType)
        return ![
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate,
        ].contains(transport)
    }
}
