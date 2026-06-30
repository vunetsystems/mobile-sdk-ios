//
//  GhostCrashInterceptor.h
//  VuTelemetryBootstrap
//
//  Declares the C interface and initialization phases for the pre-main
//  ghost crash signal interception system.
//

#ifndef GhostCrashInterceptor_h
#define GhostCrashInterceptor_h

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

#ifndef NS_ENUM
#if (__cplusplus && __cplusplus >= 201103L && (__has_feature(cxx_strong_enums) || __has_extension(cxx_strong_enums))) || (!__cplusplus && __has_feature(objc_fixed_enum))
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#else
#define NS_ENUM(_type, _name) _type _name; enum _name
#endif
#endif

NS_ASSUME_NONNULL_BEGIN

// Called once at the start of each app boot by GhostCrashRecovery.swift.
// Returns 1 if a pending crash report was found on disk, 0 otherwise.
int ghost_crash_has_pending_report(void);

// Copies the pending crash report JSON into buf (null-terminated).
// buf must be at least ghost_crash_report_size() + 1 bytes.
// Returns 0 on success, -1 if no report exists.
int ghost_crash_read_pending_report(char *buf, size_t buf_size);

// Returns the byte length of the pending crash report (excluding null terminator).
// Returns 0 if no report exists.
size_t ghost_crash_report_size(void);

// Deletes the pending crash report from disk.
// Call after successful export.
void ghost_crash_clear_pending_report(void);

// Returns the absolute path used for the crash report file.
// Safe to call at any time (uses only POSIX calls).
const char *ghost_crash_report_path(void);

// Phases — set by the C constructor and by StartupTimingBridge at each boundary
typedef NS_ENUM(int, GhostCrashPhase) {
    GhostCrashPhaseDyld              = 0,  // default — before constructor runs
    GhostCrashPhaseStaticInit       = 1,  // set when constructor fires
    GhostCrashPhaseOtelInitBegin   = 2,  // set by StartupTimingBridge.markOtelSdkInitBegin()
    GhostCrashPhaseOtelInitEnd     = 3,  // set by StartupTimingBridge.markOtelSdkInitEnd()
    GhostCrashPhaseMain              = 4,  // set at main() entry
    GhostCrashPhasePostLaunch       = 5   // set after didFinishLaunching
};

// Called from C/Swift code at each phase boundary
void ghost_crash_set_phase(int phase);

// Update cached VM/CPU metrics for signal-safe access (call periodically from normal code)
void ghost_crash_update_cached_metrics(void);

// Update cached mach-to-wall-clock conversion anchors (call after constructor(101) sets them)
void ghost_crash_update_time_anchors(uint64_t baseMach, uint64_t baseWallNs);

NS_ASSUME_NONNULL_END

#endif /* GhostCrashInterceptor_h */
