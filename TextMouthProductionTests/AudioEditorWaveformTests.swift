import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The audio editor's waveform (FR04): drawn for sighted helpers from an
/// overview of the levels made once per measurement, its bars as loud as
/// the sound and its lines where the cursor, the selection, and the
/// markers are; and hidden from VoiceOver, which meets nothing of it.
@MainActor
final class AudioEditorWaveformTests: XCTestCase {

    /// A bar is as tall as its level is loud: nothing at -60 dBFS and
    /// quieter, the full height at full scale.
    func testABarIsAsTallAsItsLevelIsLoud() {
        XCTAssertEqual(AudioEditorWaveform.barHeight(decibels: 0, height: 96), 96)
        XCTAssertEqual(AudioEditorWaveform.barHeight(decibels: -30, height: 96), 48)
        XCTAssertEqual(AudioEditorWaveform.barHeight(decibels: -60, height: 96), 0)
        XCTAssertEqual(AudioEditorWaveform.barHeight(decibels: AudioEditorLevels.silence, height: 96), 0)
        XCTAssertEqual(AudioEditorWaveform.barHeight(decibels: .nan, height: 96), 0)
    }

    /// A time lies across the width as it lies in the audio, kept inside it.
    func testATimeLiesAcrossTheWidthAsInTheAudio() {
        XCTAssertEqual(AudioEditorWaveform.x(of: 0, duration: 10, width: 500), 0)
        XCTAssertEqual(AudioEditorWaveform.x(of: 2.5, duration: 10, width: 500), 125)
        XCTAssertEqual(AudioEditorWaveform.x(of: 12, duration: 10, width: 500), 500)
        XCTAssertEqual(AudioEditorWaveform.x(of: 2, duration: 0, width: 500), 0)
    }

    /// The overview holds the loudest level of each of its stretches, at
    /// most 4,096 of them however long the audio, and the envelope drawn is
    /// taken from it.
    func testTheOverviewHoldsTheLoudestOfEachStretch() {
        // Ten windows to each of the overview's stretches; the loud one is
        // in the first.
        var decibels = Array(repeating: Float(-50), count: 40_960)
        decibels[5] = -3
        let levels = AudioEditorLevels(decibels: decibels, duration: 409.6)

        XCTAssertEqual(levels.overview.count, AudioEditorLevels.overviewCount)
        XCTAssertEqual(levels.overview.first, -3, "a loud window went missing from its stretch")
        XCTAssertEqual(levels.overview[checked: 1], -50)
        XCTAssertEqual(levels.envelope(2), [-3, -50])
        XCTAssertEqual(AudioEditorLevels(decibels: [-20, -10], duration: 0.02).overview, [-20, -10])
        XCTAssertEqual(AudioEditorLevels.loudest(of: [-20, -10], in: 4), [-20, -20, -10, -10])
    }

    /// VoiceOver meets nothing of the waveform: it holds no element of its
    /// own, wherever hosted windows expose their elements.
    func testTheWaveformIsHiddenFromVoiceOver() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let levels = AudioEditorLevels(decibels: Array(repeating: -20, count: 500), duration: 5)
        let waveform = AudioEditorWaveform(
            levels: levels,
            duration: 5,
            cursor: 2,
            selection: AudioTimeRange(start: 1, end: 3),
            chapters: [0, 2.5],
            markers: [4]
        )
        // A labelled stepper beside it shows the window's elements are
        // exposed; the same view without the waveform has exactly the same
        // elements, so the waveform adds none.
        var withWaveform: [String] = []
        var without: [String] = []
        withHostedView(Self.beside(waveform), until: { !self.accessibleControls(in: $0).isEmpty }) { hosting in
            withWaveform = accessibleControls(in: hosting).map { "\($0.role.rawValue) \($0.label)" }
        }
        withHostedView(Self.beside(EmptyView()), until: { !self.accessibleControls(in: $0).isEmpty }) { hosting in
            without = accessibleControls(in: hosting).map { "\($0.role.rawValue) \($0.label)" }
        }
        XCTAssertFalse(without.isEmpty)
        XCTAssertEqual(withWaveform, without, "the waveform showed VoiceOver something")
    }

    /// `content` above a labelled stepper.
    private static func beside(_ content: some View) -> some View {
        VStack {
            content
            Stepper(value: .constant(1), in: 0...2) { EmptyView() }
                .accessibilityLabel("Beside the waveform")
        }
    }
}
