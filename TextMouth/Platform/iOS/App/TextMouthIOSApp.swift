import SwiftUI

/// TextMouth's iOS app, as phase 0 of the port leaves it
/// (IOS-PORT-RESEARCH-2026-11-03.md): one screen saying that the iPhone app
/// is still being built. Phase 0 makes the shared engine compile in this
/// target, with the Mac app unchanged; phase 1 builds the iPhone's own
/// interface on that engine, and this screen goes.
@main
struct TextMouthIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSPlaceholderView()
        }
    }
}

/// The placeholder screen: the app's name as a heading, then one sentence,
/// both read by VoiceOver in that order.
struct IOSPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("TextMouth")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("The iPhone app is still being built. For now, listen with TextMouth on your Mac.")
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
