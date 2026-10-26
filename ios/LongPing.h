#import <React/RCTEventEmitter.h>

// The codegen spec header is Objective-C++ only. Keep this header importable from plain Objective-C
// (the podspec also marks it private so Swift's module import never sees it).
#ifdef __cplusplus
#import <LongPingSpec/LongPingSpec.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// TurboModule "LongPing": a thin forwarder to the Swift `LongPingEngine`, which owns all behaviour.
#ifdef __cplusplus
@interface LongPing : RCTEventEmitter <NativeLongPingSpec>
#else
@interface LongPing : RCTEventEmitter
#endif
@end

NS_ASSUME_NONNULL_END
