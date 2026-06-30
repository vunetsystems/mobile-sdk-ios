//
//  StartupTelemetry.h
//  VuTelemetryBootstrap
//
//  Lightweight pre-main startup telemetry collection
//  Captures only measurable lifecycle anchors using sysctl and mach_absolute_time
//

#ifndef StartupTelemetry_h
#define StartupTelemetry_h

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - C Accessor Functions for Pre-Main Timing Globals
//
// These functions provide the only public interface to startup timing globals.
// Swift must use these getters exclusively — never access globals directly.
// All writes happen on the ObjC/C side only.
//
// IMPORTANT (Finding #28): Despite the "_ns" suffix, most functions below return
// raw mach_absolute_time ticks (boot-epoch), NOT wall-clock nanoseconds.
// Use vu_mach_time_to_unix_nanos() to convert mach ticks to Unix nanoseconds.
// Only vu_get_process_start_ns(), vu_get_wall_clock_at_process_start_ns(), and
// vu_get_static_init_begin_ns() return actual wall-clock Unix nanoseconds.

/// Process start time — WALL-CLOCK Unix nanoseconds (from kernel sysctl)
uint64_t vu_get_process_start_ns(void);

/// End of dylib loading phase — MACH TICKS (raw mach_absolute_time)
uint64_t vu_get_dylib_loaded_end_mach(void);

/// Anchor pair captured atomically at Constructor(101)
/// vu_get_wall_clock_at_process_start_ns: WALL-CLOCK Unix nanoseconds
/// vu_get_mach_time_at_process_start: MACH TICKS
uint64_t vu_get_wall_clock_at_process_start_ns(void);
uint64_t vu_get_mach_time_at_process_start(void);

/// Start of static initializers phase — WALL-CLOCK Unix nanoseconds (converted at capture time)
uint64_t vu_get_static_init_begin_ns(void);

/// Main() entry — MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_main_entry_ns(void);

/// UIApplication setDelegate hook called — MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_ui_application_delegate_assigned_ns(void);

/// Pre-SDK static initializer end — MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_pre_sdk_static_init_end_ns(void);

/// OTel SDK initialization begin — MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_otel_sdk_init_begin_ns(void);

/// OTel SDK initialization end — MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_otel_sdk_init_end_ns(void);

/// Prewarming flag (iOS 15+)
BOOL vu_get_is_prewarmed(void);

/// AppDelegate lifecycle timestamps — all MACH TICKS (not nanoseconds despite name)
uint64_t vu_get_will_finish_launching_begin_ns(void);
uint64_t vu_get_will_finish_launching_end_ns(void);
uint64_t vu_get_did_finish_launching_begin_ns(void);
uint64_t vu_get_did_finish_launching_end_ns(void);
uint64_t vu_get_scene_connection_begin_ns(void);
uint64_t vu_get_scene_connection_end_ns(void);

/// Set OTel SDK initialization end timestamp (internal, called from ObjC only)
void vu_set_otel_sdk_init_end_ns(uint64_t ticks);

/// Internal setters for constructor-captured conversion anchors.
void vu_set_wall_clock_at_process_start_ns(uint64_t ns);
void vu_set_mach_time_at_process_start(uint64_t ticks);
void vu_set_pre_sdk_static_init_end_ns(uint64_t ticks);
void vu_set_main_entry_ns(uint64_t ticks);
void vu_set_ui_application_delegate_assigned_ns(uint64_t ticks);

// Called at app entry to mark the end of static initializers and detect prewarm.
// NOTE: Only reachable via the fishhook vu_hooked_main wrapper. For SwiftUI @main apps
// the Swift compiler generates a main() with no C linkage, so fishhook never fires and
// this function is never called. The static_init_end fallback in refreshStaticInitAnchors
// covers that path (using the setDelegate: hook timestamp as an approximation).
void vu_capture_main_entry_and_prewarm(void);

