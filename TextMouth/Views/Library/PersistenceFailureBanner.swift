import SwiftUI

/// The Library window's notice of writes and cleanups that failed (TODO
/// S09): one row for each subsystem with a failure, naming the subsystem and
/// the reason in one sentence, with Retry when the failure can run again
/// and Dismiss. A row disappears once the subsystem's next write succeeds.
///
/// It is not modal and never an alert: a write that keeps failing fails
/// again every half second. VoiceOver hears each new problem once, from the
/// failure center, wherever the user is, and finds the rows here at the top
/// of the library, each sentence a static text followed by its buttons,
/// whose labels name the subsystem so one row's Retry is not mistaken for
/// another's.
struct PersistenceFailureBanner: View {
    @ObservedObject var center: PersistenceFailureCenter

    var body: some View {
        let rows = center.bannerRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    PersistenceFailureBannerRowView(
                        row: row,
                        onRetry: { center.retry(row.subsystem) },
                        onDismiss: { center.dismiss(row.subsystem) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Storage problems")
        }
    }
}

/// One row of the banner: its sentence, then its buttons.
struct PersistenceFailureBannerRowView: View {
    /// The failures of one subsystem, as the banner words them.
    let row: PersistenceBannerRow
    /// Runs the subsystem's failures again.
    let onRetry: () -> Void
    /// Hides the row until the subsystem clears.
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(row.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
            Spacer(minLength: 8)
            if row.canRetry {
                Button("Retry", action: onRetry)
                    .accessibilityLabel(row.subsystem.retryLabel)
            }
            Button("Dismiss", action: onDismiss)
                .accessibilityLabel(row.subsystem.dismissLabel)
                .accessibilityHint(Self.dismissHint)
        }
    }

    /// What VoiceOver adds after a pause on Dismiss: that dismissing saves
    /// nothing, and when the notice comes back.
    static let dismissHint = "Hides this notice without saving anything. "
        + "It appears again if the problem returns after it clears."
}
