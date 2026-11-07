import SwiftUI

/// The bare reader of Slice 1: the book's title and one Play button, both from
/// the session's snapshot, so that the screen does not redraw as the book's
/// place moves. Slice 4 replaces it with the reader the spec describes.
struct PhoneReaderView: View {
    /// The owner of the reader.
    @ObservedObject var session: PhoneSession

    var body: some View {
        // No snapshot means no reader. Nothing in Slice 1 closes the reader
        // while this screen shows; a screen with nothing on it is the safe
        // answer if something does, with the system's Back still there.
        VStack(spacing: 24) {
            if let snapshot = session.snapshot {
                Text(snapshot.title)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Button(PhoneAppWording.playButton(isPlaying: snapshot.isPlaying)) {
                    session.togglePlayPause()
                }
                .accessibilityValue(snapshot.isLoading ? PhoneAppWording.loading : "")
            }
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
    }
}