/// Unified helpers to eliminate redundancies
uint64_t vu_get_kernel_process_start_ns(void);
uint64_t vu_get_current_time_ns(void);
uint64_t vu_mach_time_to_unix_nanos(uint64_t machTime);
void vu_dispatch_bootstrap_selector(SEL selector, const char * _Nonnull sourceLabel);
uint32_t vu_get_dylib_image_count(void);

// MARK: - Startup Metrics Tracking

// Finding #18: Use NS_ENUM for thermal state so Swift gets a native enum
typedef NS_ENUM(int32_t, VUThermalState) {
    VUThermalStateUnknown  = -1,
    VUThermalStateNominal  =  0,
    VUThermalStateFair     =  1,
    VUThermalStateSerious  =  2,
    VUThermalStateCritical =  3
};

typedef struct {
    uint64_t phys_footprint;        // bytes (from TASK_VM_INFO)
    uint64_t cpu_thread_time_ns;    // nanoseconds (from TASK_THREAD_TIMES_INFO)
    VUThermalState thermal_state;   // thermal state (from ProcessInfo), -1 if unavailable
    double vm_pressure;             // ratio (from HOST_VM_INFO64)
    BOOL disk_is_readonly;          // flag indicating if root partition is read-only
    BOOL valid;                     // flag indicating capture was successful
} VUStage1Metrics;

VUStage1Metrics vu_get_stage1_metrics(void);
void vu_set_stage1_metrics(VUStage1Metrics metrics);
VUStage1Metrics vu_capture_current_metrics(void);
VUStage1Metrics vu_capture_pre_main_metrics(void);
void vu_resolve_pre_main_thermal_state(void);

/// Finding #21: Prefer using vu_get_*() C functions directly from Swift.
/// This ObjC class duplicates the C accessor surface and may return stale values
/// if refreshStaticInitAnchors hasn't been called. Kept for backward compatibility.
@interface StartupTelemetry : NSObject

/// Process start time (from kernel via sysctl)
@property (nonatomic, assign) uint64_t processStartNs;

/// Constructor execution start time
@property (nonatomic, assign) uint64_t constructorStartNs;

/// Constructor execution end time
@property (nonatomic, assign) uint64_t constructorEndNs;

/// End of dylib loading phase (raw mach_absolute_time)
@property (nonatomic, assign) uint64_t dylibLoadedEndMach;

/// Begin of static initializers (Unix nanoseconds)
@property (nonatomic, assign) uint64_t staticInitBeginNs;

/// End of static initializers (Unix nanoseconds)
@property (nonatomic, assign) uint64_t staticInitEndNs;

/// Pre-SDK static initializer end — Constructor(199) boundary (Unix nanoseconds)
@property (nonatomic, assign) uint64_t preSDKStaticInitEndNs;

/// Whether the process was launched from iOS prewarm cache
@property (nonatomic, assign) BOOL isPrewarmed;

/// Main function entry point
@property (nonatomic, assign) uint64_t mainEntryNs;

/// Shared singleton instance
+ (instancetype)sharedInstance;

/// Convert mach_absolute_time to Unix nanoseconds
+ (uint64_t)machTimeToUnixNanos:(uint64_t)machTime;

/// Get current time in Unix nanoseconds
+ (uint64_t)currentTimeNs;

/// Refreshes static initializer timestamps from global pre-main anchors.
- (void)refreshStaticInitAnchors;

/// Mark OTel SDK initialization end (called after provider registration)
+ (void)markOtelSdkInitEnd;

/// Convert OTel SDK init begin timestamp (mach ticks → wall-clock nanoseconds)
+ (uint64_t)otelSdkInitBeginNsWallClock;

/// Convert OTel SDK init end timestamp (mach ticks → wall-clock nanoseconds)
+ (uint64_t)otelSdkInitEndNsWallClock;

@end

NS_ASSUME_NONNULL_END

#endif /* StartupTelemetry_h */
