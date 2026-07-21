//
//  StartupTelemetry.m
//  VuTelemetryBootstrap
//
//  Implementation of lightweight pre-main startup telemetry
//

#import "StartupTelemetry.h"
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>
#include <stdio.h>
#include <assert.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/param.h>
#import <sys/mount.h>

#import "VUObjCLogger.h"

// MARK: - Static Timing Globals
// All timing anchors are private to this file and accessible only via
// the public accessor functions. This eliminates Swift 6 concurrency warnings
// since Swift never directly accesses these globals.

/// Process start time (wall-clock Unix nanoseconds from kernel sysctl)
static uint64_t vu_process_start_ns = 0;

/// End of dylib loading (raw mach_absolute_time ticks — NOT nanoseconds)
static uint64_t vu_dylib_loaded_end_mach = 0;

/// Anchor pair captured atomically in Constructor(101)
static uint64_t vu_wall_clock_at_process_start_ns = 0;
static uint64_t vu_mach_time_at_process_start = 0;

/// Start of static initializers (mach_absolute_time ticks)
static uint64_t vu_static_init_begin_ns = 0;

/// End of static initializers (mach_absolute_time ticks) — DEPRECATED, use vu_main_entry_ns
static uint64_t vu_static_init_end_ns = 0;

/// Pre-SDK static initializer end — Constructor(199) boundary (mach_absolute_time ticks)
static uint64_t vu_pre_sdk_static_init_end_ns = 0;

/// Main function entry (mach_absolute_time ticks) — TRUE end of static initializers
static uint64_t vu_main_entry_ns = 0;

/// UIApplication setDelegate hook called (mach_absolute_time ticks)
static uint64_t vu_ui_application_delegate_assigned_ns = 0;

/// OTel SDK initialization begin (mach_absolute_time ticks)
static uint64_t vu_otel_sdk_init_begin_ns = 0;

/// OTel SDK initialization end (mach_absolute_time ticks)
static uint64_t vu_otel_sdk_init_end_ns = 0;

/// iOS 15+ pre-warming detection flag
static BOOL vu_is_prewarmed = NO;

/// AppDelegate lifecycle timestamps (mach_absolute_time ticks)
static uint64_t vu_will_finish_launching_begin_ns = 0;
static uint64_t vu_will_finish_launching_end_ns = 0;
static uint64_t vu_did_finish_launching_begin_ns = 0;
static uint64_t vu_did_finish_launching_end_ns = 0;
static uint64_t vu_scene_connection_begin_ns = 0;
static uint64_t vu_scene_connection_end_ns = 0;

@interface StartupTelemetry ()
@property (nonatomic, assign) uint64_t machProcessStartTime;
@property (nonatomic, assign) mach_timebase_info_data_t timebaseInfo;
@end

// Finding #20: Removed dead code VUConvertMachToUnixNanos

@implementation StartupTelemetry

// Finding #23: Use dispatch_once for thread-safe singleton
+ (instancetype)sharedInstance {
    static StartupTelemetry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[StartupTelemetry alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize timebase info
        mach_timebase_info(&_timebaseInfo);
        
        // Default fallback anchor for conversion if pre-main anchor is unavailable.
        _machProcessStartTime = mach_absolute_time();
        
        // Query kernel for process start time
        _processStartNs = [self processStartTimeFromKernel];

        // Prefer constructor-captured anchor for conversions when present.
        if (vu_mach_time_at_process_start > 0) {
            _machProcessStartTime = vu_mach_time_at_process_start;
        }

        [self refreshStaticInitAnchors];
    }
    return self;
}

