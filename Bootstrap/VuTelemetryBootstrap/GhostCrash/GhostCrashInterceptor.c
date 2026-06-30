//
//  GhostCrashInterceptor.c
//  VuTelemetryBootstrap
//
//  Implements the pre-main ghost crash signal interception engine in pure C.
//

#include "GhostCrashInterceptor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <time.h>
#include <signal.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

// Finding #1: Use volatile sig_atomic_t instead of volatile int
static volatile sig_atomic_t ghost_crash_current_phase = GhostCrashPhaseDyld;

// Static storage
static struct timespec s_install_time;
static char s_report_path[1024] = {0};

// Finding #4: Pre-cache device info at init time instead of reading in signal handler
static char s_os_version[64] = "unknown";
static char s_device_model[64] = "unknown";

// Finding #3: Pre-cache VM/CPU info periodically, read from signal handler
static volatile uint64_t s_last_known_phys_footprint = 0;
static volatile uint64_t s_last_known_virtual_size = 0;
static volatile uint64_t s_last_known_cpu_user_ns = 0;
static volatile uint64_t s_last_known_cpu_system_ns = 0;

// Finding #5: Pre-cache mach-to-wall-clock conversion parameters
static uint64_t s_cached_base_mach = 0;
static uint64_t s_cached_base_wall_ns = 0;
static uint32_t s_cached_numer = 0;
static uint32_t s_cached_denom = 0;

// Finding #7: Save previous signal handlers for chaining
static struct sigaction s_previous_actions[32] = {{0}};

// Finding #8: Pre-open crash report file descriptor
static int s_crash_fd = -1;

// Forward declaration of signal handler
static void ghost_crash_signal_handler(int signum, siginfo_t *info, void *context);

// Convert phase enum to static string
static const char *ghost_crash_phase_name(int phase) {
    switch (phase) {
        case GhostCrashPhaseDyld:
            return "dylib_loading";
        case GhostCrashPhaseStaticInit:
            return "static_initializers";
        case GhostCrashPhaseOtelInitBegin:
            return "otel_sdk_initialization";
        case GhostCrashPhaseOtelInitEnd:
            return "otel_sdk_initialization_completed";
        case GhostCrashPhaseMain:
            return "main";
        case GhostCrashPhasePostLaunch:
            return "post_launch";
        default:
            return "unknown";
    }
}

// Initialize cache file path
static void ghost_crash_init_path(void) {
    const char *home = getenv("HOME");
    if (home) {
        snprintf(s_report_path, sizeof(s_report_path), "%s/Library/Caches/vutelemetry_ghost_crash.json", home);
    } else {
        snprintf(s_report_path, sizeof(s_report_path), "/tmp/vutelemetry_ghost_crash.json");
    }
}

// Finding #2: Async-signal-safe uint64 to decimal string formatter
static void vu_uint64_to_str(uint64_t val, char *buf, int *pos) {
    char tmp[20];
    int len = 0;
    do { tmp[len++] = '0' + (char)(val % 10); val /= 10; } while (val);
    while (len--) buf[(*pos)++] = tmp[len];
}

// Finding #2: Async-signal-safe int to decimal string formatter
static void vu_int_to_str(int val, char *buf, int *pos) {
    if (val < 0) { buf[(*pos)++] = '-'; val = -val; }
    vu_uint64_to_str((uint64_t)val, buf, pos);
}

// Finding #2: Async-signal-safe hex formatter for fault address
static void vu_ptr_to_hex(uintptr_t val, char *buf, int *pos) {
    buf[(*pos)++] = '0';
    buf[(*pos)++] = 'x';
    if (val == 0) { buf[(*pos)++] = '0'; return; }
    char tmp[16];
    int len = 0;
    while (val) {
        int digit = (int)(val & 0xF);
        tmp[len++] = digit < 10 ? ('0' + (char)digit) : ('a' + (char)(digit - 10));
        val >>= 4;
    }
    while (len--) buf[(*pos)++] = tmp[len];
}

// Async-signal-safe string copy
static void vu_str_copy(const char *src, char *buf, int *pos) {
    while (*src) buf[(*pos)++] = *src++;
}

