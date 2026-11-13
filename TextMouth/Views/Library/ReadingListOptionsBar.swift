import SwiftUI

/// The options bar at the top of the Reading List (FR09): what a book
/// opened from the reading list does when it ends, whether continuing
/// passes over finished books, whether a finished book leaves the list, and,
/// in a cloud library, whether this Mac keeps the list's books downloaded.
///
/// All are AppKit controls the keyboard and VoiceOver reach as they reach
/// any other, side by side with no group around them, so VoiceOver moves to
/// each directly: a pop-up button, which speaks its label, the option
/// chosen, and its hint, and the checkboxes, each of which speaks its
/// label, whether it is checked, and its hint. Each choice is saved at once,
/// by the closures the window gives: the list's choices with the list, and
/// the choice to keep the books on this Mac in this Mac's own folder.
///
/// The controls sit in one row, which wraps onto a second line when the
/// window is too narrow for them all (`WrappingRow`), never truncating a
/// label; their order, which is the order VoiceOver and the keyboard visit
/// them in, does not change.
struct ReadingListOptionsBar: View {
    /// What a book opened from the list does when it ends.
    let continuation: ReadingList.Continuation
    /// Whether continuing passes over finished books.
    let skipsFinished: Bool
    /// Whether a book leaves the list as soon as it is finished.
    let removesFinished: Bool
    /// Whether this Mac keeps the list's books downloaded; this Mac's own
    /// choice, not the list's.
    let keepsBooks: Bool
    /// Whether the library is in a cloud location, which alone shows the
    /// checkbox for keeping the list's books on this Mac.
    let showsKeepChoice: Bool
    /// Saves a new choice of what a book does when it ends.
    let chooseContinuation: (ReadingList.Continuation) -> Void
    /// Saves skipping finished books on or off.
    let chooseSkipsFinished: (Bool) -> Void
    /// Saves removing finished books on or off.
    let chooseRemovesFinished: (Bool) -> Void
    /// Saves keeping the list's books on this Mac on or off, on this Mac.
    let chooseKeepsBooks: (Bool) -> Void

    var body: some View {
        WrappingRow(spacing: 16, lineSpacing: 4) {
            // The label is spoken from the control itself, as in Settings:
            // a pop-up button takes no label from the picker's title.
            Picker(ReadingListWording.continuationLabel, selection: Binding(
                get: { continuation },
                set: { chooseContinuation($0) }
            )) {
                ForEach(ReadingList.Continuation.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(ReadingListWording.continuationHint)
            .accessibilityLabel(ReadingListWording.continuationLabel)
            .accessibilityHint(ReadingListWording.continuationHint)

            Toggle(ReadingListWording.skipFinishedLabel, isOn: Binding(
                get: { skipsFinished },
                set: { chooseSkipsFinished($0) }
            ))
            .checkboxToggleStyle()
            .help(ReadingListWording.skipFinishedHint)
            .accessibilityLabel(ReadingListWording.skipFinishedLabel)
            .accessibilityHint(ReadingListWording.skipFinishedHint)

            Toggle(ReadingListWording.removeFinishedLabel, isOn: Binding(
                get: { removesFinished },
                set: { chooseRemovesFinished($0) }
            ))
            .checkboxToggleStyle()
            .help(ReadingListWording.removeFinishedHint)
            .accessibilityLabel(ReadingListWording.removeFinishedLabel)
            .accessibilityHint(ReadingListWording.removeFinishedHint)

            // Only a cloud library has downloads to keep; elsewhere there is
            // nothing to choose and no control to find.
            if showsKeepChoice {
                Toggle(ReadingListWording.keepBooksLabel, isOn: Binding(
                    get: { keepsBooks },
                    set: { chooseKeepsBooks($0) }
                ))
                .checkboxToggleStyle()
                .help(ReadingListWording.keepBooksHint)
                .accessibilityLabel(ReadingListWording.keepBooksLabel)
                .accessibilityHint(ReadingListWording.keepBooksHint)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

/// A row of views that wraps onto further lines, as text does, when they do
/// not fit the width offered: each view keeps its natural size and the
/// order it was declared in, so a label is never truncated and the order
/// VoiceOver and the keyboard visit the views in is the order they read in.
struct WrappingRow: Layout {
    /// The space between two views on a line.
    var spacing: CGFloat = 8
    /// The space between two lines.
    var lineSpacing: CGFloat = 4

    /// Where each of views of the given `sizes` goes in a row `width` wide,
    /// in order, and the size the whole takes: a view that would run past
    /// `width` starts a new line, unless it is the first on its line, which
    /// keeps its place however wide it is.
    static func arrange(
        _ sizes: [CGSize],
        width: CGFloat,
        spacing: CGFloat,
        lineSpacing: CGFloat
    ) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                // Start a new line below the tallest view of this one.
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + lineHeight))
    }

    /// The sizes the views would like, unconstrained.
    private func sizes(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrange(
            sizes(of: subviews),
            width: proposal.width ?? .infinity,
            spacing: spacing,
            lineSpacing: lineSpacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(of: subviews)
        let origins = Self.arrange(sizes, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing).origins
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + origins[index].x, y: bounds.minY + origins[index].y),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }
}
