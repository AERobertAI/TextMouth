import Foundation

extension PhoneExportMemoryCheck {
    /// The guard an export on the iPhone is asked before it converts a book's
    /// text: the memory the app has left now (`SessionMemoryFloor.app`, which
    /// reads `os_proc_available_memory()` and knows the simulator's 0 for no
    /// limit and a phone's 0 for an app over its limit), against what the
    /// conversion is estimated to hold (`check(textBytes:availableBytes:)`).
    static let live: BookExportMemoryGuard = { writerID, textBytes in
        // Nil where the system sets the app no limit; never negative.
        let left = SessionMemoryFloor.app.left.map { UInt64(max(0, $0)) }
        try check(writerID: writerID, textBytes: textBytes, availableBytes: left)
    }
}
