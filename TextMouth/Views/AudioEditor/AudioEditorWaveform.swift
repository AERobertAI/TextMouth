import SwiftUI

/// The edited audio's level envelope, drawn for sighted helpers (FR04): the
/// loudness of every stretch, mirrored about the middle, with the selection
/// shaded, the chapter markers and the markers as thin lines, and the
/// cursor as a bold one.
///
/// It is hidden from VoiceOver, and no command needs it: everything it
/// shows the time display, the status line, and the lists say in words, as
/// the user asked. It can't be clicked, so it never takes the keyboard's
/// focus either.
struct AudioEditorWaveform: View {
    /// The levels to draw, once measured; nil draws only the lines.
    let levels: AudioEditorLevels?
    /// How long the audio lasts, in seconds: the drawing's width.
    let duration: TimeInterval
    /// Where the cursor is.
    let cursor: TimeInterval
    /// The selection, if any.
    let selection: AudioTimeRange?
    /// Where the chapter markers are.
    let chapters: [TimeInterval]
    /// Where the markers are.
    let markers: [TimeInterval]

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.secondary.opacity(0.08)))

            // The selection, shaded behind the sound.
            if let selection {
                let start = Self.x(of: selection.start, duration: duration, width: width)
                let end = Self.x(of: selection.end, duration: duration, width: width)
                context.fill(Path(CGRect(x: start, y: 0, width: max(1, end - start), height: height)), with: .color(Color.accentColor.opacity(0.25)))
            }

            // The sound: one bar a point wide for each stretch.
            if let levels {
                let columns = max(1, Int(width.rounded(.down)))
                var bars = Path()
                for (column, level) in levels.envelope(columns).enumerated() {
                    let bar = Self.barHeight(decibels: level, height: height)
                    guard bar > 0 else { continue }
                    bars.addRect(CGRect(x: CGFloat(column), y: (height - bar) / 2, width: 1, height: bar))
                }
                context.fill(bars, with: .color(Color.primary.opacity(0.55)))
            }

            // The chapter markers and the markers, then the cursor on top.
            for time in chapters {
                Self.line(at: Self.x(of: time, duration: duration, width: width), height: height, width: 1, color: .orange, in: context)
            }
            for time in markers {
                Self.line(at: Self.x(of: time, duration: duration, width: width), height: height, width: 1, color: .green, in: context)
            }
            Self.line(at: Self.x(of: cursor, duration: duration, width: width), height: height, width: 2, color: .accentColor, in: context)
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    /// The quietest level drawn, in dBFS: anything quieter draws nothing.
    static let floor: Float = -60

    /// How tall a bar for `decibels` is, of `height`: nothing at the floor
    /// and below, all of it at full scale.
    static func barHeight(decibels: Float, height: CGFloat) -> CGFloat {
        guard decibels.isFinite, decibels > floor else { return 0 }
        return CGFloat(min(1, (decibels - floor) / -floor)) * height
    }

    /// Where `time` is across `width`, for audio lasting `duration`.
    static func x(of time: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0, time.isFinite else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    /// Draws a vertical line `width` wide at `x`, the full `height`.
    private static func line(at x: CGFloat, height: CGFloat, width: CGFloat, color: Color, in context: GraphicsContext) {
        context.fill(Path(CGRect(x: x - width / 2, y: 0, width: width, height: height)), with: .color(color))
    }
}
