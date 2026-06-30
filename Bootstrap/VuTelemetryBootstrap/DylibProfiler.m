//
//  DylibProfiler.m
//  VuTelemetryBootstrap
//
//  Implementation of high-precision dylib loading profiler.
//

#import "DylibProfiler.h"
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include <stdatomic.h>

#import "VUObjCLogger.h"

// MARK: - Profiler State

static struct {
    VUDylibRecord records[VU_DYLIB_PROFILER_MAX_DYLIBS];

    // Finding #13: Use atomic for thread safety with post-main dlopen callbacks
    _Atomic uint32_t record_count;

    uint64_t phase_start_ticks;
    uint64_t phase_end_ticks;
    mach_timebase_info_data_t timebase;
    uint8_t is_enabled;

    // Finding #12: Track replay phase to distinguish pre-loaded vs. live dylibs
    _Atomic uint8_t replay_phase;
} vu_dylib_profiler_state = {0};

// MARK: - Public API

void vu_dylib_profiler_start(void) {
    if (vu_dylib_profiler_state.is_enabled) {
        return;
    }

    mach_timebase_info(&vu_dylib_profiler_state.timebase);
    vu_dylib_profiler_state.phase_start_ticks = mach_absolute_time();
    atomic_store(&vu_dylib_profiler_state.record_count, 0);
    atomic_store(&vu_dylib_profiler_state.replay_phase, 1);
    vu_dylib_profiler_state.is_enabled = 1;

    VU_LOG("[DylibProfiler] Started at tick %llu\n", vu_dylib_profiler_state.phase_start_ticks);
}

void vu_dylib_profiler_mark_replay_complete(void) {
    atomic_store(&vu_dylib_profiler_state.replay_phase, 0);
}

void vu_dylib_profiler_on_image_added(const char *dylib_path, uint64_t timestamp_ticks) {
    if (!vu_dylib_profiler_state.is_enabled) {
        return;
    }

    // Finding #13: Atomic increment to prevent concurrent corruption
    uint32_t idx = atomic_fetch_add(&vu_dylib_profiler_state.record_count, 1);
    if (idx >= VU_DYLIB_PROFILER_MAX_DYLIBS) {
        atomic_fetch_sub(&vu_dylib_profiler_state.record_count, 1);
        VU_LOG("[DylibProfiler] Record buffer full (%u/%u)\n",
                idx, VU_DYLIB_PROFILER_MAX_DYLIBS);
        return;
    }

    VUDylibRecord *record = &vu_dylib_profiler_state.records[idx];

    if (dylib_path) {
        size_t path_len = strlen(dylib_path);
        size_t copy_len = path_len < sizeof(record->dylib_path) - 1 ?
                         path_len : sizeof(record->dylib_path) - 1;
        strncpy(record->dylib_path, dylib_path, copy_len);
        record->dylib_path[copy_len] = '\0';
    } else {
        strcpy(record->dylib_path, "<unknown>");
    }

    record->load_order = idx;
    record->load_end_ticks = timestamp_ticks;

    // Finding #12: Mark whether this callback is from replay phase
    record->is_replayed = atomic_load(&vu_dylib_profiler_state.replay_phase);

    if (idx == 0) {
        record->load_start_ticks = vu_dylib_profiler_state.phase_start_ticks;
    } else {
        record->load_start_ticks = vu_dylib_profiler_state.records[idx - 1].load_end_ticks;
    }

    uint64_t delta_ticks = record->load_end_ticks - record->load_start_ticks;
    uint64_t delta_ns = delta_ticks * vu_dylib_profiler_state.timebase.numer /
                       vu_dylib_profiler_state.timebase.denom;
    record->load_time_ms = (double)delta_ns / 1000000.0;
}

void vu_dylib_profiler_end_phase(uint64_t end_ticks) {
    vu_dylib_profiler_state.phase_end_ticks = end_ticks;
}

uint32_t vu_dylib_profiler_record_count(void) {
    return atomic_load(&vu_dylib_profiler_state.record_count);
}

VUDylibRecord vu_dylib_profiler_record_at_index(uint32_t index) {
    assert(index < atomic_load(&vu_dylib_profiler_state.record_count));
    return vu_dylib_profiler_state.records[index];
}

double vu_dylib_profiler_total_time_ms(void) {
    uint32_t count = atomic_load(&vu_dylib_profiler_state.record_count);
    if (count == 0) {
        return 0.0;
    }

    uint64_t first_start = vu_dylib_profiler_state.records[0].load_start_ticks;
    uint64_t last_end = vu_dylib_profiler_state.records[count - 1].load_end_ticks;
    uint64_t delta_ticks = last_end - first_start;
    uint64_t delta_ns = delta_ticks * vu_dylib_profiler_state.timebase.numer /
                       vu_dylib_profiler_state.timebase.denom;
    return (double)delta_ns / 1000000.0;
}

