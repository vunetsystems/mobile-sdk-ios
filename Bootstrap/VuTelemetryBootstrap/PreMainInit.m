//
//  PreMainInit.m
//  VuTelemetryBootstrap
//
//  Zero-touch pre-main instrumentation using fishhook UIApplicationMain interception
//  Captures static_initializers.begin and .end without requiring app-level changes
//

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdatomic.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VULifecycleSwizzler.h"
#import "StartupTelemetry.h"
#import "GhostCrash/GhostCrashInterceptor.h"
#import "DylibProfiler.h"
#include "fishhook.h"

#import "VUObjCLogger.h"

// MARK: - Global Timing Anchors

// These globals are now statically defined in StartupTelemetry.m.
// We declare them as extern here to write to them during pre-main.
// Swift accesses them only via vu_get_*() accessor functions.

extern void vu_set_process_start_ns(uint64_t ns);
extern void vu_set_dylib_loaded_end_mach(uint64_t ticks);
extern void vu_set_static_init_begin_ns(uint64_t ns);
extern void vu_set_static_init_end_ns(uint64_t ns);
extern uint64_t vu_get_static_init_end_ns(void);
extern void vu_set_pre_sdk_static_init_end_ns(uint64_t ns);
extern void vu_set_main_entry_ns(uint64_t ticks);
extern void vu_set_ui_application_delegate_assigned_ns(uint64_t ticks);
extern void vu_set_otel_sdk_init_begin_ns(uint64_t ns);
extern void vu_set_is_prewarmed(BOOL value);

// Finding #24: Use atomics for thread safety with post-main dyld callbacks
static _Atomic uint32_t vu_image_callback_count = 0;
static _Atomic BOOL vu_initial_dylib_scan_complete = NO;

uint32_t vu_get_dylib_image_count(void) {
    return atomic_load(&vu_image_callback_count);
}

// MARK: - dyld Image Callback

/// Called for each dylib loaded. Last call marks end of dylib loading phase.
static void vuOnImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh;
    (void)vmaddr_slide;

    uint64_t current_ticks = mach_absolute_time();

#if DEBUG
    if (vu_dylib_profiler_record_count() < VU_DYLIB_PROFILER_MAX_DYLIBS) {
        // Use _dyld_get_image_name instead of dladdr — dladdr acquires dyld's internal
        // locks and causes deadlocks + ~1-3ms overhead inside the add-image callback.
        uint32_t idx = atomic_load(&vu_image_callback_count);
        const char *dylib_path = _dyld_get_image_name(idx);
        if (!dylib_path) dylib_path = "<unknown>";
        vu_dylib_profiler_on_image_added(dylib_path, current_ticks);
    }
#endif

    if (!atomic_load(&vu_initial_dylib_scan_complete)) {
        vu_set_dylib_loaded_end_mach(current_ticks);
    }
    atomic_fetch_add(&vu_image_callback_count, 1);
}

// MARK: - UIApplication Delegate Interception Helper

