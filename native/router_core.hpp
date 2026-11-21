#pragma once

#include <cstddef>
#include <cstdint>

namespace audio_router {

constexpr std::uint64_t kSampleRate = 48000;
constexpr std::size_t kMaximumFrames = 48000;
constexpr std::uint64_t kMaximumLeaseNs = 1000000000;
constexpr std::uint64_t kMaximumCommandAgeNs = 100000000;

enum class Status {
    ok,
    invalid_configuration,
    invalid_control,
    invalid_timeline,
    time_overflow,
    invalid_buffers,
    invalid_samples,
    epoch_exhausted
};

struct Command {
    std::uint64_t epoch;
    std::uint64_t sequence;
    std::uint64_t progress;
    std::uint64_t timestamp_ns;
    bool healthy;
    bool wake;
    bool standby;
};

struct InputBuffer {
    const float* data;
    std::size_t size;
};

struct OutputBuffer {
    float* data;
    std::size_t size;
};

struct Inputs { InputBuffer mic, discord, dot; };
struct Outputs { OutputBuffer discord, detector, dot; };

// App-agnostic routes over the two established endpoint buses. The keyword
// listener remains ungated mic + conversation mix, independent of mic routing.
struct Routing {
    bool mic_to_apps = true;
    bool mic_to_assistant = true;
    bool assistant_to_apps = true;
};

// Single-owner, serialized offline API. This is not a concurrent IPC boundary.
// now_ns/start_ns must come from the same trusted monotonic clock. Command
// timestamps and counters are checked against that clock and prior operations.
class RouterCore {
public:
    explicit RouterCore(std::uint64_t lease_ns = kMaximumLeaseNs) noexcept;
    Status restart() noexcept;
    Status control(const Command& command, std::uint64_t now_ns) noexcept;
    Status render(const Inputs& inputs, const Outputs& outputs,
                  std::size_t frames, std::uint64_t start_ns) noexcept;
    Status render(const Inputs& inputs, const Outputs& outputs,
                  std::size_t frames, std::uint64_t start_ns,
                  const Routing& routing) noexcept;

    std::uint64_t epoch() const noexcept { return epoch_; }
    std::uint64_t next_time_ns() const noexcept { return timeline_ns_; }
    bool gate_open() const noexcept { return open_; }

private:
    void close() noexcept;
    std::uint64_t lease_ns_;
    std::uint64_t epoch_ = 1;
    std::uint64_t sequence_ = 0;
    std::uint64_t progress_ = 0;
    std::uint64_t timeline_ns_ = 0;
    std::uint64_t deadline_ns_ = 0;
    bool has_timeline_ = false;
    bool open_ = false;
    bool exhausted_ = false;
};

} // namespace audio_router
