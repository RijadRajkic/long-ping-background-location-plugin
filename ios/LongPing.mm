#import "LongPing.h"

#import <UIKit/UIKit.h>

// Static library builds expose the generated header by file name; static/dynamic frameworks by module path.
#if __has_include(<LongPing/LongPing-Swift.h>)
#import <LongPing/LongPing-Swift.h>
#else
#import "LongPing-Swift.h"
#endif

static NSString *const LPErrorInternal = @"INTERNAL";

typedef void (^LPEngineCompletion)(id _Nullable result, NSString *_Nullable code, NSString *_Nullable message);

/// Engine completion → promise. A non-nil code rejects with that DESIGN.md error code.
static LPEngineCompletion LPSettle(RCTPromiseResolveBlock resolve, RCTPromiseRejectBlock reject)
{
  return ^(id _Nullable result, NSString *_Nullable code, NSString *_Nullable message) {
    if (code != nil) {
      reject(code, message ?: code, nil);
    } else {
      resolve(result);
    }
  };
}

/// Last line of defence for the host app: an Objective-C exception thrown synchronously while handing a
/// call to the engine becomes an INTERNAL rejection instead of a crash.
static void LPRun(RCTPromiseRejectBlock reject, void (^NS_NOESCAPE body)(void))
{
  @try {
    body();
  } @catch (NSException *exception) {
    reject(LPErrorInternal, exception.reason ?: exception.name, nil);
  }
}

@implementation LongPing

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

#pragma mark - Events

- (NSArray<NSString *> *)supportedEvents
{
  return @[
    @"location",
    @"motionchange",
    @"http",
    @"providerchange",
    @"authorization",
    @"enabledchange",
    @"configchange",
    @"error",
  ];
}

// RCTEventEmitter calls these on the first listener added / last removed, so the engine only emits
// while JS is listening (nothing is buffered).
- (void)startObserving
{
  __weak LongPing *weakSelf = self;
  [LongPingEngine.shared setEventSink:^(NSString *name, NSDictionary<NSString *, id> *body) {
    [weakSelf sendEventWithName:name body:body];
  }
                                owner:self];
}

- (void)stopObserving
{
  [LongPingEngine.shared removeEventSinkForOwner:self];
}

- (void)invalidate
{
  [LongPingEngine.shared removeEventSinkForOwner:self];
  [super invalidate];
}

#pragma mark - NativeLongPingSpec

- (void)configure:(NSDictionary *)config resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared configure:config completion:LPSettle(resolve, reject)];
  });
}

- (void)setConfig:(NSDictionary *)config resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared setConfig:config completion:LPSettle(resolve, reject)];
  });
}

- (void)start:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared startWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)stop:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared stopWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)getState:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared getStateWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)setAuthorization:(NSDictionary *)auth resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared setAuthorization:auth completion:LPSettle(resolve, reject)];
  });
}

- (void)clearAuthorization:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared clearAuthorizationWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)getCurrentPosition:(NSDictionary *)options
                   resolve:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared getCurrentPosition:options completion:LPSettle(resolve, reject)];
  });
}

- (void)changePace:(BOOL)isMoving resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared changePace:isMoving completion:LPSettle(resolve, reject)];
  });
}

- (void)sync:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared syncWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)getQueueCount:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared getQueueCountWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)clearQueue:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared clearQueueWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)getProviderState:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared getProviderStateWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)requestPermission:(NSString *)level resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared requestPermission:level completion:LPSettle(resolve, reject)];
  });
}

// Android-only concepts; iOS answers per DESIGN.md.
- (void)isIgnoringBatteryOptimizations:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@YES);
}

- (void)requestIgnoreBatteryOptimizations:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@NO);
}

- (void)openPowerManagerSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@NO);
}

- (void)openAppSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared openAppSettingsWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)openLocationSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared openLocationSettingsWithCompletion:LPSettle(resolve, reject)];
  });
}

- (void)getLog:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared getLog:options completion:LPSettle(resolve, reject)];
  });
}

- (void)clearLog:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  LPRun(reject, ^{
    [LongPingEngine.shared clearLogWithCompletion:LPSettle(resolve, reject)];
  });
}

// addListener: and removeListeners: are inherited from RCTEventEmitter.

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeLongPingSpecJSI>(params);
}

@end

#pragma mark - Launch resume

@interface LongPing (LaunchResume)
@end

@implementation LongPing (LaunchResume)

// RCT_EXPORT_MODULE() already defines +load on the class; the runtime calls a category's +load as well.
// Tracking must resume at every launch, including background relaunches by region or significant-change
// monitoring, without waiting for JavaScript.
+ (void)load
{
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *_Nonnull notification) {
                                                  @try {
                                                    [LongPingEngine.shared resumeIfEnabled];
                                                  } @catch (NSException *exception) {
                                                    NSLog(@"[LongPing] resume failed: %@", exception);
                                                  }
                                                }];
}

@end
