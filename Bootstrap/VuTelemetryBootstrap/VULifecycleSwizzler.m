//
//  VULifecycleSwizzler.m
//  VuTelemetryBootstrap
//
//  Method swizzler for AppDelegate lifecycle timing capture
//

#import "VULifecycleSwizzler.h"
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <assert.h>
#import <objc/runtime.h>

#import "StartupTelemetry.h"

#import "VUObjCLogger.h"

#if __has_include(<UIKit/UIKit.h>)

// Internal setters (defined in StartupTelemetry.m)
extern void vu_set_will_finish_launching_begin_ns(uint64_t ns);
extern void vu_set_will_finish_launching_end_ns(uint64_t ns);
extern void vu_set_did_finish_launching_begin_ns(uint64_t ns);
extern void vu_set_did_finish_launching_end_ns(uint64_t ns);
extern void vu_set_scene_connection_begin_ns(uint64_t ns);
extern void vu_set_scene_connection_end_ns(uint64_t ns);

// Type definitions for the original method implementations
typedef BOOL (*AppDelegateMethodIMP)(id, SEL, UIApplication *, NSDictionary *);
typedef void (*SceneDelegateMethodIMP)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *);

// Finding #9: Per-class storage for AppDelegate original IMPs (install phase only).
// These dictionaries are used at swizzle-install time to store the captured IMP per class.
// The hot-path wrappers below do NOT access these dictionaries — they use the cached
// static IMP pointers below instead, which avoids @synchronized overhead on the
// critical path of willFinishLaunching / didFinishLaunching / sceneWillConnect.
static NSMutableDictionary<NSString *, NSValue *> *willFinishOriginalIMPs = nil;
static NSMutableDictionary<NSString *, NSValue *> *didFinishOriginalIMPs = nil;

// Finding #26: Per-class storage for scene delegate original implementations (install phase only).
static NSMutableDictionary<NSString *, NSValue *> *sceneOriginalIMPs = nil;

// Cached IMP pointers for hot-path wrappers.
// Written once at install time (on the main thread, before any lifecycle method fires).
// Read from the wrapper functions which also run on the main thread — no lock needed.
static AppDelegateMethodIMP vu_cached_willFinish_IMP = NULL;
static AppDelegateMethodIMP vu_cached_didFinish_IMP = NULL;
static SceneDelegateMethodIMP vu_cached_sceneWillConnect_IMP = NULL;

// Finding #10: Plain C wrapper functions with correct IMP signature
static BOOL vu_willFinishLaunching_wrapper(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    vu_set_will_finish_launching_begin_ns(mach_absolute_time());
    BOOL result = vu_cached_willFinish_IMP ? vu_cached_willFinish_IMP(self, _cmd, app, opts) : YES;
    vu_set_will_finish_launching_end_ns(mach_absolute_time());
    return result;
}

static BOOL vu_didFinishLaunching_wrapper(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    vu_set_did_finish_launching_begin_ns(mach_absolute_time());
    BOOL result = vu_cached_didFinish_IMP ? vu_cached_didFinish_IMP(self, _cmd, app, opts) : YES;
    vu_set_did_finish_launching_end_ns(mach_absolute_time());
    return result;
}

static void vu_sceneWillConnect_wrapper(id self, SEL _cmd, UIScene *scene,
                                         UISceneSession *session,
                                         UISceneConnectionOptions *connectionOptions) {
    SceneDelegateMethodIMP originalIMP = vu_cached_sceneWillConnect_IMP;
    if (vu_get_scene_connection_begin_ns() == 0) {
        vu_set_scene_connection_begin_ns(mach_absolute_time());
        if (originalIMP) {
            originalIMP(self, @selector(scene:willConnectToSession:options:), scene, session, connectionOptions);
        }
        vu_set_scene_connection_end_ns(mach_absolute_time());
    } else {
        if (originalIMP) {
            originalIMP(self, @selector(scene:willConnectToSession:options:), scene, session, connectionOptions);
        }
    }
}

@implementation VULifecycleSwizzler

// Observer token for the one-shot UISceneWillConnectNotification handler.
// Held so the block can remove itself after the scene delegate class is known.
static id _sceneWillConnectObserverToken = nil;

// Deferred-install replacement for the previous full-process objc_getClassList scan.
//
// Cold-start cost of the old approach: ~240ms on the synchronous setDelegate: path
// (Time Profiler showed objc_getClassList → realizeAllClasses → realizeClassWithoutSwift
// dominating _UIApplicationMainPreparations). The scan was needed only because at
// setDelegate: time we don't yet know the scene delegate class — scene delegates are
// instantiated later by UIApplication from UISceneConfiguration.
//
// Instead, register a one-shot observer for UISceneWillConnectNotification. When the
// first scene connects, notification.object is the UIScene; its .delegate gives us the
// concrete scene delegate class, which we then swizzle for any subsequent scene
// connections in the same process. No process-wide class realization required.
//
// First-scene timing fallback: UISceneWillConnectNotification posts synchronously
// alongside the scene:willConnectToSession:options: call. If the swizzle is too late
// to intercept the first call, scene_connection_begin/end_ns is captured from the
// notification handler itself so the app.start lifecycle event is not lost.
+ (void)installSceneSwizzleObserver {
    if (@available(iOS 13.0, *)) {
        static dispatch_once_t observerOnceToken;
        dispatch_once(&observerOnceToken, ^{
            _sceneWillConnectObserverToken =
                [[NSNotificationCenter defaultCenter] addObserverForName:UISceneWillConnectNotification
                                                                  object:nil
                                                                   queue:nil
                                                              usingBlock:^(NSNotification * _Nonnull note) {
                UIScene *scene = (UIScene *)note.object;
                id sceneDelegate = scene.delegate;
                if (sceneDelegate) {
                    Class sceneClass = [sceneDelegate class];
                    [VULifecycleSwizzler installSceneConnectionOn:sceneClass];
                }

                if (vu_get_scene_connection_begin_ns() == 0) {
                    uint64_t now = mach_absolute_time();
                    vu_set_scene_connection_begin_ns(now);
                    vu_set_scene_connection_end_ns(now);
                }

                // One-shot: remove ourselves once the swizzle is in place.
                if (_sceneWillConnectObserverToken) {
                    [[NSNotificationCenter defaultCenter] removeObserver:_sceneWillConnectObserverToken];
                    _sceneWillConnectObserverToken = nil;
                }
            }];
        });
    }
}

