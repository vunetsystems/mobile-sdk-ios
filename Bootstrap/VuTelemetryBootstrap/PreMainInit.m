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
    // First delegate assignment occurs inside UIApplicationMain after pre-main.
    // Trigger bootstrap init first so otel_sdk_init_end is captured before
    // the pre-main boundary closes.
    if (vu_get_ui_application_delegate_assigned_ns() == 0) {
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
                VU_LOG( "[vuTelemetry] VUInstrumentationHooks.installAll() completed\n");
            }
        } else {
            VU_LOG( "[vuTelemetry] VUInstrumentationHooks class not found — hooks not installed\n");
        }

        // Constructor(201) has already run by now, so begin boundary is available.
        vu_dispatch_bootstrap_selector(NSSelectorFromString(@"preMainInitializeFromInfoPlist"), "setDelegate hook");

        // Capture the moment UIApplication setDelegate is called (for reference, post-main)
        uint64_t delegateAssignedMach = mach_absolute_time();
        uint64_t delegateAssignedNs = vu_mach_time_to_unix_nanos(delegateAssignedMach);
        vu_set_ui_application_delegate_assigned_ns(delegateAssignedMach);
        
#if DEBUG
        // Mark end of dylib profiling phase
        vu_dylib_profiler_end_phase(delegateAssignedMach);
#endif

        // Signal entry to main() phase
        ghost_crash_set_phase(GhostCrashPhaseMain);

        NSString *prewarmFlag = NSProcessInfo.processInfo.environment[@"ActivePrewarm"];
        vu_set_is_prewarmed([prewarmFlag isEqualToString:@"1"]);

        // Resolve thermal state for stage 1 metrics since we are post-main now
        vu_resolve_pre_main_thermal_state();

        VU_LOG( "[vuTelemetry] ui_application_delegate_assigned captured: %llu (image_count=%u prewarmed=%d)\n",
                delegateAssignedNs, vu_image_callback_count, [prewarmFlag isEqualToString:@"1"]);
        
#if DEBUG
        // Dump dylib profiling report
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
                    VU_LOG( "[vuTelemetry] UIApplication setDelegate hook installed dynamically via exchange\n");
                }
            } else {
                VU_LOG( "[vuTelemetry] Failed to add vu_custom_setDelegate: method dynamically\n");
            }
        } else {
            VU_LOG( "[vuTelemetry] UIApplication setDelegate method not found dynamically\n");
        }
    } else {
        VU_LOG( "[vuTelemetry] UIApplication class not found dynamically\n");
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
    VU_LOG( "[vuTelemetry] main() hook installed via fishhook\n");
}

// MARK: - VUPreMainProbe: +load Registration

@interface VUPreMainProbe : NSObject
@end

@implementation VUPreMainProbe

+ (void)load {
#if DEBUG
    // Start dylib profiler early — debug only; skipped in release to avoid per-image overhead
    vu_dylib_profiler_start();
    VU_LOG( "[vuTelemetry] dylib profiler enabled\n");
#endif

    // Register dyld image callback for timing anchors (always) and profiling (debug only).
    // NOTE: _dyld_register_func_for_add_image backfills all already-loaded images synchronously,
    // so the callback must be as lightweight as possible in release builds.
    _dyld_register_func_for_add_image(&vuOnImageAdded);
#if DEBUG
    // Finding #12: Mark replay phase complete so post-registration callbacks are flagged correctly
    vu_dylib_profiler_mark_replay_complete();
#endif
    atomic_store(&vu_initial_dylib_scan_complete, YES);
    VU_LOG( "[vuTelemetry] dyld image callback registered from +load\n");

    // Install main() hook to capture true end of static initializers
    vuInstallMainHook();

    // Attempt to install swizzle at +load
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
    
    // Fallback if dylib callbacks haven't fired (on simulator with cached dylibs)
    if (dylibLoadedEnd == 0) {
        vu_set_dylib_loaded_end_mach(mach_absolute_time());
        VU_LOG( "[VuTelemetry] ⚠️ dylib_loaded_end fallback (cached images?) — callbacks: %u\n",
                vu_image_callback_count);
    } else {
        VU_LOG( "[VuTelemetry] dylib_loaded_end captured after %u images: %llu mach ticks, wall: %llu ns\n",
                vu_image_callback_count, dylibLoadedEnd, vu_get_static_init_begin_ns());
    }

    // Finding #17: Use constructor timestamp as the boundary instead of fabricating a -1 offset
    uint64_t normalizedDylibEndMach = vu_get_dylib_loaded_end_mach();
    if (normalizedDylibEndMach >= staticInitBeginMach) {
        vu_set_dylib_loaded_end_mach(staticInitBeginMach);
        normalizedDylibEndMach = staticInitBeginMach;
        VU_LOG("[VuTelemetry] dylib_loaded_end clamped to static_init_begin (dyld and static init overlap)\n");
    }
    
    VU_LOG( "[VuTelemetry] Constructor(101) captured: process_start=%llu, static_init_begin=%llu\n",
            vu_get_kernel_process_start_ns(), vu_get_static_init_begin_ns());

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
    VU_LOG( "[VuTelemetry] Constructor(199) captured pre-SDK static init end: %llu mach ticks\n", preSDKEndMach);
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
    VU_LOG( "[VuTelemetry] Constructor(201) marked OTel SDK init begin: mach=%llu anchor=%llu delta=%lld\n",
            otelBeginMach, anchorMach, delta);
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



