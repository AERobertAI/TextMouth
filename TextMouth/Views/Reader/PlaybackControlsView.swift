import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: ReaderViewModel

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

            if viewModel.settingsViewModel.playbackNavigationUnitControlMode == .separate {
                navigationUnitMenu(direction: .backward)
            }

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

            if viewModel.settingsViewModel.playbackNavigationUnitControlMode == .separate {
                navigationUnitMenu(direction: .forward)
            } else if viewModel.settingsViewModel.playbackNavigationUnitControlMode == .shared {
                sharedNavigationUnitMenu
            }

            // Bookmark toggle button (hidden by default, shown via settings)
            if viewModel.settingsViewModel.showBookmarkInPlaybackControls {
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
            if viewModel.settingsViewModel.showSpeedInPlaybackControls {
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

    /// A single popup that changes both directions and displays their shared
    /// unit in compact form. The nested Picker supplies native selected-item
    /// semantics to both the visual menu and VoiceOver.
    private var sharedNavigationUnitMenu: some View {
        Menu {
            Picker("Navigation unit", selection: Binding(
                get: { viewModel.playbackSkipForwardUnit },
                set: { viewModel.setSharedPlaybackSkipUnit($0) }
            )) {
                ForEach(SkipUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
        } label: {
            Label(
                viewModel.playbackSkipForwardUnit.compactLabel,
                systemImage: "arrow.left.arrow.right.circle"
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Forward and backward navigation unit")
        .accessibilityValue(viewModel.playbackSkipForwardUnit.rawValue)
        .help("Change this book's forward and backward navigation unit")
    }

    /// Popup for one direction in separate-menu mode.
    private func navigationUnitMenu(direction: PlaybackSkipDirection) -> some View {
        let selected = direction == .forward
            ? viewModel.playbackSkipForwardUnit
            : viewModel.playbackSkipBackwardUnit
        let directionLabel = direction == .forward ? "forward" : "backward"

        return Menu {
            Picker("Skip \(directionLabel) unit", selection: Binding(
                get: {
                    direction == .forward
                        ? viewModel.playbackSkipForwardUnit
                        : viewModel.playbackSkipBackwardUnit
                },
                set: { viewModel.setPlaybackSkipUnit($0, direction: direction) }
            )) {
                ForEach(SkipUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Skip \(directionLabel) navigation unit")
        .accessibilityValue(selected.rawValue)
        .help("Change this book's skip \(directionLabel) unit")
    }
}
