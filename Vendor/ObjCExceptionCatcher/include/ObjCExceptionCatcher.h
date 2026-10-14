// Runs a block and hands back the Objective-C exception it raised, if any.
//
// Swift cannot catch an Objective-C exception, so one raised inside a
// framework call (AVAudioPlayerNode's play, when the Mac's audio output has
// stopped cycling) ends the process. This one C function is the whole of
// the library: Swift calls it through `ObjCException.catching(_:)`.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try`.
///
/// - Returns: The exception the block raised, or nil when it returned
///   normally.
NSException *_Nullable TMCatchException(NS_NOESCAPE void (^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