- (void)refreshStaticInitAnchors {
    // The global anchors are populated by PreMainInit constructors/+load
    // We just convert them and expose them via this object
    
    if (vu_process_start_ns > 0) {
        self.processStartNs = vu_process_start_ns;
    }

    if (vu_dylib_loaded_end_mach > 0) {
        self.dylibLoadedEndMach = vu_dylib_loaded_end_mach;
    }

    // staticInitBeginNs is already in wall-clock nanoseconds from PreMainInit
    if (vu_static_init_begin_ns > 0) {
        self.staticInitBeginNs = vu_static_init_begin_ns;
    }

    // staticInitEndNs is already wall-clock nanoseconds — converted at capture time
    // in vu_setDelegate: using the same machTimeToWallClockNs anchor as staticInitBeginNs.
    if (vu_static_init_end_ns > 0) {
        self.staticInitEndNs = vu_static_init_end_ns;
    }

    // preSDKStaticInitEndNs: Constructor(199) boundary (mach ticks → wall clock)
    // Represents what happened between Constructor(101) and SDK init (Constructor 201)
    if (vu_pre_sdk_static_init_end_ns > 0) {
        self.preSDKStaticInitEndNs = vu_mach_time_to_unix_nanos(vu_pre_sdk_static_init_end_ns);
    } else {
        // Fallback: if Constructor(199) didn't fire, make the span zero-width
        self.preSDKStaticInitEndNs = self.staticInitBeginNs;
    }

    // mainEntryNs: prefer fishhook-captured main() entry (mach ticks → wall clock).
    // For SwiftUI @main apps the C main() symbol is not exported, so fishhook never fires.
    // Fall back in order: static_init_end (legacy) → setDelegate boundary (always captured).
    if (vu_main_entry_ns > 0) {
        self.mainEntryNs = vu_mach_time_to_unix_nanos(vu_main_entry_ns);
    } else if (vu_static_init_end_ns > 0) {
        self.mainEntryNs = vu_static_init_end_ns;
    } else if (vu_ui_application_delegate_assigned_ns > 0) {
        // Fallback for SwiftUI @main: fishhook cannot intercept Swift's generated main()
        // so vu_main_entry_ns is never set. setDelegate: fires inside UIApplicationMain
        // after window/scene setup, so this OVERSTATES static_initializers duration for
        // SwiftUI apps. It is the best approximation available without a @_silgen_name shim.
        self.mainEntryNs = vu_mach_time_to_unix_nanos(vu_ui_application_delegate_assigned_ns);
    }

    self.isPrewarmed = vu_is_prewarmed;
}

/// Query kernel for exact process start time via sysctl
- (uint64_t)processStartTimeFromKernel {
    uint64_t process_start_ns = vu_get_kernel_process_start_ns();
    if (process_start_ns == 0) {
        VU_LOG("[startup] process start time unavailable — sysctl failed, using current time as fallback\n");
        return [StartupTelemetry currentTimeNs];
    }
    VU_LOG("[startup] Process start time locked in from kernel\n");
    return process_start_ns;
}

+ (uint64_t)currentTimeNs {
    return vu_get_current_time_ns();
}

+ (uint64_t)machTimeToUnixNanos:(uint64_t)machTime {
    return vu_mach_time_to_unix_nanos(machTime);
}

/// Mark OTel SDK initialization end after provider registration completes
+ (void)markOtelSdkInitEnd {
    uint64_t endTicks = mach_absolute_time();

    // Do not auto-repair ordering mistakes. Keep them visible in DEBUG so
    // assertion sites in Swift can catch and diagnose the root cause.
#if DEBUG
    if (vu_otel_sdk_init_begin_ns == 0) {
        VU_LOG("[startup] BUG: markOtelSdkInitEnd called before begin was set\n");
    } else if (vu_otel_sdk_init_begin_ns > endTicks) {
        VU_LOG("[startup] BUG: markOtelSdkInitEnd end precedes begin — begin=%llu end=%llu\n",
               vu_otel_sdk_init_begin_ns, endTicks);
    }
#endif

    vu_set_otel_sdk_init_end_ns(endTicks);
}