static void vu_custom_setDelegate(id self, SEL _cmd, id delegate) {
    if (vu_get_ui_application_delegate_assigned_ns() == 0) {
        // Detect prewarm status before emitting the first log so the banner is accurate.
        NSString *prewarmFlag = NSProcessInfo.processInfo.environment[@"ActivePrewarm"];
        BOOL isPrewarmed = [prewarmFlag isEqualToString:@"1"];
        vu_set_is_prewarmed(isPrewarmed);

        VU_LOG("[startup] vuTelemetry loaded — %s start, %sprewarmed\n",
               isPrewarmed ? "warm" : "cold",
               isPrewarmed ? "" : "not ");

        // Install all instrumentation hooks and activate the buffering TracerProvider
        // synchronously before any app code runs. Must precede the async OTel bootstrap
        // so spans produced during scene:willConnectToSession are captured.
        Class hooksClass = objc_getClass("VUInstrumentationHooks");
        if (hooksClass == Nil) {
            hooksClass = NSClassFromString(@"vuTelemetry.VUInstrumentationHooks");
        }
        if (hooksClass != Nil) {
            SEL installAllSel = sel_registerName("installAll");
            if ([hooksClass respondsToSelector:installAllSel]) {
                ((void (*)(id, SEL))objc_msgSend)(hooksClass, installAllSel);
            }
        } else {
            VU_LOG("[startup] instrumentation hooks class not found — hooks not installed\n");
        }

        // Constructor(201) has already run by now, so begin boundary is available.
        vu_dispatch_bootstrap_selector(NSSelectorFromString(@"preMainInitializeFromInfoPlist"), "setDelegate hook");

        uint64_t delegateAssignedMach = mach_absolute_time();
        vu_set_ui_application_delegate_assigned_ns(delegateAssignedMach);

#if DEBUG
        vu_dylib_profiler_end_phase(delegateAssignedMach);
#endif

        ghost_crash_set_phase(GhostCrashPhaseMain);
        vu_resolve_pre_main_thermal_state();

#if DEBUG
        if ([VUObjCLogger exportDebugLogsEnabled]) {
            vu_dylib_profiler_report();
        }
#endif
    }
    
    // Install lifecycle method swizzles on the concrete delegate class
    if (delegate) {
        Class delegateClass = [delegate class];
        [VULifecycleSwizzler installOn:delegateClass];
    }

    // Call original implementation by invoking the exchanged selector
    SEL replacementSel = sel_registerName("vu_custom_setDelegate:");
    ((void (*)(id, SEL, id))objc_msgSend)(self, replacementSel, delegate);
}

static void vuInstallUIApplicationSwizzle(void) {
    static BOOL swizzleInstalled = NO;
    if (swizzleInstalled) {
        return;
    }

    Class cls = objc_getClass("UIApplication");
    if (cls == Nil) {
        cls = NSClassFromString(@"UIApplication");
    }

    if (cls != Nil) {
        SEL originalSel = sel_registerName("setDelegate:");
        SEL replacementSel = sel_registerName("vu_custom_setDelegate:");
        Method originalMethod = class_getInstanceMethod(cls, originalSel);
        if (originalMethod != NULL) {
            BOOL added = class_addMethod(cls, replacementSel, (IMP)vu_custom_setDelegate, method_getTypeEncoding(originalMethod));
            if (added) {
                Method replacementMethod = class_getInstanceMethod(cls, replacementSel);
                if (replacementMethod != NULL) {
                    method_exchangeImplementations(originalMethod, replacementMethod);
                    swizzleInstalled = YES;
                }
            } else {
                VU_LOG("[startup] setDelegate swizzle install failed — hook not added to UIApplication\n");
            }
        } else {
            VU_LOG("[startup] UIApplication setDelegate method not found — delegate hook skipped\n");
        }
    } else {
        VU_LOG("[startup] UIApplication class not found — delegate hook skipped\n");
    }
}

// MARK: - main() Entry Point Capture via fishhook

typedef int (*main_t)(int argc, char *argv[]);
static main_t original_main = NULL;

// Finding #19: Minimize work before calling original_main
static int vu_hooked_main(int argc, char *argv[]) {
    vu_set_main_entry_ns(mach_absolute_time());
    return original_main(argc, argv);
}

static void vuInstallMainHook(void) {
    struct rebinding rb[] = {{"main", (void *)vu_hooked_main, (void **)&original_main}};
    rebind_symbols(rb, 1);
}

// MARK: - VUPreMainProbe: +load Registration

@interface VUPreMainProbe : NSObject
@end

@implementation VUPreMainProbe

+ (void)load {
#if DEBUG
    vu_dylib_profiler_start();
#endif

    _dyld_register_func_for_add_image(&vuOnImageAdded);
#if DEBUG
    vu_dylib_profiler_mark_replay_complete();
#endif
    atomic_store(&vu_initial_dylib_scan_complete, YES);

    vuInstallMainHook();
    vuInstallUIApplicationSwizzle();
}

@end

// Safety fallback swizzling installation in constructor
__attribute__((constructor(102)))
static void vuPreMainInitSwizzle(void) {
    vuInstallUIApplicationSwizzle();
}

// MARK: - Constructor: Capture Process Start

