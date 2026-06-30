//
//  DylibProfiler.h
//  VuTelemetryBootstrap
//
//  High-precision profiler for dylib loading phase (pre-main).
//  Tracks each dylib as it's loaded and measures loading time contribution.
//
//  Usage:
//    1. Call vu_dylib_profiler_start() early in +load
//    2. Register dyld callback with profiler enabled
//    3. Call vu_dylib_profiler_report() to dump results
//
//  Output: Detailed per-dylib timings + aggregated metrics
//

#ifndef DylibProfiler_h
#define DylibProfiler_h

#include <stdint.h>
#include <stddef.h>

#ifndef NS_ASSUME_NONNULL_BEGIN
# ifdef __OBJC__
#  import <Foundation/Foundation.h>
# else
#  if __has_include(<os/base.h>)
#   include <os/base.h>
#  endif
# endif
#endif

#ifndef NS_ASSUME_NONNULL_BEGIN
# define NS_ASSUME_NONNULL_BEGIN
# define NS_ASSUME_NONNULL_END
#endif

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

/// Maximum number of dylibs to track (increase if needed)
#define VU_DYLIB_PROFILER_MAX_DYLIBS 512

/// Per-dylib profiling record
typedef struct {
    /// Dylib path (truncated to 256 chars if needed)
    char dylib_path[256];
    
    /// Relative load order (0 = first, 1 = second, etc.)
    uint32_t load_order;
    
    /// mach_absolute_time tick when dyld began loading this dylib
    uint64_t load_start_ticks;
    
    /// mach_absolute_time tick when dyld finished loading this dylib
    uint64_t load_end_ticks;
    
    /// Estimated wall-clock milliseconds for this dylib load
    double load_time_ms;

    /// Whether this record was from replay phase (pre-loaded images, not live dlopen)
    uint8_t is_replayed;
} VUDylibRecord;

/// Initialize profiler (must be called once early in +load)
void vu_dylib_profiler_start(void);

/// Called by dyld callback for each image
void vu_dylib_profiler_on_image_added(const char * _Nonnull dylib_path, uint64_t timestamp_ticks);

/// Mark replay phase complete (call after _dyld_register_func_for_add_image returns)
void vu_dylib_profiler_mark_replay_complete(void);

/// Return current record count
uint32_t vu_dylib_profiler_record_count(void);

/// Return specific record by index (0-based)
VUDylibRecord vu_dylib_profiler_record_at_index(uint32_t index);

/// Return total dylib loading time in milliseconds
double vu_dylib_profiler_total_time_ms(void);

/// Return time of slowest dylib in milliseconds
double vu_dylib_profiler_slowest_time_ms(void);

/// Return path of slowest dylib
const char * _Nonnull vu_dylib_profiler_slowest_dylib_path(void);

/// Generate human-readable profiling report to stderr
void vu_dylib_profiler_report(void);

/// Return raw dylib records for programmatic access
const VUDylibRecord * _Nonnull vu_dylib_profiler_all_records(uint32_t * _Nonnull out_count);

/// Signal end of dylib loading phase (call after constructor(101))
void vu_dylib_profiler_end_phase(uint64_t end_ticks);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif /* DylibProfiler_h */
