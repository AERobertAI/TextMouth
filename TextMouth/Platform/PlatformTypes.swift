// The platform types TextMouth's shared code names, each under one name for
// both apps (phase 0 of the iOS port, IOS-PORT-RESEARCH-2026-11-03.md).
//
// On the Mac each alias is exactly the AppKit type the code always named, so
// the Mac compiles what it did before: Scripts/ios/mac-projection.py reads
// every alias declared here, in its `#if os(macOS)` branch, as its Mac type.
// On iOS each is the UIKit counterpart, which shared code passes along (a
// window is often nil there) to code that only the Mac runs.
//
// An alias is added only when shared code needs the type itself; a call that
// only the Mac makes belongs in `#if os(macOS)` or in TextMouth/Platform/macOS/.
// Keep one alias per line, in the form `typealias PlatformX = NSX`, which the
// projection script reads.

#if os(macOS)
import AppKit

/// A window: AppKit's, on the Mac.
typealias PlatformWindow = NSWindow
/// A font: AppKit's, on the Mac.
typealias PlatformFont = NSFont
/// A view: AppKit's, on the Mac.
typealias PlatformView = NSView
#else
import UIKit

/// A window: UIKit's, on iOS.
typealias PlatformWindow = UIWindow
/// A font: UIKit's, on iOS.
typealias PlatformFont = UIFont
/// A view: UIKit's, on iOS.
typealias PlatformView = UIView
#endif