/// Convert mach_absolute_time ticks to wall-clock Unix nanoseconds
+ (uint64_t)otelSdkInitBeginNsWallClock {
    uint64_t machTicks = vu_get_otel_sdk_init_begin_ns();
    if (machTicks == 0) return 0;
    return [self machTimeToUnixNanos:machTicks];
}

/// Convert mach_absolute_time ticks to wall-clock Unix nanoseconds
+ (uint64_t)otelSdkInitEndNsWallClock {
    uint64_t machTicks = vu_get_otel_sdk_init_end_ns();
    if (machTicks == 0) return 0;
    return [self machTimeToUnixNanos:machTicks];
}

@end

// MARK: - Startup Metrics Tracking
static VUStage1Metrics vu_stage1_metrics = {0};

VUStage1Metrics vu_get_stage1_metrics(void) {
    return vu_stage1_metrics;
}

void vu_set_stage1_metrics(VUStage1Metrics metrics) {
    vu_stage1_metrics = metrics;
}

static VUStage1Metrics vu_capture_metrics_common(BOOL isPreMain) {
    VUStage1Metrics metrics = {0};
    
    // 1. Capture memory footprint (phys_footprint)
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        metrics.phys_footprint = (uint64_t)vmInfo.phys_footprint;
    }
    
    // 2. Capture CPU thread time (ns)
    task_thread_times_info_data_t threadTimes;
    mach_msg_type_number_t threadTimesCount = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&threadTimes, &threadTimesCount) == KERN_SUCCESS) {
        metrics.cpu_thread_time_ns = (uint64_t)threadTimes.user_time.seconds * 1000000000ULL +
                                     (uint64_t)threadTimes.user_time.microseconds * 1000ULL +
                                     (uint64_t)threadTimes.system_time.seconds * 1000000000ULL +
                                     (uint64_t)threadTimes.system_time.microseconds * 1000ULL;
    }
    
    // 3. Capture thermal state
    metrics.thermal_state = VUThermalStateUnknown;
    if (!isPreMain) {
        if ([NSProcessInfo respondsToSelector:@selector(processInfo)]) {
            NSProcessInfo *pi = [NSProcessInfo processInfo];
            if ([pi respondsToSelector:@selector(thermalState)]) {
                metrics.thermal_state = (VUThermalState)[pi thermalState];
            }
        }
    }
    
    // 4. Capture VM pressure (ratio)
    metrics.vm_pressure = -1.0;
    if (!isPreMain) {
        vm_statistics64_data_t vmStats;
        mach_msg_type_number_t infoCount = HOST_VM_INFO64_COUNT;
        kern_return_t kernReturn = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &infoCount);
        if (kernReturn == KERN_SUCCESS) {
            uint64_t total_pages = (uint64_t)vmStats.active_count +
                                   (uint64_t)vmStats.inactive_count +
                                   (uint64_t)vmStats.wire_count +
                                   (uint64_t)vmStats.free_count +
                                   (uint64_t)vmStats.speculative_count +
                                   (uint64_t)vmStats.compressor_page_count;
            if (total_pages > 0) {
                metrics.vm_pressure = (double)((uint64_t)vmStats.active_count +
                                               (uint64_t)vmStats.wire_count +
                                               (uint64_t)vmStats.compressor_page_count) / (double)total_pages;
            }
        }
    }
    
    // 5. Capture disk read-only status (Finding #16: removed disk_io_saturation — unavailable on Apple platforms)
    metrics.disk_is_readonly = NO;
    if (!isPreMain) {
        int num_mounts = getfsstat(NULL, 0, MNT_NOWAIT);
        if (num_mounts > 0) {
            int max_mounts = num_mounts > 32 ? 32 : num_mounts;
            struct statfs fs[max_mounts];
            int fs_count = getfsstat(fs, (int)(max_mounts * sizeof(struct statfs)), MNT_NOWAIT);
            for (int i = 0; i < fs_count; i++) {
                if (strcmp(fs[i].f_mntonname, "/") == 0) {
                    metrics.disk_is_readonly = (fs[i].f_flags & MNT_RDONLY) != 0;
                    break;
                }
            }
        }
    }
    
    metrics.valid = YES;
    return metrics;
}

