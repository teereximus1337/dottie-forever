#include "router_bridge.h"
#include "router_core.hpp"

using audio_router::RouterCore;
using audio_router::Status;

static_assert(static_cast<int>(Status::ok) == AR_OK, "ABI status changed");
static_assert(static_cast<int>(Status::invalid_configuration) == AR_INVALID_CONFIGURATION, "ABI status changed");
static_assert(static_cast<int>(Status::invalid_control) == AR_INVALID_CONTROL, "ABI status changed");
static_assert(static_cast<int>(Status::invalid_timeline) == AR_INVALID_TIMELINE, "ABI status changed");
static_assert(static_cast<int>(Status::time_overflow) == AR_TIME_OVERFLOW, "ABI status changed");
static_assert(static_cast<int>(Status::invalid_buffers) == AR_INVALID_BUFFERS, "ABI status changed");
static_assert(static_cast<int>(Status::invalid_samples) == AR_INVALID_SAMPLES, "ABI status changed");
static_assert(static_cast<int>(Status::epoch_exhausted) == AR_EPOCH_EXHAUSTED, "ABI status changed");

extern "C" {

uint32_t ar_abi_version(void) noexcept { return 1; }

void* ar_create(uint64_t lease_ns) noexcept {
    try {
        return new RouterCore(lease_ns);
    } catch (...) {
        return nullptr;
    }
}

void ar_destroy(void* handle) noexcept {
    delete static_cast<RouterCore*>(handle);
}

int ar_restart(void* handle) noexcept {
    if (handle == nullptr) return AR_ERROR_INVALID_HANDLE;
    return static_cast<int>(static_cast<RouterCore*>(handle)->restart());
}

int ar_control(void* handle, uint64_t epoch, uint64_t sequence,
               uint64_t progress, uint64_t timestamp_ns, uint64_t now_ns,
               uint32_t flags) noexcept {
    if (handle == nullptr) return AR_ERROR_INVALID_HANDLE;
    auto* core = static_cast<RouterCore*>(handle);
    constexpr uint32_t known_flags = AR_HEALTHY | AR_WAKE | AR_STANDBY;
    if ((flags & ~known_flags) != 0) {
        // Every rejected unknown flag set closes Dot. An unhealthy command is
        // always fail-closed in the core, even if its envelope is also invalid.
        core->control({epoch, sequence, progress, timestamp_ns, false, false, true}, now_ns);
        return AR_ERROR_INVALID_FLAGS;
    }
    return static_cast<int>(core->control({epoch, sequence, progress, timestamp_ns,
        (flags & AR_HEALTHY) != 0, (flags & AR_WAKE) != 0, (flags & AR_STANDBY) != 0}, now_ns));
}

int ar_render(void* handle, const float* mic, const float* discord,
              const float* dot, float* discord_out, float* detector_out,
              float* dot_out, size_t frames, uint64_t start_ns) noexcept {
    if (handle == nullptr) return AR_ERROR_INVALID_HANDLE;
    return static_cast<int>(static_cast<RouterCore*>(handle)->render(
        {{mic, frames}, {discord, frames}, {dot, frames}},
        {{discord_out, frames}, {detector_out, frames}, {dot_out, frames}}, frames, start_ns));
}

uint64_t ar_epoch(void* handle) noexcept {
    return handle == nullptr ? 0 : static_cast<RouterCore*>(handle)->epoch();
}

uint64_t ar_next_time_ns(void* handle) noexcept {
    return handle == nullptr ? 0 : static_cast<RouterCore*>(handle)->next_time_ns();
}

uint32_t ar_gate_open(void* handle) noexcept {
    return handle != nullptr && static_cast<RouterCore*>(handle)->gate_open() ? 1U : 0U;
}

} // extern "C"