// Finding #5: Signal-safe mach-to-wall-clock using pre-cached values
static uint64_t safe_ticks_to_nanos(uint64_t ticks) {
    if (ticks == 0 || s_cached_denom == 0 || s_cached_base_mach == 0) return 0;
    int64_t deltaMach = (int64_t)ticks - (int64_t)s_cached_base_mach;
    int64_t deltaNanos = (deltaMach * (int64_t)s_cached_numer) / (int64_t)s_cached_denom;
    int64_t unixNanos = (int64_t)s_cached_base_wall_ns + deltaNanos;
    return unixNanos > 0 ? (uint64_t)unixNanos : 0;
}

// Update cached metrics from normal code (call periodically)
void ghost_crash_update_cached_metrics(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        s_last_known_phys_footprint = (uint64_t)vmInfo.phys_footprint;
        s_last_known_virtual_size = (uint64_t)vmInfo.virtual_size;
    }

    task_thread_times_info_data_t threadTimes;
    mach_msg_type_number_t threadTimesCount = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&threadTimes, &threadTimesCount) == KERN_SUCCESS) {
        s_last_known_cpu_user_ns = (uint64_t)threadTimes.user_time.seconds * 1000000000ULL + (uint64_t)threadTimes.user_time.microseconds * 1000ULL;
        s_last_known_cpu_system_ns = (uint64_t)threadTimes.system_time.seconds * 1000000000ULL + (uint64_t)threadTimes.system_time.microseconds * 1000ULL;
    }
}

// Update cached mach-to-wall-clock conversion anchors
void ghost_crash_update_time_anchors(uint64_t baseMach, uint64_t baseWallNs) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    s_cached_numer = tb.numer;
    s_cached_denom = tb.denom;
    s_cached_base_mach = baseMach;
    s_cached_base_wall_ns = baseWallNs;
}

// Prototypes for StartupTelemetry timing functions
uint64_t vu_get_process_start_ns(void);
uint64_t vu_get_dylib_loaded_end_mach(void);
uint64_t vu_get_static_init_begin_ns(void);
uint64_t vu_get_static_init_end_ns(void);
uint64_t vu_get_otel_sdk_init_begin_ns(void);
uint64_t vu_get_otel_sdk_init_end_ns(void);
uint64_t vu_get_will_finish_launching_begin_ns(void);
uint64_t vu_get_will_finish_launching_end_ns(void);
uint64_t vu_get_did_finish_launching_begin_ns(void);
uint64_t vu_get_did_finish_launching_end_ns(void);
uint64_t vu_get_scene_connection_begin_ns(void);
uint64_t vu_get_scene_connection_end_ns(void);

// Runs BEFORE OTel SDK static initializer.
// Priority 101 = runs early in the static constructor sequence.
__attribute__((constructor(101)))
static void ghost_crash_install_handlers(void) {
    // 1. Build crash report file path
    ghost_crash_init_path();

    // 2. Record installation time
    clock_gettime(CLOCK_REALTIME, &s_install_time);

    // 3. Mark phase transition to static initialization
    ghost_crash_set_phase(GhostCrashPhaseStaticInit);

    // Finding #4: Pre-cache device info at init time
    size_t len = sizeof(s_os_version);
    sysctlbyname("kern.osversion", s_os_version, &len, NULL, 0);
    len = sizeof(s_device_model);
    sysctlbyname("hw.machine", s_device_model, &len, NULL, 0);

    // Finding #5: Pre-cache timebase info
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    s_cached_numer = tb.numer;
    s_cached_denom = tb.denom;

    // Finding #3: Initial metrics capture
    ghost_crash_update_cached_metrics();

    // Finding #8: Pre-open crash report file descriptor
    if (s_report_path[0] != '\0') {
        s_crash_fd = open(s_report_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    }

    // Finding #6: Set up alternate signal stack for stack overflow handling
    stack_t ss;
    ss.ss_sp = malloc(SIGSTKSZ);
    if (ss.ss_sp) {
        ss.ss_size = SIGSTKSZ;
        ss.ss_flags = 0;
        sigaltstack(&ss, NULL);
    }

    // 4. Install signal handlers
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = ghost_crash_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;  // Finding #6: Add SA_ONSTACK
    sigfillset(&sa.sa_mask);

    int signals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        // Finding #7: Save previous handlers for chaining
        sigaction(signals[i], &sa, &s_previous_actions[signals[i]]);
    }
}