+ (void)installOn:(Class)delegateClass {
    static NSMutableSet<NSString *> *installedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installedClasses = [NSMutableSet new];
        // Finding #9: Initialize per-class IMP dictionaries
        willFinishOriginalIMPs = [NSMutableDictionary new];
        didFinishOriginalIMPs = [NSMutableDictionary new];
    });

    NSString *classKey = [NSString stringWithFormat:@"%p", delegateClass];
    @synchronized(installedClasses) {
        if ([installedClasses containsObject:classKey]) {
            return;
        }
        [installedClasses addObject:classKey];
    }

    [self installWillFinishLaunchingOn:delegateClass];
    [self installDidFinishLaunchingOn:delegateClass];
    [self installSceneSwizzleObserver];

    VU_LOG("[lifecycle] app lifecycle + main() entry will be captured\n");
}

// MARK: - willFinishLaunching Swizzle

+ (void)installWillFinishLaunchingOn:(Class)delegateClass {
    SEL originalSel = @selector(application:willFinishLaunchingWithOptions:);

    Method origMethod = class_getInstanceMethod(delegateClass, originalSel);

    if (origMethod) {
        AppDelegateMethodIMP origIMP = (AppDelegateMethodIMP)method_getImplementation(origMethod);
        NSString *className = [NSString stringWithUTF8String:class_getName(delegateClass)];
        @synchronized(willFinishOriginalIMPs) {
            willFinishOriginalIMPs[className] = [NSValue valueWithPointer:(const void *)origIMP];
        }
        vu_cached_willFinish_IMP = origIMP;

        BOOL added = class_addMethod(delegateClass, originalSel,
                                     (IMP)vu_willFinishLaunching_wrapper,
                                     method_getTypeEncoding(origMethod));
        if (!added) {
            method_setImplementation(origMethod, (IMP)vu_willFinishLaunching_wrapper);
        }
    }
}

// MARK: - didFinishLaunching Swizzle

+ (void)installDidFinishLaunchingOn:(Class)delegateClass {
    SEL originalSel = @selector(application:didFinishLaunchingWithOptions:);

    Method origMethod = class_getInstanceMethod(delegateClass, originalSel);

    if (origMethod) {
        AppDelegateMethodIMP origIMP = (AppDelegateMethodIMP)method_getImplementation(origMethod);
        NSString *className = [NSString stringWithUTF8String:class_getName(delegateClass)];
        @synchronized(didFinishOriginalIMPs) {
            didFinishOriginalIMPs[className] = [NSValue valueWithPointer:(const void *)origIMP];
        }
        vu_cached_didFinish_IMP = origIMP;

        BOOL added = class_addMethod(delegateClass, originalSel,
                                     (IMP)vu_didFinishLaunching_wrapper,
                                     method_getTypeEncoding(origMethod));
        if (!added) {
            method_setImplementation(origMethod, (IMP)vu_didFinishLaunching_wrapper);
        }
    }
}

// MARK: - scene:willConnectToSession:options: Swizzle (iOS 13+)

+ (void)installSceneConnectionOn:(Class)delegateClass {
    if (@available(iOS 13.0, *)) {
        SEL originalSel = @selector(scene:willConnectToSession:options:);

        Method origMethod = class_getInstanceMethod(delegateClass, originalSel);

        if (origMethod) {
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                sceneOriginalIMPs = [NSMutableDictionary new];
            });

            SceneDelegateMethodIMP originalIMP = (SceneDelegateMethodIMP)method_getImplementation(origMethod);
            NSString *className = [NSString stringWithUTF8String:class_getName(delegateClass)];
            // Finding #26: Synchronized access for install-phase dictionary.
            @synchronized(sceneOriginalIMPs) {
                sceneOriginalIMPs[className] = [NSValue valueWithPointer:(const void *)originalIMP];
            }
            // Cache the IMP for direct use in the hot-path wrapper (avoids @synchronized at call time).
            vu_cached_sceneWillConnect_IMP = originalIMP;

            BOOL added = class_addMethod(delegateClass, originalSel,
                                         (IMP)vu_sceneWillConnect_wrapper,
                                         method_getTypeEncoding(origMethod));
            if (!added) {
                method_setImplementation(origMethod, (IMP)vu_sceneWillConnect_wrapper);
            }
        }
    }
}

@end
#endif
