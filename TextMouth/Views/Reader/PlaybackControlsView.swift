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
            .accessibilityLabel(PlaybackControlsWording.skipBackward(unit: viewModel.playbackSkipBackwardUnit.title))
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
            .accessibilityLabel(PlaybackControlsWording.skipForward(unit: viewModel.playbackSkipForwardUnit.title))
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
                .accessibilityLabel(viewModel.hasNearbyBookmark ? PlaybackControlsWording.removeBookmark : PlaybackControlsWording.addBookmark)
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
                    Text(verbatim: "\(Int(viewModel.currentWPM))")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 40)
                        .accessibilityLabel(PlaybackControlsWording.wordsPerMinute(Int(viewModel.currentWPM)))
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
        .accessibilityLabel(PlaybackControlsWording.groupLabel)
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
            return PlaybackControlsWording.pause
        }
        return PlaybackControlsWording.play
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
        Picker(PlaybackControlsWording.unitLabel, selection: Binding(
            get: { viewModel.playbackSkipForwardUnit },
            set: { viewModel.setSharedPlaybackSkipUnit($0) }
        )) {
            // Page is left out for a book without pages, unless it is the
            // unit in force (`ReaderViewModel.navigationUnitChoices`).
            ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipForwardUnit), id: \.self) { unit in
                Text(unit.title).tag(unit)
            }
        }
        .pickerStyle(.menu)
        // Supplying label and value separately preserves the popup role while
        // producing “Navigation unit, 15 seconds” without an abbreviated or
        // duplicated native value.
        .accessibilityLabel(PlaybackControlsWording.unitLabel)
        .accessibilityValue(viewModel.playbackSkipForwardUnit.title)
        .help(PlaybackControlsWording.unitHelp)
    }

    /// Separate mode uses one top-level control. Its two labeled picker
    /// submenus keep independent values without scattering controls around
    /// the rewind and fast-forward buttons.
    private var separateNavigationUnitsMenu: some View {
        Menu {
            Picker(PlaybackControlsWording.forwardUnitLabel, selection: Binding(
                get: { viewModel.playbackSkipForwardUnit },
                set: { viewModel.setPlaybackSkipUnit($0, direction: .forward) }
            )) {
                ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipForwardUnit), id: \.self) { unit in
                    Text(unit.title).tag(unit)
                }
            }

            Picker(PlaybackControlsWording.backwardUnitLabel, selection: Binding(
                get: { viewModel.playbackSkipBackwardUnit },
                set: { viewModel.setPlaybackSkipUnit($0, direction: .backward) }
            )) {
                ForEach(viewModel.navigationUnitChoices(keeping: viewModel.playbackSkipBackwardUnit), id: \.self) { unit in
                    Text(unit.title).tag(unit)
                }
            }
        } label: {
            Label(PlaybackControlsWording.unitsLabel, systemImage: "arrow.left.arrow.right.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(PlaybackControlsWording.unitsLabel)
        .accessibilityValue(PlaybackControlsWording.unitsValue(
            forward: viewModel.playbackSkipForwardUnit.title,
            backward: viewModel.playbackSkipBackwardUnit.title
        ))
        .accessibilityHint(PlaybackControlsWording.unitsHint)
        .help(PlaybackControlsWording.unitsHelp)
    }
}

// MARK: - Wording

