import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: ReaderViewModel
    /// Settings are a separate observable object from the reader. Observing
    /// both is required for already-open playback bars to reflect changes.
    @ObservedObject private var settingsViewModel: SettingsViewModel

    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        self.settingsViewModel = viewModel.settingsViewModel
    }

    var body: some View {
        HStack(spacing: 20) {
            // Skip backward
            Button {
                viewModel.skipBackward()
            } label: {
                Image(systemName: skipBackwardIcon)
                    .font(.title2)
            }
            .accessibilityLabel("Skip backward: \(viewModel.playbackSkipBackwardUnit.rawValue)")
            .buttonStyle(.plain)

            // Play/Pause
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: playPauseIcon)
                    .font(.title)
            }
            .accessibilityLabel(playPauseLabel)
            .accessibilityIdentifier(voiceOverFocusID)
            .background(StandardVoiceOverFocus())
            .buttonStyle(.plain)

            // Skip forward
            Button {
                viewModel.skipForward()
            } label: {
                Image(systemName: skipForwardIcon)
                    .font(.title2)
            }
            .accessibilityLabel("Skip forward: \(viewModel.playbackSkipForwardUnit.rawValue)")
            .buttonStyle(.plain)

            if settingsViewModel.playbackNavigationUnitControlMode == .separate {
                separateNavigationUnitsMenu
            } else if settingsViewModel.playbackNavigationUnitControlMode == .shared {
                sharedNavigationUnitPicker
            }

            // Bookmark toggle button (hidden by default, shown via settings)
            if settingsViewModel.showBookmarkInPlaybackControls {
                Button {
                    viewModel.toggleBookmarkAtCurrentPosition()
                } label: {
                    Image(systemName: viewModel.hasNearbyBookmark ? "bookmark.fill" : "bookmark")
                        .font(.title2)
                }
                .accessibilityLabel(viewModel.hasNearbyBookmark ? "Remove bookmark" : "Add bookmark")
                .buttonStyle(.plain)
            }

            Spacer()

            // Speed controls (can be hidden via settings)
            if settingsViewModel.showSpeedInPlaybackControls {
            HStack(spacing: 8) {
                Button {
                    viewModel.adjustSpeed(delta: viewModel.isAudioBook ? -0.25 : -25)
                } label: {
                    Image(systemName: "tortoise")
                        .font(.caption)
                }
                .accessibilityLabel(viewModel.isAudioBook ? "Decrease speed by 0.25x" : "Decrease speed by 25 words per minute")
                .buttonStyle(.plain)

                if viewModel.isAudioBook {
                    Text(String(format: "%.1fx", viewModel.audioSpeed))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 40)
                        .accessibilityLabel(String(format: "%.1f times speed", viewModel.audioSpeed))
                } else {
                    Text("\(Int(viewModel.currentWPM))")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 40)
                        .accessibilityLabel("\(Int(viewModel.currentWPM)) words per minute")
                }

                Button {
                    viewModel.adjustSpeed(delta: viewModel.isAudioBook ? 0.25 : 25)
                } label: {
                    Image(systemName: "hare")
                        .font(.caption)
                }
                .accessibilityLabel(viewModel.isAudioBook ? "Increase speed by 0.25x" : "Increase speed by 25 words per minute")
                .buttonStyle(.plain)

                if viewModel.hasLocalSettings {
                    Button {
                        viewModel.saveSettingsToGlobal()
                    } label: {
                        Image(systemName: "arrow.up.square")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel("Save this book's speed to global settings")
                    .buttonStyle(.plain)
                    .help("Save to global settings")
                }
            }
            } // showSpeedInPlaybackControls

            // Sleep timer indicator
            if viewModel.sleepTimerService.isActive {
                HStack(spacing: 4) {
                    Image(systemName: "moon.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(viewModel.sleepTimerService.formattedRemaining)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sleep timer: \(viewModel.sleepTimerService.formattedRemaining) remaining")
            }
        }
        .padding()
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
    }

    /// Uses the forwarded state from ReaderViewModel for reliable SwiftUI updates
    private var playPauseIcon: String {
        if viewModel.isCurrentlyPlaying && !viewModel.isCurrentlyPaused {
            return "pause.fill"
        }
        return "play.fill"
    }

    private var playPauseLabel: String {
        if viewModel.isCurrentlyPlaying && !viewModel.isCurrentlyPaused {
            return "Pause"
        }
        return "Play"
    }

    private var skipBackwardIcon: String {
        viewModel.playbackSkipBackwardUnit.iconName(forward: false)
    }

    private var skipForwardIcon: String {
        viewModel.playbackSkipForwardUnit.iconName(forward: true)
    }

    /// Match the settings-panel style in shared mode: one directly operable
    /// popup picker, without an otherwise redundant one-item parent menu.
    private var sharedNavigationUnitPicker: some View {
        Picker("Navigation unit", selection: Binding(
            get: { viewModel.playbackSkipForwardUnit },
            set: { viewModel.setSharedPlaybackSkipUnit($0) }
        )) {
            ForEach(SkipUnit.allCases, id: \.self) { unit in
                Text(unit.rawValue).tag(unit)
            }
        }
        .pickerStyle(.menu)
        // Supplying label and value separately preserves the popup role while
        // producing “Navigation unit, 15 seconds” without an abbreviated or
        // duplicated native value.
        .accessibilityLabel("Navigation unit")
        .accessibilityValue(viewModel.playbackSkipForwardUnit.rawValue)
        .help("Change this book's forward and backward navigation unit")
    }

    /// Separate mode uses one top-level control. Its two labeled picker
    /// submenus keep independent values without scattering controls around
    /// the rewind and fast-forward buttons.
    private var separateNavigationUnitsMenu: some View {
        Menu {
            Picker("Forward navigation unit", selection: Binding(
                get: { viewModel.playbackSkipForwardUnit },
                set: { viewModel.setPlaybackSkipUnit($0, direction: .forward) }
            )) {
                ForEach(SkipUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }

            Picker("Backward navigation unit", selection: Binding(
                get: { viewModel.playbackSkipBackwardUnit },
                set: { viewModel.setPlaybackSkipUnit($0, direction: .backward) }
            )) {
                ForEach(SkipUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
        } label: {
            Label("Navigation units", systemImage: "arrow.left.arrow.right.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Navigation units")
        .accessibilityValue(
            "Forward navigation unit: \(viewModel.playbackSkipForwardUnit.rawValue); "
                + "backward navigation unit: \(viewModel.playbackSkipBackwardUnit.rawValue)"
        )
        .accessibilityHint("Choose separate forward and backward navigation units for this book")
        .help("Change this book's forward and backward navigation units")
    }
}
