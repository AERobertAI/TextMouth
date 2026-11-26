import SwiftUI

/// The two controls of a device's own choice of books (FR45), which the Sync section of Settings shows on the
/// Mac and on the iPhone alike: "Books on this device", with its two choices, and, under "Books you open or
/// keep", the days a book may stay unopened before its download is removed.
///
/// Each control speaks a label, a value, and a hint, and says the new state after every change (the model
/// announces it); a change never moves focus, and the days control appears below the choice, never above it,
/// so nothing VoiceOver is on moves. Shown only while sync is on (R1: nothing is added before a folder is chosen).
struct SyncSpaceControls: View {
    /// The device's settings.
    @ObservedObject var settings: SyncSpaceSettings

    /// The longest wait, which the stepper's last step is.
    private let longestWait = SyncDeviceSettings.longestWait

    var body: some View {
        // The choice is a pop-up that speaks its label and the chosen words as its value.
        Picker(SyncWording.booksOnDeviceLabel, selection: booksBinding) {
            Text(SyncWording.booksOnDeviceAll).tag(BooksOnThisDevice.allBooks)
            Text(SyncWording.booksOnDeviceOpenedOrKept).tag(BooksOnThisDevice.openedOrKept)
        }
        .accessibilityLabel(SyncWording.booksOnDeviceLabel)
        .accessibilityHint(SyncWording.booksOnDeviceHint)

        // The days apply only to "Books you open or keep", so under "All books" there is nothing to set.
        if settings.settings.books == .openedOrKept {
            // 0 is Off, 1 to 30 are days, so the stepper's own arrows, and VoiceOver's adjusting, walk the whole range.
            Stepper(value: daysBinding, in: 0...longestWait) {
                HStack {
                    Text(SyncWording.removeAfterLabel)
                    Spacer()
                    Text(Self.value(of: settings.settings.removeAfterDays))
                }
            }
            .accessibilityLabel(SyncWording.removeAfterLabel)
            .accessibilityValue(Self.value(of: settings.settings.removeAfterDays))
            .accessibilityHint(SyncWording.removeAfterHint)
        }
    }

    /// The choice as a binding, which says the new state when a person changes it.
    private var booksBinding: Binding<BooksOnThisDevice> {
        Binding(get: { settings.settings.books }, set: { settings.setBooks($0) })
    }

    /// The days as a binding, 0 for Off.
    private var daysBinding: Binding<Int> {
        Binding(get: { settings.settings.removeAfterDays ?? 0 }, set: { settings.setRemoveAfterDays($0 == 0 ? nil : $0) })
    }

    /// The days as they are shown and spoken: "Off" or "7 days".
    static func value(of days: Int?) -> String {
        SyncWording.removeAfterValue(days)
    }
}