VUStage1Metrics vu_capture_current_metrics(void) {
    return vu_capture_metrics_common(NO);
}

VUStage1Metrics vu_capture_pre_main_metrics(void) {
    return vu_capture_metrics_common(YES);
}

void vu_resolve_pre_main_thermal_state(void) {
    if (vu_stage1_metrics.valid && vu_stage1_metrics.thermal_state == VUThermalStateUnknown) {
        if ([NSProcessInfo respondsToSelector:@selector(processInfo)]) {
            NSProcessInfo *pi = [NSProcessInfo processInfo];
            if ([pi respondsToSelector:@selector(thermalState)]) {
                vu_stage1_metrics.thermal_state = (VUThermalState)[pi thermalState];
            }
        }
    }
}

// MARK: - C Accessor Functions for Pre-Main Timing Globals

uint64_t vu_get_process_start_ns(void) {
    return vu_process_start_ns;
}

uint64_t vu_get_dylib_loaded_end_mach(void) {
    return vu_dylib_loaded_end_mach;
}

uint64_t vu_get_wall_clock_at_process_start_ns(void) {
    return vu_wall_clock_at_process_start_ns;
}

uint64_t vu_get_mach_time_at_process_start(void) {
    return vu_mach_time_at_process_start;
}

uint64_t vu_get_static_init_begin_ns(void) {
    return vu_static_init_begin_ns;
}

uint64_t vu_get_static_init_end_ns(void) {
    return vu_static_init_end_ns;
}

uint64_t vu_get_pre_sdk_static_init_end_ns(void) {
    return vu_pre_sdk_static_init_end_ns;
}

uint64_t vu_get_main_entry_ns(void) {
    return vu_main_entry_ns;
}

uint64_t vu_get_ui_application_delegate_assigned_ns(void) {
    return vu_ui_application_delegate_assigned_ns;
}

uint64_t vu_get_otel_sdk_init_begin_ns(void) {
    return vu_otel_sdk_init_begin_ns;
}

uint64_t vu_get_otel_sdk_init_end_ns(void) {
    return vu_otel_sdk_init_end_ns;
}

BOOL vu_get_is_prewarmed(void) {
    return vu_is_prewarmed;
}

void vu_set_otel_sdk_init_end_ns(uint64_t ticks) {
    vu_otel_sdk_init_end_ns = ticks;
}

// MARK: - Internal Setters (Called from PreMainInit.m)

void vu_set_process_start_ns(uint64_t ns) {
    vu_process_start_ns = ns;
}

void vu_set_dylib_loaded_end_mach(uint64_t ticks) {
    vu_dylib_loaded_end_mach = ticks;
}

void vu_set_wall_clock_at_process_start_ns(uint64_t ns) {
    vu_wall_clock_at_process_start_ns = ns;
}

void vu_set_mach_time_at_process_start(uint64_t ticks) {
    vu_mach_time_at_process_start = ticks;
}

void vu_set_static_init_begin_ns(uint64_t ns) {
    vu_static_init_begin_ns = ns;
}

void vu_set_static_init_end_ns(uint64_t ns) {
    vu_static_init_end_ns = ns;
}

void vu_set_pre_sdk_static_init_end_ns(uint64_t ticks) {
    vu_pre_sdk_static_init_end_ns = ticks;
}

void vu_set_main_entry_ns(uint64_t ticks) {
    vu_main_entry_ns = ticks;
}

void vu_set_ui_application_delegate_assigned_ns(uint64_t ticks) {
    vu_ui_application_delegate_assigned_ns = ticks;
}

void vu_set_otel_sdk_init_begin_ns(uint64_t ns) {
    vu_otel_sdk_init_begin_ns = ns;
}

