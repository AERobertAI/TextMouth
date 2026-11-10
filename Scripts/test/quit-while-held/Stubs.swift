// Stand-in for the one app type the quit code reaches (TextMouthRuntime), so
// App/QuitRequest.swift, App/QuitHold.swift, and App/QuitFinisher.swift
// compile into the probe unchanged, as the app's real sources.
//
// The probe is its own process, never a test host, so it really quits.

/// What QuitRequest asks of the app's runtime: whether this process hosts
/// tests. The probe does not.
struct TextMouthRuntime {
    /// The probe's runtime.
    static let current = TextMouthRuntime()
    /// Never: the probe really asks AppKit to quit.
    let isHostedTest = false
}