double vu_dylib_profiler_slowest_time_ms(void) {
    double max_time = 0.0;
    uint32_t count = atomic_load(&vu_dylib_profiler_state.record_count);
    for (uint32_t i = 0; i < count; i++) {
        if (vu_dylib_profiler_state.records[i].load_time_ms > max_time) {
            max_time = vu_dylib_profiler_state.records[i].load_time_ms;
        }
    }
    return max_time;
}

const char * vu_dylib_profiler_slowest_dylib_path(void) {
    double max_time = 0.0;
    const char *max_path = NULL;
    uint32_t count = atomic_load(&vu_dylib_profiler_state.record_count);
    for (uint32_t i = 0; i < count; i++) {
        if (vu_dylib_profiler_state.records[i].load_time_ms > max_time) {
            max_time = vu_dylib_profiler_state.records[i].load_time_ms;
            max_path = vu_dylib_profiler_state.records[i].dylib_path;
        }
    }
    return max_path ? max_path : "<none>";
}

const VUDylibRecord * vu_dylib_profiler_all_records(uint32_t *out_count) {
    if (out_count) {
        *out_count = atomic_load(&vu_dylib_profiler_state.record_count);
    }
    return vu_dylib_profiler_state.records;
}

// MARK: - Reporting (Finding #14/#27: Gated behind VU_LOG so report is debug-only)

void vu_dylib_profiler_report(void) {
#if defined(DEBUG) || defined(VU_TELEMETRY_DEBUG)
    fprintf(stderr, "\n");
    fprintf(stderr, "╔════════════════════════════════════════════════════════════════╗\n");
    fprintf(stderr, "║                    DYLIB LOADING PROFILE                       ║\n");
    fprintf(stderr, "╚════════════════════════════════════════════════════════════════╝\n");
    fprintf(stderr, "\n");

    uint32_t count = atomic_load(&vu_dylib_profiler_state.record_count);

    if (count == 0) {
        fprintf(stderr, "  No dylibs recorded. Profiler may not be enabled.\n\n");
        return;
    }

    uint64_t phase_delta_ticks = vu_dylib_profiler_state.phase_end_ticks - vu_dylib_profiler_state.phase_start_ticks;
    uint64_t phase_delta_ns = phase_delta_ticks * vu_dylib_profiler_state.timebase.numer /
                             vu_dylib_profiler_state.timebase.denom;
    double phase_total_ms = (double)phase_delta_ns / 1000000.0;

    double sum_total_ms = vu_dylib_profiler_total_time_ms();
    double slowest_ms = vu_dylib_profiler_slowest_time_ms();
    const char *slowest_path = vu_dylib_profiler_slowest_dylib_path();

    fprintf(stderr, "Summary:\n");
    fprintf(stderr, "  Total dylibs loaded: %u\n", count);
    fprintf(stderr, "  Total dylib loading time (inter-callback only): %.2f ms\n", sum_total_ms);
    fprintf(stderr, "  Total pre-main phase (process start -> Constructor(101)): %.2f ms\n", phase_total_ms);
    fprintf(stderr, "  Slowest individual callback interval: %.2f ms -- %s\n", slowest_ms, slowest_path);
    fprintf(stderr, "  Average callback interval per dylib: %.2f ms\n", sum_total_ms / (double)count);
    fprintf(stderr, "\n");
    fprintf(stderr, "  NOTE: Times above measure interval between dylib callbacks, not actual dylib work time.\n");
    fprintf(stderr, "\n");

    fprintf(stderr, "Top 20 Slowest Callback Intervals:\n");
    fprintf(stderr, "  %-3s %-8s %-7s %s\n", "Ord", "Time(ms)", "Replay", "Dylib Path");
    fprintf(stderr, "  %-3s %-8s %-7s %s\n", "---", "--------", "------", "─────────────────────────────────────────────");

    VUDylibRecord *sorted = (VUDylibRecord *)malloc(count * sizeof(VUDylibRecord));
    if (sorted) {
        memcpy(sorted, vu_dylib_profiler_state.records, count * sizeof(VUDylibRecord));

        for (uint32_t i = 0; i < count; i++) {
            for (uint32_t j = i + 1; j < count; j++) {
                if (sorted[j].load_time_ms > sorted[i].load_time_ms) {
                    VUDylibRecord tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }

        uint32_t display_count = count < 20 ? count : 20;
        for (uint32_t i = 0; i < display_count; i++) {
            const char *path = sorted[i].dylib_path;
            const char *filename = strrchr(path, '/');
            filename = filename ? filename + 1 : path;

            // Finding #12: Show replay flag in report
            fprintf(stderr, "  %3u  %8.2f  %-7s  %s\n",
                   sorted[i].load_order, sorted[i].load_time_ms,
                   sorted[i].is_replayed ? "yes" : "no", filename);
        }

        free(sorted);
    }

    fprintf(stderr, "\n");
#endif
}
