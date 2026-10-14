// See ObjCExceptionCatcher.h.

#import "ObjCExceptionCatcher.h"

NSException *_Nullable TMCatchException(NS_NOESCAPE void (^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        // The exception a framework raised, handed to the caller to act on.
        return exception;
    }
}
