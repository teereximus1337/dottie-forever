#pragma once

#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <sys/types.h>

namespace audio_router::macos {

constexpr std::size_t kMaxCaptureFrames = 4096;
constexpr std::size_t kMaxProcesses = 16;

enum class Error : std::uint32_t {
    none, invalid_selection, unsupported_os, unsupported_format,
    source_unavailable, core_audio_failure, already_started, invalid_sink,
    invalid_buffer, invalid_pcm, sink_full, invalid_timestamp,
    configuration_changed, cleanup_failed, allocation_failure, not_running
};

// Diagnostic categories only; never include source identifiers or audio.
enum class ErrorStage : std::uint16_t {
    none, device_alive, device_streams, stream_format, device_rate, device_buffer,
    process_translate, process_identity, process_output, callback_timestamp,
    callback_format, callback_sink
};
const char* error_stage_name(ErrorStage) noexcept;

struct Result {
    Error code = Error::none;
    OSStatus os_status = noErr;
    ErrorStage stage = ErrorStage::none;
    bool ok() const noexcept { return code == Error::none; }
};

enum class Phase : std::uint32_t { stopped, starting, running, faulted, stopping, cleanup_failed };
enum class SourceKind : std::uint32_t { none, physical_input, process_allowlist };

struct CaptureBlock {
    std::uint64_t host_time = 0; // Core Audio host ticks, not nanoseconds.
    std::uint32_t frames = 0;
    std::uint32_t sample_rate = 48000;
    float samples[kMaxCaptureFrames]{};
};

// Caller-owned slots remain alive through CaptureEngine::stop(). One producer
// capture and one consumer only. No allocation or blocking in push/pop.
class BoundedSink {
public:
    BoundedSink(CaptureBlock* slots, std::uint32_t slot_count) noexcept;
    bool valid() const noexcept;
    bool try_pop(CaptureBlock& output) noexcept;
    bool try_push(const float* mono, std::uint32_t frames, std::uint64_t host_time, std::uint32_t sample_rate = 48000) noexcept;
    bool claim() noexcept;
    void release() noexcept;
private:
    CaptureBlock* slots_;
    std::uint32_t capacity_;
    std::atomic<std::uint32_t> write_{0}, read_{0}, claimed_{0};
};

struct Format {
    std::uint32_t channels = 0;
    bool noninterleaved = false;
    std::uint32_t sample_rate = 48000;
};

// Pure validation/conversion functions: no property queries or capture.
Result validate_format(const AudioStreamBasicDescription& asbd, Format& out) noexcept;
Result downmix(const Format& format, const AudioBufferList* input, float* mono,
               std::size_t capacity, std::uint32_t& frames) noexcept;
Result validate_process_selection(const pid_t* pids, std::size_t count) noexcept;

struct Snapshot {
    Phase phase = Phase::stopped;
    SourceKind source = SourceKind::none;
    std::uint64_t blocks = 0;
    std::uint64_t frames = 0;
    Result pending_error{};
    bool source_active = true; // Process output activity; physical input stays true.
    bool accepting = false;
    std::uint64_t priming_callbacks = 0;
};

// Construction, snapshot and destruction of a never-started engine do not
// query audio devices. Start/arm/stop/poll_health/destruction must be serialized;
// an owner may hand control to a monitor thread after arm and join before stop.
// snapshot/take_error access atomic runtime state and may run concurrently with
// poll_health, but never concurrently with start/stop/destruction.
// Start/stop/poll_health contain real Core Audio calls and must NOT be invoked
// until capture is explicitly authorized. This target is compiled-only.
class CaptureEngine {
public:
    CaptureEngine();
    ~CaptureEngine();
    CaptureEngine(const CaptureEngine&) = delete;
    CaptureEngine& operator=(const CaptureEngine&) = delete;
    Result start_physical(AudioObjectID device, const char* expected_device_uid, BoundedSink&, bool defer_acceptance = false) noexcept;
    Result start_processes(const pid_t* explicit_pids, std::size_t count, BoundedSink&, bool defer_acceptance = false) noexcept;
    // Deferred startup discards callbacks until all sources are prepared. Arm
    // immediately before the consumer runs; it never clears a fault or queue.
    // No HAL calls, allocation, waiting or device changes occur here.
    Result arm() noexcept;
    Result stop() noexcept;
    Result poll_health() noexcept;
    Snapshot snapshot() const noexcept;
    Result take_error() noexcept;
private:
#ifdef AR_CAPTURE_TESTING
    friend struct CaptureTestAccess;
#endif
    struct State;
    std::unique_ptr<State> state_;
};

#ifdef AR_CAPTURE_TESTING
// Offline callback harness only: no device queries, starts, or permissions.
struct CaptureTestAccess {
    static Result prepare(CaptureEngine&, BoundedSink&, bool deferred) noexcept;
    static void callback(CaptureEngine&, const AudioBufferList*, std::uint64_t ticks) noexcept;
};
#endif

} // namespace audio_router::macos
