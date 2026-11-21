#ifndef AUDIO_ROUTER_BRIDGE_H
#define AUDIO_ROUTER_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define AR_NOEXCEPT noexcept
extern "C" {
#else
#define AR_NOEXCEPT
#endif

enum ar_status {
    AR_OK = 0,
    AR_INVALID_CONFIGURATION = 1,
    AR_INVALID_CONTROL = 2,
    AR_INVALID_TIMELINE = 3,
    AR_TIME_OVERFLOW = 4,
    AR_INVALID_BUFFERS = 5,
    AR_INVALID_SAMPLES = 6,
    AR_EPOCH_EXHAUSTED = 7,
    AR_ERROR_INVALID_HANDLE = -1,
    AR_ERROR_INVALID_FLAGS = -2
};

enum ar_control_flag {
    AR_HEALTHY = 1,
    AR_WAKE = 2,
    AR_STANDBY = 4
};

/* ABI 1: serial, single-owner access only. No exception crosses this boundary.
 * A handle must be NULL or a still-live handle returned by ar_create; arbitrary
 * forged pointers, use-after-destroy and concurrent access are invalid usage.
 * ar_create returns NULL on allocation failure. A non-null object with an
 * invalid lease reports AR_INVALID_CONFIGURATION on control operations.
 * ar_destroy(NULL) is harmless; NULL query handles return zero.
 */
uint32_t ar_abi_version(void) AR_NOEXCEPT;
void* ar_create(uint64_t lease_ns) AR_NOEXCEPT;
void ar_destroy(void* handle) AR_NOEXCEPT;
int ar_restart(void* handle) AR_NOEXCEPT;
int ar_control(void* handle, uint64_t epoch, uint64_t sequence,
               uint64_t progress, uint64_t timestamp_ns, uint64_t now_ns,
               uint32_t flags) AR_NOEXCEPT;

/* The six pointers must reference distinct, non-overlapping allocations, each
 * with at least frames actual float elements. Sizes are not discoverable from
 * a C pointer; this requirement must be enforced by the caller. Null pointers
 * are checked by the core. Its 1..48000 frame bound still applies.
 */
int ar_render(void* handle, const float* mic, const float* discord,
              const float* dot, float* discord_out, float* detector_out,
              float* dot_out, size_t frames, uint64_t start_ns) AR_NOEXCEPT;
uint64_t ar_epoch(void* handle) AR_NOEXCEPT;
uint64_t ar_next_time_ns(void* handle) AR_NOEXCEPT;
uint32_t ar_gate_open(void* handle) AR_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef AR_NOEXCEPT
#endif
