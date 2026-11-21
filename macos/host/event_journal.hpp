#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

namespace audio_router::host {
enum class DetectorProfile { unknown, gigaspeech_fp32_paths8 };
inline const char* profile_name(DetectorProfile value) noexcept { return value == DetectorProfile::gigaspeech_fp32_paths8 ? "gigaspeech3.3m-fp32-paths8-v1" : "unknown"; }
#define AR_EVENT_KINDS(X) X(session_started) X(session_stopped) X(wake_detected) X(wake_admitted) X(wake_rejected) X(wake_cancelled) X(wake_completed) X(standby_detected) X(standby_requested) X(gate_opened) X(gate_closed) X(detector_restart) X(detector_ready) X(detector_failed) X(detector_health) X(source_fault) X(source_health) X(controller_health) X(scheduler_discontinuity) X(health_sample) X(detector_batch)
#define AR_EVENT_REASONS(X) X(none) X(startup) X(shutdown) X(manual) X(acoustic) X(configuration) X(configuration_rejected) X(capture_changed) X(controller_changed) X(capture_and_controller_changed) X(render_slip) X(capture_discontinuity) X(output_fault) X(detector_unhealthy) X(capture_unhealthy) X(controller_expired) X(standby_priority) X(stale_generation) X(stale_progress) X(stale_audio) X(coalesced) X(service_failed) X(gate_already_open) X(gate_not_opened) X(lease_expired) X(worker_backpressure) X(worker_eof) X(worker_error) X(worker_exit) X(worker_pcm) X(worker_pipe) X(worker_protocol) X(worker_read) X(worker_spawn) X(worker_timeout) X(worker_write) X(worker_configuration) X(worker_input_backpressure) X(worker_progress_timeout) X(worker_queue_stale) X(worker_restart_backpressure) X(worker_service_failure) X(worker_snapshot_backpressure) X(worker_start_timeout) X(worker_thread)
#define AR_ENUM_VALUE(value) value,
enum class EventKind { AR_EVENT_KINDS(AR_ENUM_VALUE) };
enum class EventReason { AR_EVENT_REASONS(AR_ENUM_VALUE) };
#undef AR_ENUM_VALUE
inline const char* event_name(EventKind kind) noexcept {
    switch (kind) {
#define AR_NAME_CASE(value) case EventKind::value: return #value;
    AR_EVENT_KINDS(AR_NAME_CASE)
#undef AR_NAME_CASE
    } return "unknown";
}
inline const char* reason_name(EventReason reason) noexcept {
    switch (reason) {
#define AR_REASON_CASE(value) case EventReason::value: return #value;
    AR_EVENT_REASONS(AR_REASON_CASE)
#undef AR_REASON_CASE
    } return "unknown";
}
inline EventReason detector_reason(const char* error) noexcept {
#define AR_MATCH_REASON(value) if (std::strcmp(error, #value) == 0) return EventReason::value;
    AR_EVENT_REASONS(AR_MATCH_REASON)
#undef AR_MATCH_REASON
    return EventReason::service_failed;
}
#undef AR_EVENT_KINDS
#undef AR_EVENT_REASONS

// No arbitrary text can enter an event: no audio, transcripts, phrase strings,
// filenames, selected app identities, or device identifiers are representable.
struct HostEvent {
    EventKind kind = EventKind::session_started;
    EventReason reason = EventReason::none;
    DetectorProfile model_profile = DetectorProfile::unknown;
    std::uint64_t monotonic_ns = 0, sequence = 0, generation = 0, attempt = 0;
    std::int64_t wall_ns = 0;
    std::uint64_t action_generation = 0, action_sequence = 0, action_frames = 0;
    std::uint64_t queued_frames = 0, gate_epoch = 0, wake_count = 0, standby_count = 0, coalesced_count = 0, last_action_sequence = 0, detector_events_dropped = 0;
    std::int64_t progress_age_ms = -1, audio_age_ms = -1;
    std::uint32_t health = 0, mic_peak_milli = 0, listener_peak_milli = 0;
    std::int32_t source = -1, code = 0, os_status = 0, source_stage = 0;
    bool gate_open = false;
};
template<class Value, std::size_t Capacity> class EventQueue {
public:
    bool push(const Value& value) noexcept {
        const auto w = write_.load(std::memory_order_relaxed);
        if (w - read_.load(std::memory_order_acquire) == Capacity) return false;
        slots_[w % Capacity] = value; write_.store(w + 1, std::memory_order_release); return true;
    }
    bool pop(Value& value) noexcept {
        const auto r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        value = slots_[r % Capacity]; read_.store(r + 1, std::memory_order_release); return true;
    }
    std::uint64_t size() const noexcept {
        const auto r = read_.load(std::memory_order_acquire), w = write_.load(std::memory_order_acquire);
        return std::min<std::uint64_t>(w - r, Capacity);
    }
private:
    std::array<Value, Capacity> slots_{};
    std::atomic<std::uint64_t> read_{0}, write_{0};
};

// Only the journal worker calls filesystem/formatting operations. Paths are
// fixed within a verified private directory; existing symlinks/hardlinks and
// non-private files are rejected rather than followed or repaired.
class PrivateEventFiles {
public:
    explicit PrivateEventFiles(std::string directory, std::size_t limit) : directory_(std::move(directory)), limit_(limit) {}
    ~PrivateEventFiles() { if (file_ >= 0) ::close(file_); if (directory_fd_ >= 0) ::close(directory_fd_); }
    bool open() {
        if (directory_.empty() || directory_[0] != '/') { errno = EINVAL; return false; }
        directory_fd_ = ::open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        for (std::size_t begin = 1; directory_fd_ >= 0 && begin < directory_.size();) {
            const auto slash = directory_.find('/', begin);
            const auto part = directory_.substr(begin, slash == std::string::npos ? std::string::npos : slash - begin);
            if (part.empty() || part == "." || part == "..") { errno = EINVAL; return false; }
            const int next = openat(directory_fd_, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            const int error = errno; ::close(directory_fd_); directory_fd_ = next; errno = error;
            if (slash == std::string::npos) break;
            begin = slash + 1;
        }
        struct stat info{};
        if (directory_fd_ < 0) return false;
        if (fstat(directory_fd_, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0777) != 0700) { errno = EPERM; return false; }
        for (const auto* name : names_) if (!safe(name)) return false;
        return open_current();
    }
    bool write(const char* bytes, std::size_t size) {
        if (size > limit_) { errno = EFBIG; return false; }
        if (bytes_ + size > limit_ && !rotate()) return false;
        std::size_t sent = 0;
        while (sent < size) {
            const auto result = ::write(file_, bytes + sent, size - sent);
            if (result < 0 && errno == EINTR) continue;
            if (result <= 0) return false;
            sent += static_cast<std::size_t>(result);
        }
        bytes_ += size; return true;
    }
private:
    bool safe(const char* name) {
        struct stat info{};
        if (fstatat(directory_fd_, name, &info, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
        if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077) != 0 || info.st_size < 0 || static_cast<std::uint64_t>(info.st_size) > limit_) { errno = EPERM; return false; }
        return true;
    }
    bool open_current() {
        file_ = openat(directory_fd_, names_[0], O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
        struct stat info{};
        if (file_ < 0) return false;
        if (fstat(file_, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077) != 0 || info.st_size < 0 || static_cast<std::uint64_t>(info.st_size) > limit_) { errno = EPERM; return false; }
        bytes_ = static_cast<std::size_t>(info.st_size); return true;
    }
    bool rotate() {
        for (const auto* name : names_) if (!safe(name)) return false;
        ::close(file_); file_ = -1;
        if (unlinkat(directory_fd_, names_[3], 0) != 0 && errno != ENOENT) return false;
        for (int i = 2; i >= 0; --i) if (renameat(directory_fd_, names_[i], directory_fd_, names_[i + 1]) != 0 && errno != ENOENT) return false;
        return open_current();
    }
    inline static constexpr std::array<const char*,4> names_{{"host-events.jsonl", "host-events.1.jsonl", "host-events.2.jsonl", "host-events.3.jsonl"}};
    std::string directory_;
    std::size_t limit_, bytes_ = 0;
    int directory_fd_ = -1, file_ = -1;
};

template<class Files = PrivateEventFiles> class BasicEventJournal {
public:
    struct Stats { bool active = false; std::uint64_t queued = 0, written = 0, dropped = 0, errors = 0; int last_errno = 0; };
    static constexpr std::size_t kCapacity = 256, kFileBytes = 1024 * 1024;
    ~BasicEventJournal() { stop(); }
    void start(const std::string& directory, std::uint64_t monotonic, std::size_t limit = kFileBytes) noexcept {
        if (state_ || closed_ || startup_failed_) return;
        try {
            state_ = std::make_shared<State>(directory, monotonic, limit);
            worker_ = std::thread([state = state_] { run(state); });
        } catch (...) { startup_failed_ = true; if (state_) state_->failed.store(true); }
    }
    void append(HostEvent event) noexcept {
        event.sequence = ++sequence_;
        event.wall_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        if (!state_) { ++unavailable_drops_; return; }
        if (closed_ || state_->failed.load(std::memory_order_acquire) || !state_->queue.push(event)) state_->dropped.fetch_add(1, std::memory_order_relaxed);
    }
    Stats stats() const noexcept {
        if (!state_) return {false, 0, 0, unavailable_drops_, startup_failed_ ? 1U : 0U, 0};
        return {state_->active.load(), state_->queue.size(), state_->written.load(), state_->dropped.load(), state_->errors.load() + (startup_failed_ ? 1U : 0U), state_->last_errno.load()};
    }
    void stop() noexcept {
        closed_ = true;
        if (!state_ || !worker_.joinable()) return;
        state_->exit.store(true, std::memory_order_release);
        std::unique_lock<std::mutex> hold(state_->done_lock);
        const bool done = state_->done_changed.wait_for(hold, std::chrono::milliseconds(250), [&] { return state_->done; });
        hold.unlock(); if (done) worker_.join(); else worker_.detach();
    }
private:
    struct State {
        State(std::string directory_value, std::uint64_t mono, std::size_t limit_value) : directory(std::move(directory_value)), limit(limit_value), monotonic(mono) {
            std::array<unsigned char,16> random{}; arc4random_buf(random.data(), random.size());
            for (std::size_t i = 0; i < random.size(); ++i) std::snprintf(session.data() + i * 2, 3, "%02x", random[i]);
        }
        const std::string directory;
        const std::size_t limit;
        const std::uint64_t monotonic;
        std::array<char,33> session{};
        EventQueue<HostEvent,kCapacity> queue;
        std::atomic<bool> exit{false}, active{false}, failed{false};
        std::atomic<std::uint64_t> written{0}, dropped{0}, errors{0};
        std::atomic<int> last_errno{0};
        std::mutex done_lock; std::condition_variable done_changed; bool done = false;
    };
    static bool write_event(State& state, Files& files, const HostEvent& event) {
        const auto elapsed = event.monotonic_ns >= state.monotonic ? event.monotonic_ns - state.monotonic : 0;
        const auto milliseconds = event.wall_ns / 1000000;
        const std::time_t seconds = static_cast<std::time_t>(milliseconds / 1000);
        struct tm utc{}; gmtime_r(&seconds, &utc);
        std::array<char,32> date{}; std::strftime(date.data(), date.size(), "%Y-%m-%dT%H:%M:%S", &utc);
        std::array<char,2048> line{};
        const int size = std::snprintf(line.data(), line.size(),
            "{\"schema\":1,\"component\":\"host\",\"session\":\"%s\",\"utc\":\"%s.%03lldZ\",\"monotonic_ns\":%llu,\"elapsed_ms\":%llu,\"sequence\":%llu,\"event\":\"%s\",\"reason\":\"%s\",\"generation\":%llu,\"model_profile\":\"%s\",\"attempt\":%llu,\"action_generation\":%llu,\"action_sequence\":%llu,\"action_frames\":%llu,\"progress_age_ms\":%lld,\"audio_age_ms\":%lld,\"queued_frames\":%llu,\"health\":%u,\"mic_peak_milli\":%u,\"listener_peak_milli\":%u,\"gate_open\":%s,\"gate_epoch\":%llu,\"source_index\":%d,\"code\":%d,\"os_status\":%d,\"dropped\":%llu,\"wake_count\":%llu,\"standby_count\":%llu,\"coalesced_count\":%llu,\"last_action_sequence\":%llu,\"detector_events_dropped\":%llu,\"source_stage\":%d}\n",
            state.session.data(), date.data(), static_cast<long long>(milliseconds % 1000),
            ull(event.monotonic_ns), ull(elapsed / 1000000), ull(event.sequence), event_name(event.kind), reason_name(event.reason),
            ull(event.generation), profile_name(event.model_profile), ull(event.attempt), ull(event.action_generation), ull(event.action_sequence), ull(event.action_frames),
            static_cast<long long>(event.progress_age_ms), static_cast<long long>(event.audio_age_ms), ull(event.queued_frames), event.health, event.mic_peak_milli, event.listener_peak_milli, event.gate_open ? "true" : "false", ull(event.gate_epoch), event.source, event.code, event.os_status, ull(state.dropped.load()), ull(event.wake_count), ull(event.standby_count), ull(event.coalesced_count), ull(event.last_action_sequence), ull(event.detector_events_dropped), event.source_stage);
        if (size <= 0 || static_cast<std::size_t>(size) >= line.size()) { errno = EOVERFLOW; return false; }
        return files.write(line.data(), static_cast<std::size_t>(size));
    }
    static unsigned long long ull(std::uint64_t value) { return static_cast<unsigned long long>(value); }
    static void fail(State& state) noexcept {
        state.last_errno.store(errno); state.errors.fetch_add(1); state.failed.store(true, std::memory_order_release); state.active.store(false);
    }
    static void run(const std::shared_ptr<State>& state) noexcept {
        bool in_flight = false;
        try {
            // File construction, close and destruction also belong to this
            // thread; a blocked close cannot escape the bounded stop wait.
            Files files(state->directory, state->limit);
            if (!files.open()) fail(*state);
            else state->active.store(true);
            for (;;) {
                HostEvent event{};
                while (state->queue.pop(event)) {
                    in_flight = true;
                    if (state->failed.load()) state->dropped.fetch_add(1);
                    else if (write_event(*state, files, event)) state->written.fetch_add(1);
                    else { state->dropped.fetch_add(1); fail(*state); }
                    in_flight = false;
                }
                if (state->exit.load(std::memory_order_acquire)) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        } catch (...) {
            fail(*state); if (in_flight) state->dropped.fetch_add(1);
            for (;;) {
                HostEvent value{}; while (state->queue.pop(value)) state->dropped.fetch_add(1);
                if (state->exit.load(std::memory_order_acquire)) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }
        state->active.store(false);
        { std::lock_guard<std::mutex> hold(state->done_lock); state->done = true; }
        state->done_changed.notify_all();
    }
    std::shared_ptr<State> state_;
    std::thread worker_;
    std::uint64_t sequence_ = 0, unavailable_drops_ = 0;
    bool closed_ = false, startup_failed_ = false;
};
using EventJournal = BasicEventJournal<>;
} // namespace audio_router::host
