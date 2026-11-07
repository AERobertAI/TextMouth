import SwiftUI

// Control styles that exist on the Mac only, under one name for both apps
// (phase 0 of the iOS port). On the Mac each applies exactly the style the
// views used before, so the Mac draws and speaks every control as it did:
// Scripts/ios/mac-projection.py reads each call below as the Mac style it
// stands for. On iOS each falls back to the nearest iOS style.

extension View {
    /// A toggle drawn as a checkbox on the Mac (`.toggleStyle(.checkbox)`),
    /// and as a switch on iOS, which has no checkbox.
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// A picker drawn as a group of radio buttons on the Mac
    /// (`.pickerStyle(.radioGroup)`), and as an inline list on iOS, which has
    /// no radio group.
    func radioGroupPickerStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }
}
