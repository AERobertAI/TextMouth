// Phase 0 stand-in: the Mac's OrphanedConversionSweep (Platform/macOS/Services)
// looks, at launch, for afconvert, afinfo and textutil processes that an
// earlier run left behind, kills them, and removes their leftover files.
// iOS apps start no helper programs, so none can be left behind: each sweep
// here does nothing. The names and defaults match the Mac's so AppDelegate
// compiles unchanged.

import Foundation

/// The iOS stand-in for the Mac's launch sweeps: they sweep nothing.
enum OrphanedConversionSweep {
    /// Would kill orphaned afconvert processes; does nothing on iOS.
    static func sweepInBackground() {}

    /// Would kill orphaned afinfo processes and remove their captured output
    /// files; does nothing on iOS.
    static func sweepAfinfoInBackground() {}

    /// Would kill orphaned textutil processes and remove their working
    /// folders; does nothing on iOS.
    static func sweepTextutilInBackground() {}
}
