import SwiftUI

/// Settings tab for miscellaneous options like Bluetooth monitoring.
struct MiscellaneousSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable Bluetooth monitoring", isOn: $settingsViewModel.bluetoothMonitoringEnabled)
                    .accessibilityLabel("Enable Bluetooth monitoring")
                    .accessibilityHint("When enabled, prevents spurious auto-resume when Bluetooth audio devices disconnect")

                Text("Monitors Bluetooth audio disconnections and blocks the spurious play command macOS sends when headphones are removed.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settingsViewModel.bluetoothMonitoringEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Disconnect delay: \(Int(settingsViewModel.bluetoothDisconnectDelay)) \(Int(settingsViewModel.bluetoothDisconnectDelay) == 1 ? "second" : "seconds")")
                            .accessibilityLabel("Disconnect delay: \(Int(settingsViewModel.bluetoothDisconnectDelay)) seconds")

                        Slider(
                            value: $settingsViewModel.bluetoothDisconnectDelay,
                            in: 1...10,
                            step: 1
                        ) {
                            Text("Disconnect delay")
                        }
                        .accessibilityLabel("Bluetooth disconnect delay slider")
                        .accessibilityValue("\(Int(settingsViewModel.bluetoothDisconnectDelay)) seconds")

                        Text("How long to suppress spurious media commands after a Bluetooth device disconnects. Increase if playback sometimes auto-resumes after removing headphones.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Bluetooth")
            }
        }
        .padding()
    }
}
