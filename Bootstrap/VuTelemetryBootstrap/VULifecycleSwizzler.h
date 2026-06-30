//
//  VULifecycleSwizzler.h
//  VuTelemetryBootstrap
//
//  Method swizzler for AppDelegate lifecycle timing capture
//  Installs swizzles on the concrete delegate class to capture:
//    - applicationWillFinishLaunchingWithOptions:
//    - applicationDidFinishLaunchingWithOptions:
//    - scene:willConnectToSession:options: (iOS 13+)
//

#ifndef VULifecycleSwizzler_h
#define VULifecycleSwizzler_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs lifecycle method swizzles on a concrete AppDelegate class
/// Called from setDelegate: hook after the delegate instance is assigned
@interface VULifecycleSwizzler : NSObject
+ (void)installOn:(Class)delegateClass;
@end

NS_ASSUME_NONNULL_END

#endif /* VULifecycleSwizzler_h */
