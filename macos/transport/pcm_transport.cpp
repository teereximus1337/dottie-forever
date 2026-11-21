#include "pcm_transport.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <mach/mach_vm.h>
#include <new>
#include <sys/acl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace audio_router::transport {
namespace {
constexpr std::uint64_t kMagic = 0x41524450434D3031ULL;
constexpr std::uint32_t kVersion = 1;
constexpr std::uint64_t kNs = 1000000000;
constexpr auto kMax = std::numeric_limits<std::uint64_t>::max();
static_assert(std::atomic<std::uint32_t>::is_always_lock_free, "IPC sample atoms must be lock-free");
static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "IPC metadata atoms must be lock-free");

struct alignas(64) Packet {
    std::atomic<std::uint64_t> stamp{0}, session{0}, sequence{0}, gate_epoch{0}, start_ns{0};
    std::atomic<std::uint32_t> frames{0};
    std::atomic<std::uint32_t> discord[kPacketFrames]{};
    std::atomic<std::uint32_t> alexa[kPacketFrames]{};
};
struct alignas(64) Region {
    std::atomic<std::uint64_t> magic{0};
    std::atomic<std::uint32_t> version{kVersion}, bytes{sizeof(Region)}, active{0};
    std::atomic<std::uint64_t> session{0}, heartbeat_ns{0}, latest_sequence{0};
    std::atomic<std::uint64_t> gate_version{0}, gate_epoch{0}, gate_deadline_ns{0};
    Packet packets[kPacketCount]{};
};
struct Gate { std::uint64_t version = 0, epoch = 0, deadline = 0; bool valid = false; };
struct Metadata { std::uint64_t stamp = 0, session = 0, sequence = 0, gate = 0, start = 0; std::uint32_t frames = 0; };

bool valid(const Region* r) noexcept {
    return r != nullptr && r->magic.load(std::memory_order_acquire) == kMagic &&
        r->version.load(std::memory_order_relaxed) == kVersion && r->bytes.load(std::memory_order_relaxed) == sizeof(Region);
}
Gate read_gate(const Region& r) noexcept {
    for (int retry = 0; retry < 3; ++retry) {
        Gate gate;
        gate.version = r.gate_version.load(std::memory_order_acquire);
        if ((gate.version & 1) != 0) continue;
        gate.epoch = r.gate_epoch.load(std::memory_order_relaxed);
        gate.deadline = r.gate_deadline_ns.load(std::memory_order_relaxed);
        gate.valid = gate.version == r.gate_version.load(std::memory_order_acquire);
        if (gate.valid) return gate;
    }
    return {};
}
bool write_gate(Region& r, std::uint64_t epoch, std::uint64_t deadline) noexcept {
    const auto version = r.gate_version.load(std::memory_order_relaxed);
    if (version > kMax - 2) { r.gate_deadline_ns.store(0, std::memory_order_release); return false; }
    r.gate_version.store(version + 1, std::memory_order_release);
    r.gate_deadline_ns.store(deadline, std::memory_order_relaxed);
    r.gate_epoch.store(epoch, std::memory_order_relaxed);
    r.gate_version.store(version + 2, std::memory_order_release);
    return true;
}
bool metadata(const Packet& p, Metadata& m) noexcept {
    m.stamp = p.stamp.load(std::memory_order_acquire);
    if (m.stamp == 0 || (m.stamp & 1) != 0) return false;
    m.session = p.session.load(std::memory_order_relaxed);
    m.sequence = p.sequence.load(std::memory_order_relaxed);
    m.gate = p.gate_epoch.load(std::memory_order_relaxed);
    m.start = p.start_ns.load(std::memory_order_relaxed);
    m.frames = p.frames.load(std::memory_order_relaxed);
    return m.frames >= 1 && m.frames <= kPacketFrames && m.stamp == p.stamp.load(std::memory_order_acquire);
}
Result system_error() noexcept { return {Code::system_error, errno}; }

Result private_acl(int fd) noexcept {
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (acl == nullptr && errno == ENOENT) return {};
    if (acl == nullptr) return system_error();
    acl_entry_t entry = nullptr;
    const bool has_entry = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) == 0;
    acl_free(acl);
    return has_entry ? Result{Code::insecure_permissions, 0} : Result{};
}

