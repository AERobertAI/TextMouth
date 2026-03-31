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
            .accessibilityLabel("Skip backward: \(viewModel.settingsViewModel.skipBackwardUnit.rawValue)")
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
            .accessibilityLabel("Skip forward: \(viewModel.settingsViewModel.skipForwardUnit.rawValue)")
            .buttonStyle(.plain)

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
        let unit = viewModel.settingsViewModel.skipBackwardUnit
        switch unit {
        case .seconds10: return "gobackward.10"
        case .seconds15: return "gobackward.15"
        case .seconds30: return "gobackward.30"
        case .seconds60: return "gobackward.60"
        case .sentence: return "text.line.first.and.arrowtriangle.forward"
        case .paragraph: return "text.justify.left"
        case .heading, .subheading: return "backward.end.fill"
        case .bookmark: return "bookmark.fill"
        }
    }

    private var skipForwardIcon: String {
        let unit = viewModel.settingsViewModel.skipForwardUnit
        switch unit {
        case .seconds10: return "goforward.10"
        case .seconds15: return "goforward.15"
        case .seconds30: return "goforward.30"
        case .seconds60: return "goforward.60"
        case .sentence: return "text.line.last.and.arrowtriangle.forward"
        case .paragraph: return "text.justify.right"
        case .heading, .subheading: return "forward.end.fill"
        case .bookmark: return "bookmark.fill"
        }
    }
}
