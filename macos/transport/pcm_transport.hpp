#pragma once

#include <cstddef>
#include <atomic>
#include <cstdint>
#include <string>
#include <mach/mach.h>

namespace audio_router::transport {

constexpr std::uint32_t kSampleRate = 48000;
constexpr std::size_t kPacketFrames = 480;
constexpr std::size_t kPacketCount = 32;
constexpr std::size_t kMaxReadFrames = 4096;
constexpr std::uint64_t kMaxPacketAgeNs = 100000000;
constexpr std::uint64_t kReaderDelayNs = 20000000;
constexpr std::uint64_t kMaxLeaseNs = 1000000000;
// Covers integer host-tick/nanosecond conversion at packet boundaries only;
// this is far below a 48k sample period and is not clock-drift resampling.
constexpr std::uint64_t kTimestampToleranceNs = 1000;

enum class Code { ok, invalid_path, invalid_owner, insecure_permissions, system_error, wrong_layout, writer_busy, epoch_exhausted };
struct Result {
    Code code = Code::ok;
    int sys_errno = 0;
    bool ok() const noexcept { return code == Code::ok; }
};
enum class Route { discord, alexa };
struct ReadStats {
    std::size_t copied_frames = 0;
    std::size_t silent_frames = 0;
    bool producer_stale = false;
    bool gate_closed = false;
};

std::string default_path(std::uint32_t owner_uid);

// Exactly one serialized producer. open/close may use filesystem/allocations;
// publish/gate calls use only lock-free mapped atomics and bounded loops.
class Writer {
public:
    Writer() = default;
    ~Writer();
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;
    Result open(const std::string& file_path, std::uint32_t owner_uid);
    void close() noexcept;
    bool publish(const float* discord, const float* alexa_ungated, std::size_t frames,
                 std::uint64_t first_sample_ns, std::uint64_t now_ns) noexcept;
    bool open_gate(std::uint64_t now_ns, std::uint64_t lease_ns = kMaxLeaseNs) noexcept;
    bool renew_gate(std::uint64_t now_ns, std::uint64_t lease_ns = kMaxLeaseNs) noexcept;
    void close_gate(std::uint64_t now_ns) noexcept;
    std::uint64_t session_epoch() const noexcept;
    std::uint64_t gate_epoch() const noexcept;
    std::uint64_t gate_deadline_ns() const noexcept;
private:
    int fd_ = -1;
    void* region_ = nullptr;
    std::uint64_t last_end_ns_ = 0, last_clock_ns_ = 0;
    bool has_packet_ = false;
};

// open/close outside callbacks. Concurrent reads are safe, but no read may
// overlap open/close. A mapping remains valid through producer restart because
// the writer reuses the fixed-size file/inode instead of replacing/truncating it.
class Reader {
public:
    Reader() = default;
    ~Reader();
    Reader(const Reader&) = delete;
    Reader& operator=(const Reader&) = delete;
    Result open(const std::string& file_path, std::uint32_t owner_uid);
    Result open_memory_entry(mach_port_t read_only_entry, std::uint64_t region_bytes) noexcept;
    Result export_readonly_memory_entry(mach_port_t& entry, std::uint64_t& region_bytes) const noexcept;
    void close() noexcept;
    bool ready() const noexcept;
    ReadStats read(Route route, float* output, std::size_t frames,
                   std::uint64_t first_sample_ns, std::uint64_t now_ns) const noexcept;
private:
    int fd_ = -1;
    const void* region_ = nullptr;
    bool mach_mapping_ = false;
    mutable std::atomic<std::uint64_t> revoked_gate_epoch_{0};
};

} // namespace audio_router::transport
