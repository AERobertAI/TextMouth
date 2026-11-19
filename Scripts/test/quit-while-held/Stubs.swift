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

/// What QuitHoldWording reaches of the app's wording (`CountWording.list`):
/// the quit panel's list of what is under way. The probe says it in English,
/// as "a", "a and b", or "a, b, and c".
enum CountWording {
    /// `items` joined in a sentence, in English.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