// Finding #2: Fully async-signal-safe JSON builder
static void vu_build_json_field_str(char *buf, int *pos, const char *key, const char *val, int last) {
    vu_str_copy("  \"", buf, pos);
    vu_str_copy(key, buf, pos);
    vu_str_copy("\": \"", buf, pos);
    vu_str_copy(val, buf, pos);
    buf[(*pos)++] = '"';
    if (!last) buf[(*pos)++] = ',';
    buf[(*pos)++] = '\n';
}

static void vu_build_json_field_uint(char *buf, int *pos, const char *key, uint64_t val, int last) {
    vu_str_copy("  \"", buf, pos);
    vu_str_copy(key, buf, pos);
    vu_str_copy("\": ", buf, pos);
    vu_uint64_to_str(val, buf, pos);
    if (!last) buf[(*pos)++] = ',';
    buf[(*pos)++] = '\n';
}

static void vu_build_json_field_int(char *buf, int *pos, const char *key, int val, int last) {
    vu_str_copy("  \"", buf, pos);
    vu_str_copy(key, buf, pos);
    vu_str_copy("\": ", buf, pos);
    vu_int_to_str(val, buf, pos);
    if (!last) buf[(*pos)++] = ',';
    buf[(*pos)++] = '\n';
}

// The raw signal handler — uses only async-signal-safe operations
static void ghost_crash_signal_handler(int signum, siginfo_t *info, void *context) {
    // 1. Calculate timestamps (clock_gettime is async-signal-safe)
    uint64_t install_time_ns = (uint64_t)s_install_time.tv_sec * 1000000000ULL + (uint64_t)s_install_time.tv_nsec;
    struct timespec crash_time;
    clock_gettime(CLOCK_REALTIME, &crash_time);
    uint64_t crash_time_ns = (uint64_t)crash_time.tv_sec * 1000000000ULL + (uint64_t)crash_time.tv_nsec;

    // Finding #3: Read pre-cached metrics instead of calling task_info()
    uint64_t memory_footprint = s_last_known_phys_footprint;
    uint64_t memory_virtual = s_last_known_virtual_size;
    uint64_t cpu_user_time_ns = s_last_known_cpu_user_ns;
    uint64_t cpu_system_time_ns = s_last_known_cpu_system_ns;

    // 5. Signal type
    const char *sig_name = "UNKNOWN";
    switch (signum) {
        case SIGSEGV: sig_name = "SIGSEGV"; break;
        case SIGBUS:  sig_name = "SIGBUS";  break;
        case SIGABRT: sig_name = "SIGABRT"; break;
        case SIGILL:  sig_name = "SIGILL";  break;
        case SIGFPE:  sig_name = "SIGFPE";  break;
        case SIGTRAP: sig_name = "SIGTRAP"; break;
    }

    // Finding #2: Build fault address using signal-safe formatter
    char fault_addr_str[32];
    int fa_pos = 0;
    if (info && info->si_addr) {
        vu_ptr_to_hex((uintptr_t)info->si_addr, fault_addr_str, &fa_pos);
    } else {
        vu_str_copy("0x0", fault_addr_str, &fa_pos);
    }
    fault_addr_str[fa_pos] = '\0';

    // Finding #2: Build JSON using async-signal-safe formatters only
    static char json_buffer[8192];
    int pos = 0;
    json_buffer[pos++] = '{';
    json_buffer[pos++] = '\n';

    vu_build_json_field_str(json_buffer, &pos, "crash.type", sig_name, 0);
    vu_build_json_field_int(json_buffer, &pos, "crash.signal_code", info ? info->si_code : 0, 0);
    vu_build_json_field_str(json_buffer, &pos, "crash.fault_address", fault_addr_str, 0);
    vu_build_json_field_str(json_buffer, &pos, "crash.phase", ghost_crash_phase_name((int)ghost_crash_current_phase), 0);
    vu_build_json_field_int(json_buffer, &pos, "crash.phase_code", (int)ghost_crash_current_phase, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.handler_install_time_ns", install_time_ns, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.crash_time_ns", crash_time_ns, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.memory_footprint_bytes", memory_footprint, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.memory_virtual_size_bytes", memory_virtual, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.cpu_user_time_ns", cpu_user_time_ns, 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.cpu_system_time_ns", cpu_system_time_ns, 0);
    vu_build_json_field_str(json_buffer, &pos, "crash.export_status", "pending_next_boot", 0);
    vu_build_json_field_str(json_buffer, &pos, "crash.sdk_version", "0.0.1", 0);
    // Finding #4: Read from pre-cached static buffers
    vu_build_json_field_str(json_buffer, &pos, "crash.os_version", s_os_version, 0);
    vu_build_json_field_str(json_buffer, &pos, "crash.device_model", s_device_model, 0);
    vu_build_json_field_int(json_buffer, &pos, "crash.pid", (int)getpid(), 0);
    // Finding #5: Use pre-cached conversion parameters
    vu_build_json_field_uint(json_buffer, &pos, "crash.process_start_time_ns", vu_get_process_start_ns(), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.dylib_loaded_end_ns", safe_ticks_to_nanos(vu_get_dylib_loaded_end_mach()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.static_init_begin_ns", vu_get_static_init_begin_ns(), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.static_init_end_ns", vu_get_static_init_end_ns(), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.otel_sdk_init_begin_ns", safe_ticks_to_nanos(vu_get_otel_sdk_init_begin_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.otel_sdk_init_end_ns", safe_ticks_to_nanos(vu_get_otel_sdk_init_end_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.will_finish_launching_begin_ns", safe_ticks_to_nanos(vu_get_will_finish_launching_begin_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.will_finish_launching_end_ns", safe_ticks_to_nanos(vu_get_will_finish_launching_end_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.did_finish_launching_begin_ns", safe_ticks_to_nanos(vu_get_did_finish_launching_begin_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.did_finish_launching_end_ns", safe_ticks_to_nanos(vu_get_did_finish_launching_end_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.scene_connection_begin_ns", safe_ticks_to_nanos(vu_get_scene_connection_begin_ns()), 0);
    vu_build_json_field_uint(json_buffer, &pos, "crash.scene_connection_end_ns", safe_ticks_to_nanos(vu_get_scene_connection_end_ns()), 1);

    json_buffer[pos++] = '}';
    json_buffer[pos] = '\0';

    // Finding #8: Write to pre-opened file descriptor
    if (s_crash_fd >= 0 && pos > 0) {
        lseek(s_crash_fd, 0, SEEK_SET);
        ftruncate(s_crash_fd, 0);
        write(s_crash_fd, json_buffer, (size_t)pos);
    }

    // Finding #7: Chain to previous handler or re-raise with default
    struct sigaction *prev = &s_previous_actions[signum];
    if ((prev->sa_flags & SA_SIGINFO) && prev->sa_sigaction) {
        prev->sa_sigaction(signum, info, context);
    } else if (prev->sa_handler && prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
        prev->sa_handler(signum);
    } else {
        signal(signum, SIG_DFL);
        raise(signum);
    }
}

// MARK: - Exported C Functions

int ghost_crash_has_pending_report(void) {
    if (s_report_path[0] == '\0') return 0;
    return access(s_report_path, F_OK) == 0 ? 1 : 0;
}

size_t ghost_crash_report_size(void) {
    if (s_report_path[0] == '\0') return 0;
    struct stat st;
    if (stat(s_report_path, &st) != 0) return 0;
    return (size_t)st.st_size;
}

int ghost_crash_read_pending_report(char *buf, size_t buf_size) {
    if (s_report_path[0] == '\0' || buf == NULL || buf_size == 0) return -1;
    int fd = open(s_report_path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, buf_size - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return 0;
}

void ghost_crash_clear_pending_report(void) {
    if (s_report_path[0] != '\0') {
        unlink(s_report_path);
    }
}

const char *ghost_crash_report_path(void) {
    return s_report_path;
}

void ghost_crash_set_phase(int phase) {
    ghost_crash_current_phase = (sig_atomic_t)phase;
}