Result open_file(const std::string& path, std::uint32_t uid, bool writer, int& fd, bool& empty) {
    const auto separator = path.rfind('/');
    if (separator == std::string::npos || path.substr(separator + 1) != "pcm-v1.bin") return {Code::invalid_path, 0};
    const auto parent = path.substr(0, separator);
    if (parent.empty() || parent.find("/../") != std::string::npos) return {Code::invalid_path, 0};
    if (writer && static_cast<std::uint32_t>(geteuid()) != uid) return {Code::invalid_owner, 0};
    bool created_dir = false;
    if (writer) {
        if (mkdir(parent.c_str(), 0700) == 0) created_dir = true;
        else if (errno != EEXIST) return system_error();
    }
    const int directory = ::open(parent.c_str(), (writer ? O_RDONLY | O_DIRECTORY : O_SEARCH) | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return system_error();
    if (created_dir && fchmod(directory, 0700) != 0) { auto result = system_error(); ::close(directory); return result; }
    struct stat ds{};
    if (fstat(directory, &ds) != 0) { auto result = system_error(); ::close(directory); return result; }
    if (ds.st_uid != uid || (ds.st_mode & 0777) != 0700) { ::close(directory); return {Code::insecure_permissions, 0}; }
    auto acl_result = private_acl(directory);
    if (!acl_result.ok()) { ::close(directory); return acl_result; }
    bool created_file = false;
    if (writer) {
        fd = openat(directory, "pcm-v1.bin", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) created_file = true;
        else if (errno == EEXIST) fd = openat(directory, "pcm-v1.bin", O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    } else fd = openat(directory, "pcm-v1.bin", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    const auto open_errno = errno;
    ::close(directory);
    if (fd < 0) return {Code::system_error, open_errno};
    if (created_file && fchmod(fd, 0600) != 0) { auto result = system_error(); ::close(fd); fd = -1; return result; }
    struct stat fs{};
    if (fstat(fd, &fs) != 0) { auto result = system_error(); ::close(fd); fd = -1; return result; }
    if (!S_ISREG(fs.st_mode) || fs.st_uid != uid || (fs.st_mode & 0777) != 0600 || fs.st_nlink != 1) {
        ::close(fd); fd = -1; return {Code::insecure_permissions, 0};
    }
    acl_result = private_acl(fd);
    if (!acl_result.ok()) { ::close(fd); fd = -1; return acl_result; }
    if (writer && flock(fd, LOCK_EX | LOCK_NB) != 0) {
        const auto error = errno; ::close(fd); fd = -1;
        return {error == EWOULDBLOCK ? Code::writer_busy : Code::system_error, error};
    }
    empty = fs.st_size == 0;
    if (writer && empty && ftruncate(fd, sizeof(Region)) != 0) { auto result = system_error(); ::close(fd); fd = -1; return result; }
    if ((!writer || !empty) && fs.st_size != static_cast<off_t>(sizeof(Region))) {
        ::close(fd); fd = -1; return {Code::wrong_layout, 0};
    }
    return {};
}
bool normalized(float f) noexcept { return std::isfinite(f) && f >= -1 && f <= 1; }
std::uint32_t bits(float value) noexcept { std::uint32_t result; std::memcpy(&result, &value, sizeof(result)); return result; }
float sample(std::uint32_t value) noexcept { float result; std::memcpy(&result, &value, sizeof(result)); return result; }
}

std::string default_path(std::uint32_t uid) { return "/Users/Shared/AudioRouter-" + std::to_string(uid) + "/pcm-v1.bin"; }
Writer::~Writer() { close(); }
Reader::~Reader() { close(); }

Result Writer::open(const std::string& path, std::uint32_t uid) {
    close();
    bool empty = false;
    auto result = open_file(path, uid, true, fd_, empty);
    if (!result.ok()) return result;
    void* mapping = mmap(nullptr, sizeof(Region), PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (mapping == MAP_FAILED) { result = system_error(); ::close(fd_); fd_ = -1; return result; }
    auto* r = static_cast<Region*>(mapping);
    if (empty) new (r) Region{};
    if (!empty && !valid(r)) { munmap(mapping, sizeof(Region)); ::close(fd_); fd_ = -1; return {Code::wrong_layout, 0}; }
    const auto previous = r->session.load(std::memory_order_relaxed);
    const auto previous_gate = r->gate_epoch.load(std::memory_order_relaxed);
    if (previous == kMax || previous_gate == kMax) { munmap(mapping, sizeof(Region)); ::close(fd_); fd_ = -1; return {Code::epoch_exhausted, 0}; }
    r->magic.store(0, std::memory_order_release);
    r->active.store(0, std::memory_order_release);
    r->session.store(previous + 1, std::memory_order_relaxed);
    r->heartbeat_ns.store(0, std::memory_order_relaxed);
    r->latest_sequence.store(0, std::memory_order_relaxed);
    r->gate_version.store(0, std::memory_order_relaxed);
    // Gate epochs never repeat, including across producer sessions. This lets
    // concurrent readonly readers latch a rejected epoch with one atomic max.
    r->gate_epoch.store(previous_gate + 1, std::memory_order_relaxed);
    r->gate_deadline_ns.store(0, std::memory_order_relaxed);
    for (auto& packet : r->packets) packet.stamp.store(0, std::memory_order_release);
    r->active.store(1, std::memory_order_release);
    r->magic.store(kMagic, std::memory_order_release);
    region_ = r; last_clock_ns_ = last_end_ns_ = 0; has_packet_ = false;
    return {};
}
void Writer::close() noexcept {
    if (region_ != nullptr) {
        auto& r = *static_cast<Region*>(region_);
        r.active.store(0, std::memory_order_release);
        r.gate_deadline_ns.store(0, std::memory_order_release);
        r.latest_sequence.store(0, std::memory_order_release);
        r.heartbeat_ns.store(0, std::memory_order_release);
        for (auto& packet : r.packets) {
            packet.stamp.store(0, std::memory_order_release);
            for (std::size_t i = 0; i < kPacketFrames; ++i) {
                packet.discord[i].store(0, std::memory_order_relaxed);
                packet.alexa[i].store(0, std::memory_order_relaxed);
            }
        }
        munmap(region_, sizeof(Region)); region_ = nullptr;
    }
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
}

bool Writer::publish(const float* discord, const float* alexa, std::size_t frames,
                     std::uint64_t start, std::uint64_t now) noexcept {
    auto* r = static_cast<Region*>(region_);
    if (!valid(r) || discord == nullptr || alexa == nullptr || frames == 0 || frames > kPacketFrames ||
        now < last_clock_ns_ || start > now || now - start > kMaxPacketAgeNs ||
        (has_packet_ && start < last_end_ns_)) return false;
    const auto duration = (frames * kNs + kSampleRate - 1) / kSampleRate;
    if (start > kMax - duration) return false;
    for (std::size_t i = 0; i < frames; ++i) if (!normalized(discord[i]) || !normalized(alexa[i])) return false;
    const auto sequence = r->latest_sequence.load(std::memory_order_relaxed) + 1;
    if (sequence == 0 || sequence > (kMax - 2) / 2) return false;
    auto& p = r->packets[(sequence - 1) % kPacketCount];
    p.stamp.store(sequence * 2 + 1, std::memory_order_release);
    p.session.store(r->session.load(std::memory_order_relaxed), std::memory_order_relaxed);
    p.sequence.store(sequence, std::memory_order_relaxed);
    p.gate_epoch.store(r->gate_epoch.load(std::memory_order_relaxed), std::memory_order_relaxed);
    p.start_ns.store(start, std::memory_order_relaxed);
    p.frames.store(static_cast<std::uint32_t>(frames), std::memory_order_relaxed);
    for (std::size_t i = 0; i < frames; ++i) {
        p.discord[i].store(bits(discord[i]), std::memory_order_relaxed);
        p.alexa[i].store(bits(alexa[i]), std::memory_order_relaxed);
    }
    p.stamp.store(sequence * 2 + 2, std::memory_order_release);
    r->latest_sequence.store(sequence, std::memory_order_release);
    r->heartbeat_ns.store(now, std::memory_order_release);
    last_clock_ns_ = now; last_end_ns_ = start + duration; has_packet_ = true;
    return true;
}
bool Writer::open_gate(std::uint64_t now, std::uint64_t lease) noexcept {
    auto* r = static_cast<Region*>(region_);
    if (!valid(r)) return false;
    const auto epoch = r->gate_epoch.load(std::memory_order_relaxed);
    if (lease == 0 || lease > kMaxLeaseNs || now < last_clock_ns_ || now > kMax - lease || epoch == kMax) {
        close_gate(now); return false;
    }
    last_clock_ns_ = now;
    return write_gate(*r, epoch + 1, now + lease);
}
bool Writer::renew_gate(std::uint64_t now, std::uint64_t lease) noexcept {
    auto* r = static_cast<Region*>(region_);
    if (!valid(r)) return false;
    const auto deadline = r->gate_deadline_ns.load(std::memory_order_relaxed);
    if (lease == 0 || lease > kMaxLeaseNs || now < last_clock_ns_ || now > kMax - lease || deadline == 0 || now >= deadline) {
        close_gate(now); return false;
    }
    last_clock_ns_ = now;
    return write_gate(*r, r->gate_epoch.load(std::memory_order_relaxed), now + lease);
}
void Writer::close_gate(std::uint64_t now) noexcept {
    auto* r = static_cast<Region*>(region_);
    if (!valid(r)) return;
    last_clock_ns_ = std::max(last_clock_ns_, now);
    const auto epoch = r->gate_epoch.load(std::memory_order_relaxed);
    write_gate(*r, epoch == kMax ? epoch : epoch + 1, 0);
}
std::uint64_t Writer::session_epoch() const noexcept { return region_ ? static_cast<const Region*>(region_)->session.load(std::memory_order_acquire) : 0; }
std::uint64_t Writer::gate_epoch() const noexcept { return region_ ? static_cast<const Region*>(region_)->gate_epoch.load(std::memory_order_acquire) : 0; }
std::uint64_t Writer::gate_deadline_ns() const noexcept { return region_ ? static_cast<const Region*>(region_)->gate_deadline_ns.load(std::memory_order_acquire) : 0; }

Result Reader::open(const std::string& path, std::uint32_t uid) {
    close(); bool empty = false;
    auto result = open_file(path, uid, false, fd_, empty);
    if (!result.ok()) return result;
    void* mapping = mmap(nullptr, sizeof(Region), PROT_READ, MAP_SHARED, fd_, 0);
    if (mapping == MAP_FAILED) { result = system_error(); ::close(fd_); fd_ = -1; return result; }
    if (!valid(static_cast<const Region*>(mapping))) { munmap(mapping, sizeof(Region)); ::close(fd_); fd_ = -1; return {Code::wrong_layout, 0}; }
    region_ = mapping; return {};
}
void Reader::close() noexcept {
    if (region_) {
        if (mach_mapping_) mach_vm_deallocate(mach_task_self(), reinterpret_cast<mach_vm_address_t>(region_), sizeof(Region));
        else munmap(const_cast<void*>(region_), sizeof(Region));
        region_ = nullptr; mach_mapping_ = false;
    }
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
    revoked_gate_epoch_.store(0, std::memory_order_relaxed);
}
Result Reader::export_readonly_memory_entry(mach_port_t& entry, std::uint64_t& region_bytes) const noexcept {
    entry = MACH_PORT_NULL; region_bytes = 0;
    if (!ready()) return {Code::wrong_layout, 0};
    memory_object_size_t size = sizeof(Region);
    const auto status = mach_make_memory_entry_64(mach_task_self(), &size,
        reinterpret_cast<memory_object_offset_t>(region_), VM_PROT_READ, &entry, MACH_PORT_NULL);
    if (status != KERN_SUCCESS) return {Code::system_error, status};
    if (size < sizeof(Region)) { mach_port_deallocate(mach_task_self(), entry); entry = MACH_PORT_NULL; return {Code::wrong_layout, 0}; }
    region_bytes = sizeof(Region);
    return {};
}
Result Reader::open_memory_entry(mach_port_t entry, std::uint64_t bytes) noexcept {
    close();
    if (entry == MACH_PORT_NULL || bytes != sizeof(Region)) return {Code::wrong_layout, 0};
    mach_vm_address_t mapped = 0;
    const auto status = mach_vm_map(mach_task_self(), &mapped, sizeof(Region), 0, VM_FLAGS_ANYWHERE,
        entry, 0, FALSE, VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE);
    if (status != KERN_SUCCESS) return {Code::system_error, status};
    const auto* candidate = reinterpret_cast<const Region*>(mapped);
    if (!valid(candidate)) { mach_vm_deallocate(mach_task_self(), mapped, sizeof(Region)); return {Code::wrong_layout, 0}; }
    region_ = candidate; mach_mapping_ = true;
    return {};
}
bool Reader::ready() const noexcept { return valid(static_cast<const Region*>(region_)); }

ReadStats Reader::read(Route route, float* output, std::size_t frames,
                       std::uint64_t start, std::uint64_t now) const noexcept {
    ReadStats stats{0, frames, false, false};
    if (!output || frames == 0 || frames > kMaxReadFrames) return stats;
    std::fill_n(output, frames, 0.0F);
    const auto* r = static_cast<const Region*>(region_);
    if (!valid(r)) { stats.producer_stale = true; return stats; }
    const auto gate = read_gate(*r);
    auto revoke = [&]() noexcept {
        if (!gate.valid) return;
        auto observed = revoked_gate_epoch_.load(std::memory_order_relaxed);
        while (observed < gate.epoch && !revoked_gate_epoch_.compare_exchange_weak(observed, gate.epoch,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {}
    };
    if (r->active.load(std::memory_order_acquire) == 0) { revoke(); stats.producer_stale = true; return stats; }
    const auto heartbeat = r->heartbeat_ns.load(std::memory_order_acquire);
    const auto session = r->session.load(std::memory_order_acquire);
    const auto latest = r->latest_sequence.load(std::memory_order_acquire);
    if (latest == 0 || heartbeat > now || now - heartbeat > kMaxPacketAgeNs) {
        if (latest != 0) revoke();
        stats.producer_stale = true; return stats;
    }
    if (route == Route::alexa && (!gate.valid || gate.deadline == 0 || now >= gate.deadline ||
                                gate.epoch <= revoked_gate_epoch_.load(std::memory_order_acquire))) {
        stats.gate_closed = true; return stats;
    }
    for (std::size_t i = 0; i < frames;) {
        const auto offset = i * kNs / kSampleRate;
        if (start > kMax - offset || now > kMax - offset) break;
        const auto target = start + offset;
        if (target > now || now - target > kMaxPacketAgeNs) { ++i; continue; }
        const Packet* chosen = nullptr; Metadata best{};
        for (const auto& packet : r->packets) {
            Metadata m;
            if (!metadata(packet, m) || m.session != session || m.sequence <= best.sequence) continue;
            if (m.start > target && m.start - target > kTimestampToleranceNs) continue;
            const auto duration = (m.frames * kNs + kSampleRate - 1) / kSampleRate;
            if (target >= m.start && target - m.start >= duration) continue;
            if (route == Route::alexa && m.gate != gate.epoch) continue;
            chosen = &packet; best = m;
        }
        if (chosen == nullptr) { ++i; continue; }
        // Samples own their timestamp intervals. Nearest-sample rounding can
        // produce index==frames while target still belongs to this packet,
        // inserting one zero per packet for a half-sample-offset HAL clock.
        // Invert floor(index * ns / rate), including its sub-nanosecond rounding:
        // max index with floor(index * ns / rate) <= delta is
        // ((delta + 1) * rate - 1) / ns. delta is bounded by packet duration.
        const auto index = target < best.start ? 0 : ((target - best.start) * kSampleRate + kSampleRate - 1) / kNs;
        if (index >= best.frames) { ++i; continue; }
        const auto count = std::min(frames - i, static_cast<std::size_t>(best.frames - index));
        const auto* samples = route == Route::discord ? chosen->discord : chosen->alexa;
        std::size_t copied = 0;
        for (std::size_t n = 0; n < count; ++n) {
            const auto sample_offset = (i + n) * kNs / kSampleRate;
            if (start > kMax - sample_offset || start + sample_offset > now || now - (start + sample_offset) > kMaxPacketAgeNs)
                continue;
            if (now > kMax - sample_offset || (route == Route::alexa && now + sample_offset >= gate.deadline)) {
                stats.gate_closed = route == Route::alexa; continue;
            }
            const auto value = sample(samples[index + n].load(std::memory_order_relaxed));
            if (normalized(value)) { output[i + n] = value; ++copied; }
        }
        if (chosen->stamp.load(std::memory_order_acquire) != best.stamp) {
            std::fill_n(output + i, count, 0.0F); copied = 0;
        }
        stats.copied_frames += copied; i += count;
    }
    const auto final_gate = route == Route::alexa ? read_gate(*r) : Gate{};
    if (!valid(r) || r->active.load(std::memory_order_acquire) == 0 || r->session.load(std::memory_order_acquire) != session ||
        (route == Route::alexa && (!final_gate.valid || final_gate.epoch != gate.epoch || final_gate.deadline == 0 || now >= final_gate.deadline ||
                                 final_gate.epoch <= revoked_gate_epoch_.load(std::memory_order_acquire)))) {
        std::fill_n(output, frames, 0.0F); stats.copied_frames = 0;
    }
    stats.silent_frames = frames - stats.copied_frames;
    return stats;
}

} // namespace audio_router::transport
