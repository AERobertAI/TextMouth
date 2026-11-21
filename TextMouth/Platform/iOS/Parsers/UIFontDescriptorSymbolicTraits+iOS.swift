// Phase 0 stand-in: AppKit's NSFontDescriptor.SymbolicTraits names its bold
// and italic traits `.bold` and `.italic`; UIKit's UIFontDescriptor.SymbolicTraits
// calls them `.traitBold` and `.traitItalic`. The PDF reader asks a font for
// `fontDescriptor.symbolicTraits.contains(.bold)` and `.italic`, text the Mac
// keeps exactly as it was. This gives iOS the same two names, so that text
// compiles there unchanged. Nothing on the Mac uses this file.

import UIKit

extension UIFontDescriptor.SymbolicTraits {
    /// The bold trait, under the name AppKit gives it.
    static let bold = UIFontDescriptor.SymbolicTraits.traitBold
    /// The italic trait, under the name AppKit gives it.
    static let italic = UIFontDescriptor.SymbolicTraits.traitItalic
}