__attribute__((constructor(101)))
static void vuCaptureProcessStart(void) {
    // Capture wall-clock time and mach time simultaneously
    uint64_t wallClockAtProcessStartNs = vu_get_current_time_ns();
    uint64_t machTimeAtProcessStart = mach_absolute_time();
    vu_set_wall_clock_at_process_start_ns(wallClockAtProcessStartNs);
    vu_set_mach_time_at_process_start(machTimeAtProcessStart);
    
    // Get kernel process start time (wall-clock)
    vu_set_process_start_ns(vu_get_kernel_process_start_ns());
    
    // Static init begin is this constructor boundary (start of static initializers phase).
    // Dylib loading end is captured separately via dyld image callbacks and should precede this.
    uint64_t dylibLoadedEnd = vu_get_dylib_loaded_end_mach();
    uint64_t staticInitBeginMach = machTimeAtProcessStart;
    vu_set_static_init_begin_ns(vu_mach_time_to_unix_nanos(staticInitBeginMach));
    
    if (dylibLoadedEnd == 0) {
        vu_set_dylib_loaded_end_mach(mach_absolute_time());
    }

    uint64_t normalizedDylibEndMach = vu_get_dylib_loaded_end_mach();
    if (normalizedDylibEndMach >= staticInitBeginMach) {
        vu_set_dylib_loaded_end_mach(staticInitBeginMach);
    }

    VU_LOG("[startup] Pre-main monitors active — dylib loading, static initializers, and OTel SDK init boundary will be captured (%u images loaded)\n",
           vu_image_callback_count);

    // Capture and store Stage 1 metrics
    VUStage1Metrics stage1 = vu_capture_pre_main_metrics();
    vu_set_stage1_metrics(stage1);

    // Update GhostCrash time anchors so signal handler can convert mach ticks signal-safely
    ghost_crash_update_time_anchors(machTimeAtProcessStart, wallClockAtProcessStartNs);
}

// MARK: - Constructor(199): Mark Pre-SDK Static Initializer End
// 
// This constructor runs between Constructor(101) and Constructor(201).
// It captures what happened between our bootstrap anchor and SDK init.
// Typically: third-party +load methods, Swift module initializers, etc.

__attribute__((constructor(199)))
static void vuMarkPreSDKStaticInitEnd(void) {
    uint64_t preSDKEndMach = mach_absolute_time();
    vu_set_pre_sdk_static_init_end_ns(preSDKEndMach);
}

// MARK: - Constructor(201): Mark OTel SDK Initialization Begin

__attribute__((constructor(201)))
static void vuMarkOtelSdkInitBegin(void) {
    // This constructor runs after priority 101 (which captures process_start),
    // but before the Swift runtime initializes (typically priority 9xx).
    // 
    // Everything from here until markOtelSdkInitEnd() is called is attributed
    // to OTel SDK initialization cost.
    uint64_t otelBeginMach = mach_absolute_time();
    vu_set_otel_sdk_init_begin_ns(otelBeginMach);
    uint64_t anchorMach = vu_get_mach_time_at_process_start();
    int64_t delta = (int64_t)otelBeginMach - (int64_t)anchorMach;
#if DEBUG
    assert(anchorMach > 0 && "Constructor(101) anchor must be captured before Constructor(201)");
    assert(delta >= 0 && "OTel SDK init begin must not precede Constructor(101) mach anchor");
#endif
}

// MARK: - UIApplicationMain Interception Helper

// Finding #22: Guard against redundant execution when both code paths fire.
// NOTE: Only called from vu_hooked_main (fishhook). For SwiftUI @main apps the Swift
// compiler generates main() without C linkage — fishhook never fires, so this function
// is unreachable in SwiftUI apps. refreshStaticInitAnchors() falls back to
// vu_ui_application_delegate_assigned_ns in that case (see StartupTelemetry.m).
void vu_capture_main_entry_and_prewarm(void) {
    static BOOL already_called = NO;
    if (already_called) return;
    already_called = YES;

    if (vu_get_static_init_end_ns() == 0) {
        vu_set_static_init_end_ns(vu_mach_time_to_unix_nanos(mach_absolute_time()));
    }
    ghost_crash_set_phase(GhostCrashPhaseMain);
    vu_resolve_pre_main_thermal_state();
}