/// The words of the playback controls: the buttons' labels, and the
/// navigation unit menus' labels, values, and hints. The unit names come from
/// `SkipUnit`, whose raw values are stored in the settings.
enum PlaybackControlsWording {
    /// The skip backward button's label. `unit` is the unit's name, such as "15 seconds".
    static func skipBackward(unit: String) -> String {
        // Translators: What VoiceOver says for the playback bar's skip backward button. %@ is the unit it skips by, such as "15 seconds" or "Sentence".
        InterfaceText.line("playbackControls.skipBackward", "Skip backward: \(unit)")
    }
    /// The skip forward button's label. `unit` is the unit's name, such as "15 seconds".
    static func skipForward(unit: String) -> String {
        // Translators: What VoiceOver says for the playback bar's skip forward button. %@ is the unit it skips by, such as "15 seconds" or "Sentence".
        InterfaceText.line("playbackControls.skipForward", "Skip forward: \(unit)")
    }
    /// The bookmark button's label while a bookmark is near the place.
    static var removeBookmark: String {
        // Translators: What VoiceOver says for the playback bar's bookmark button while a bookmark is at the place being read; it removes that bookmark.
        InterfaceText.line("playbackControls.removeBookmark", "Remove bookmark")
    }
    /// The bookmark button's label while no bookmark is near the place.
    static var addBookmark: String {
        // Translators: What VoiceOver says for the playback bar's bookmark button while no bookmark is at the place being read; it adds one.
        InterfaceText.line("playbackControls.addBookmark", "Add bookmark")
    }
    /// The speed of a text book, spoken: "500 words per minute".
    static func wordsPerMinute(_ words: Int) -> String {
        // Translators: What VoiceOver says for the playback bar's speed of a text book. %lld is the number of words read in a minute.
        InterfaceText.line("common.countWordsPerMinute", "\(number: words) words per minute")
    }
    /// The label of the whole bar.
    static var groupLabel: String {
        // Translators: What VoiceOver calls the group of playback buttons at the bottom of the reader.
        InterfaceText.line("playbackControls.groupLabel", "Playback controls")
    }
    /// The play/pause button's label while playing.
    static var pause: String {
        // Translators: Label of the reader's play and pause button while the book plays; it pauses.
        InterfaceText.line("common.pause", "Pause")
    }
    /// The play/pause button's label while not playing.
    static var play: String {
        // Translators: Label of the reader's play and pause button while the book is not playing; it plays.
        InterfaceText.line("common.play", "Play")
    }
    /// The one shared navigation unit menu's label.
    static var unitLabel: String {
        // Translators: Label of the playback bar's menu that sets the unit by which this book moves forward and backward.
        InterfaceText.line("playbackControls.unitLabel", "Navigation unit")
    }
    /// The help of the shared navigation unit menu.
    static var unitHelp: String {
        // Translators: Help text of the playback bar's menu that sets the one unit by which this book moves forward and backward.
        InterfaceText.line("playbackControls.unitHelp", "Change this book's forward and backward navigation unit")
    }
    /// The forward unit picker's label.
    static var forwardUnitLabel: String {
        // Translators: Label of the menu that sets the unit by which this book moves forward.
        InterfaceText.line("playbackControls.forwardUnitLabel", "Forward navigation unit")
    }
    /// The backward unit picker's label.
    static var backwardUnitLabel: String {
        // Translators: Label of the menu that sets the unit by which this book moves backward.
        InterfaceText.line("playbackControls.backwardUnitLabel", "Backward navigation unit")
    }
    /// The menu of both units' label.
    static var unitsLabel: String {
        // Translators: Label of the playback bar's menu that holds separate forward and backward navigation units.
        InterfaceText.line("playbackControls.unitsLabel", "Navigation units")
    }
    /// The menu of both units' value: each direction's unit.
    static func unitsValue(forward: String, backward: String) -> String {
        // Translators: What VoiceOver says for the value of the menu that holds separate navigation units. %1$@ is the forward unit and %2$@ the backward unit, each such as "15 seconds" or "Sentence".
        InterfaceText.line("playbackControls.unitsValue", "Forward navigation unit: \(forward); backward navigation unit: \(backward)")
    }
    /// The menu of both units' hint.
    static var unitsHint: String {
        // Translators: Hint of the playback bar's menu that holds separate forward and backward navigation units.
        InterfaceText.line("playbackControls.unitsHint", "Choose separate forward and backward navigation units for this book")
    }
    /// The menu of both units' help.
    static var unitsHelp: String {
        // Translators: Help text of the playback bar's menu that holds separate forward and backward navigation units.
        InterfaceText.line("playbackControls.unitsHelp", "Change this book's forward and backward navigation units")
    }
}
