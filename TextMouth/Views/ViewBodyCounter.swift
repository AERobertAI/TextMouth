import Foundation

/// Counts how many times SwiftUI evaluates the bodies of the views that
/// record themselves here, by name, so the hosted tests can check how much
/// of the interface one publish redraws: a list and its rows, a reader's
/// sheets, a settings pane (PERF27, PERF28, PERF30).
///
/// A view records itself on the first line of its body,
/// `let _ = ViewBodyCounter.record("BookRow")`. Debug builds, which the
/// hosted tests run, keep the counts; release builds compile every call to
/// nothing, so the app pays for none of it.
@MainActor
enum ViewBodyCounter {
    #if DEBUG
    /// Body evaluations so far, by the name each view records.
    private static var counts: [String: Int] = [:]
    #endif

    /// Notes one evaluation of the body of the view called `name`.
    @inline(__always)
    static func record(_ name: String) {
        #if DEBUG
        counts[name, default: 0] += 1
        #endif
    }

    /// How many times the body of the view called `name` has been evaluated
    /// in this process: always 0 in a release build.
    static func count(of name: String) -> Int {
        #if DEBUG
        return counts[name, default: 0]
        #else
        return 0
        #endif
    }
}
