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
        let _ = ViewBodyCounter.record("PlaybackControlsView")
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
                    viewModel.stepSpeed(forward: false)
                } label: {
                    Image(systemName: "tortoise")
                        .font(.caption)
                }
                .accessibilityLabel(viewModel.speedStepButtonLabel(forward: false))
                .buttonStyle(.plain)

                if viewModel.isAudioBook {
                    // Shared formatter: "1.25x" on screen, "1.25 times speed" spoken.
                    Text(AudioSpeed.visibleLabel(for: viewModel.audioSpeed))
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 50)
                        .accessibilityLabel(AudioSpeed.spokenLabel(for: viewModel.audioSpeed))
                } else {
                    Text("\(Int(viewModel.currentWPM))")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 40)
                        .accessibilityLabel("\(Int(viewModel.currentWPM)) words per minute")
                }

                Button {
                    viewModel.stepSpeed(forward: true)
                } label: {
                    Image(systemName: "hare")
                        .font(.caption)
                }
                .accessibilityLabel(viewModel.speedStepButtonLabel(forward: true))
                .buttonStyle(.plain)

                if viewModel.hasLocalSettings && !viewModel.isAudioBook {
                    Button {
                        viewModel.saveSettingsToGlobal()
                    } label: {
                        Image(systemName: "arrow.up.square")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel(BookSettingsWording.saveAsDefaultsLabel)
                    .buttonStyle(.plain)
                    // The tooltip, which VoiceOver reads as the hint, says
                    // what saving does rather than repeating the label.
                    .help(BookSettingsWording.saveAsDefaultsHint)
                }
            }
            } // showSpeedInPlaybackControls

            // Sleep timer indicator. The label observes the timer itself,
            // so it moves each second whether or not the reader publishes
            // (`SleepTimerStatusLabel`).
            SleepTimerStatusLabel(timer: viewModel.sleepTimerService) { timer in
                HStack(spacing: 4) {
                    Image(systemName: "moon.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(timer.formattedRemaining)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .accessibilityElement(children: .combine)
                // "Sleep timer: 4:59 remaining", or where a timer set for
                // a place in the book stops playback.
                .accessibilityLabel(timer.spokenLabel)
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
            // Page is left out for a book without pages, unless it is the
            // unit in force (`ReaderViewModel.navigationUnitChoices`).
            ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipForwardUnit), id: \.self) { unit in
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
                ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipForwardUnit), id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }

            Picker("Backward navigation unit", selection: Binding(
                get: { viewModel.playbackSkipBackwardUnit },
                set: { viewModel.setPlaybackSkipUnit($0, direction: .backward) }
            )) {
                ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipBackwardUnit), id: \.self) { unit in
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
