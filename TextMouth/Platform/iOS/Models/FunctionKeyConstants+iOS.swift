// Phase 0 stand-in: AppKit's NSEvent.h function-key constants, which UIKit lacks. The Mac uses AppKit's own; iOS declares the same names with the same values so config.json's key names (pageDown, f5, …) mean the same on both.
//
// Each constant is the private-use Unicode character AppKit gives the key,
// as `Int`, exactly as AppKit imports them into Swift. Only the shared
// shortcut model (`KeyBinding.functionKeys`) reads them. The Mac never
// compiles this file.

// The arrow keys.
let NSUpArrowFunctionKey: Int = 0xF700
let NSDownArrowFunctionKey: Int = 0xF701
let NSLeftArrowFunctionKey: Int = 0xF702
let NSRightArrowFunctionKey: Int = 0xF703

// The function keys F1 to F35, in a row from F1's character.
let NSF1FunctionKey: Int = 0xF704
let NSF2FunctionKey: Int = 0xF705
let NSF3FunctionKey: Int = 0xF706
let NSF4FunctionKey: Int = 0xF707
let NSF5FunctionKey: Int = 0xF708
let NSF6FunctionKey: Int = 0xF709
let NSF7FunctionKey: Int = 0xF70A
let NSF8FunctionKey: Int = 0xF70B
let NSF9FunctionKey: Int = 0xF70C
let NSF10FunctionKey: Int = 0xF70D
let NSF11FunctionKey: Int = 0xF70E
let NSF12FunctionKey: Int = 0xF70F
let NSF13FunctionKey: Int = 0xF710
let NSF14FunctionKey: Int = 0xF711
let NSF15FunctionKey: Int = 0xF712
let NSF16FunctionKey: Int = 0xF713
let NSF17FunctionKey: Int = 0xF714
let NSF18FunctionKey: Int = 0xF715
let NSF19FunctionKey: Int = 0xF716
let NSF20FunctionKey: Int = 0xF717
let NSF21FunctionKey: Int = 0xF718
let NSF22FunctionKey: Int = 0xF719
let NSF23FunctionKey: Int = 0xF71A
let NSF24FunctionKey: Int = 0xF71B
let NSF25FunctionKey: Int = 0xF71C
let NSF26FunctionKey: Int = 0xF71D
let NSF27FunctionKey: Int = 0xF71E
let NSF28FunctionKey: Int = 0xF71F
let NSF29FunctionKey: Int = 0xF720
let NSF30FunctionKey: Int = 0xF721
let NSF31FunctionKey: Int = 0xF722
let NSF32FunctionKey: Int = 0xF723
let NSF33FunctionKey: Int = 0xF724
let NSF34FunctionKey: Int = 0xF725
let NSF35FunctionKey: Int = 0xF726

// Editing and navigation keys, in the header's order.
let NSInsertFunctionKey: Int = 0xF727
let NSDeleteFunctionKey: Int = 0xF728
let NSHomeFunctionKey: Int = 0xF729
let NSBeginFunctionKey: Int = 0xF72A
let NSEndFunctionKey: Int = 0xF72B
let NSPageUpFunctionKey: Int = 0xF72C
let NSPageDownFunctionKey: Int = 0xF72D
let NSPrintScreenFunctionKey: Int = 0xF72E
let NSScrollLockFunctionKey: Int = 0xF72F
let NSPauseFunctionKey: Int = 0xF730
let NSSysReqFunctionKey: Int = 0xF731
let NSBreakFunctionKey: Int = 0xF732
let NSResetFunctionKey: Int = 0xF733
let NSStopFunctionKey: Int = 0xF734
let NSMenuFunctionKey: Int = 0xF735
let NSUserFunctionKey: Int = 0xF736
let NSSystemFunctionKey: Int = 0xF737
let NSPrintFunctionKey: Int = 0xF738
let NSClearLineFunctionKey: Int = 0xF739
let NSClearDisplayFunctionKey: Int = 0xF73A
let NSInsertLineFunctionKey: Int = 0xF73B
let NSDeleteLineFunctionKey: Int = 0xF73C
let NSInsertCharFunctionKey: Int = 0xF73D
let NSDeleteCharFunctionKey: Int = 0xF73E
let NSPrevFunctionKey: Int = 0xF73F
let NSNextFunctionKey: Int = 0xF740
let NSSelectFunctionKey: Int = 0xF741
let NSExecuteFunctionKey: Int = 0xF742
let NSUndoFunctionKey: Int = 0xF743
let NSRedoFunctionKey: Int = 0xF744
let NSFindFunctionKey: Int = 0xF745
let NSHelpFunctionKey: Int = 0xF746
let NSModeSwitchFunctionKey: Int = 0xF747