void vu_set_is_prewarmed(BOOL value) {
    vu_is_prewarmed = value;
}

// MARK: - Lifecycle Timestamp Accessors

uint64_t vu_get_will_finish_launching_begin_ns(void) {
    return vu_will_finish_launching_begin_ns;
}

uint64_t vu_get_will_finish_launching_end_ns(void) {
    return vu_will_finish_launching_end_ns;
}

uint64_t vu_get_did_finish_launching_begin_ns(void) {
    return vu_did_finish_launching_begin_ns;
}

uint64_t vu_get_did_finish_launching_end_ns(void) {
    return vu_did_finish_launching_end_ns;
}

uint64_t vu_get_scene_connection_begin_ns(void) {
    return vu_scene_connection_begin_ns;
}

uint64_t vu_get_scene_connection_end_ns(void) {
    return vu_scene_connection_end_ns;
}

// MARK: - Internal Lifecycle Setters

void vu_set_will_finish_launching_begin_ns(uint64_t ns) {
    vu_will_finish_launching_begin_ns = ns;
}

void vu_set_will_finish_launching_end_ns(uint64_t ns) {
    vu_will_finish_launching_end_ns = ns;
}

void vu_set_did_finish_launching_begin_ns(uint64_t ns) {
    vu_did_finish_launching_begin_ns = ns;
}

void vu_set_did_finish_launching_end_ns(uint64_t ns) {
    vu_did_finish_launching_end_ns = ns;
}

void vu_set_scene_connection_begin_ns(uint64_t ns) {
    vu_scene_connection_begin_ns = ns;
}

void vu_set_scene_connection_end_ns(uint64_t ns) {
    vu_scene_connection_end_ns = ns;
}

// MARK: - Unified C Helpers

uint64_t vu_get_kernel_process_start_ns(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    
    if (sysctl(mib, 4, &kp, &len, NULL, 0) == -1) {
        return 0;
    }
    
    uint64_t seconds_ns = (uint64_t)kp.kp_proc.p_starttime.tv_sec * 1000000000ULL;
    uint64_t microseconds_ns = (uint64_t)kp.kp_proc.p_starttime.tv_usec * 1000ULL;
    return seconds_ns + microseconds_ns;
}

uint64_t vu_get_current_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Finding #11: Replace dispatch_once with simple init (safe because first call is single-threaded from constructor)
// Finding #15: Remove fallback that calls ObjC singleton from constructor path
uint64_t vu_mach_time_to_unix_nanos(uint64_t machTime) {
    static mach_timebase_info_data_t timebaseInfo = {0};
    if (timebaseInfo.denom == 0) {
        mach_timebase_info(&timebaseInfo);
    }

    if (timebaseInfo.denom == 0) {
        return 0;
    }

    uint64_t baseMach = vu_mach_time_at_process_start;
    uint64_t baseWallClockNs = vu_wall_clock_at_process_start_ns;

    if (baseMach == 0 || baseWallClockNs == 0) {
        return 0;
    }

    int64_t deltaMach = (int64_t)machTime - (int64_t)baseMach;
    int64_t deltaNanos = (deltaMach * (int64_t)timebaseInfo.numer) / (int64_t)timebaseInfo.denom;
    int64_t unixNanos = (int64_t)baseWallClockNs + deltaNanos;

    return unixNanos > 0 ? (uint64_t)unixNanos : 0;
}

void vu_dispatch_bootstrap_selector(SEL selector, const char *sourceLabel) {
    Class initializerClass = objc_getClass("VuTelemetryAutoInitializer");
    if (initializerClass == Nil) {
        initializerClass = NSClassFromString(@"vuTelemetry.VuTelemetryAutoInitializer");
    }

    if (initializerClass != Nil && [initializerClass respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(initializerClass, selector);
    } else {
        VU_LOG("[startup] VuTelemetryAutoInitializer not found — SDK init skipped (source: %s)\n", sourceLabel);
    }
}
