#pragma once
#include "keyword_process.hpp"
#include "event_journal.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace audio_router::host {

// One producer and one consumer. Published slots are immutable until consumed;
// neither endpoint allocates, waits, or retries when the bounded queue is full.
template<class Value, std::size_t Capacity> class KeywordQueue {
public:
    bool push(const Value& value) noexcept {
        const auto write = write_.load(std::memory_order_relaxed);
        if (write - read_.load(std::memory_order_acquire) == Capacity) return false;
        slots_[write % Capacity] = value;
        write_.store(write + 1, std::memory_order_release); return true;
    }
    bool pop(Value& value) noexcept {
        const auto read = read_.load(std::memory_order_relaxed);
        if (read == write_.load(std::memory_order_acquire)) return false;
        value = slots_[read % Capacity];
        read_.store(read + 1, std::memory_order_release); return true;
    }
private:
    std::array<Value, Capacity> slots_{};
    std::atomic<std::uint64_t> read_{0}, write_{0};
};

// The scheduler owns this facade. Its worker owns all process creation, pipe
// I/O, JSON and decoder objects. Fixed queues hold only short-lived listener PCM.
// Backend injection permits deterministic stalled-start/pipe tests, never a
// production command or an alternative capture source.
template<class Backend> class BasicKeywordService {
public:
    using Action = typename Backend::Action;
    using Clock = std::uint64_t (*)();
    struct Observation {
        Action action = Action::none;
        EventReason reason = EventReason::none;
        std::uint64_t generation = 0, sequence = 0, frames = 0, progress = 0, audio = 0;
    };
    struct Batch {
        std::uint64_t generation = 0, wakes = 0, standbys = 0, last_sequence = 0, selected_sequence = 0;
        EventReason reason = EventReason::none;
    };
    static constexpr std::size_t kFrames = 480, kPCMCapacity = 16;
    explicit BasicKeywordService(Clock clock) : clock_(clock) {}
    ~BasicKeywordService() { stop(); }
    bool start(const std::string& executable, const std::string& model,
               const std::string& wake, const std::string& standby, std::uint64_t now) {
        ++generation_; submitted_ = 0; latest_ = {}; local_error_ = nullptr;
        started_ = now; ready_stamp_ = 0;
        if (closed_ || wake.size() > 256 || standby.size() > 256) { local_error_ = "worker_configuration"; return false; }
        if (state_ && state_->service_exception.load(std::memory_order_acquire)) { local_error_ = "worker_service_failure"; return false; }
        if (!state_) {
            try {
                state_ = std::make_shared<State>(executable, model, clock_);
                worker_ = std::thread([state = state_] { run(state); });
            } catch (...) {
                if (state_) state_->service_exception.store(true, std::memory_order_release);
                local_error_ = "worker_thread"; return false;
            }
        }
        state_->requested.store(generation_, std::memory_order_release);
        if (state_->executable != executable || state_->model != model) { local_error_ = "worker_configuration"; return false; }
        Restart request{}; request.generation = generation_; request.started = now;
        std::memcpy(request.wake.data(), wake.data(), wake.size());
        std::memcpy(request.standby.data(), standby.data(), standby.size());
        if (!state_->restarts.push(request)) { local_error_ = "worker_restart_backpressure"; return false; }
        return true;
    }
    // Called only after closing the final assistant gate. A stalled OS spawn
    // cannot hang shutdown: its detached state owns everything it may touch and
    // will kill/reap its decoder when that call returns. No Host pointer escapes.
    void stop() noexcept {
        closed_ = true;
        if (!state_) return;
        state_->exit.store(true, std::memory_order_release);
        if (worker_.joinable()) {
            std::unique_lock<std::mutex> hold(state_->done_lock);
            const bool done = state_->done_changed.wait_for(hold, std::chrono::milliseconds(250), [&] { return state_->done; });
            hold.unlock();
            if (done) worker_.join(); else worker_.detach();
        }
    }
    Action poll(std::uint64_t now) noexcept {
        if (!state_) return Action::none;
        // A late READY/progress snapshot must not revive a generation whose
        // scheduler-owned deadline already expired while its worker was stuck.
        if (!local_error_) local_error_ = deadline_error();
        observation_count_ = observation_read_ = 0;
        batch_count_ = batch_read_ = 0;
        Snapshot value{}; Action action = Action::none;
        std::size_t admitted = observations_.size();
        for (unsigned i = 0; i < 16 && state_->snapshots.pop(value); ++i) {
            // The worker may publish after the caller sampled its render time.
            // Read the clock after acquiring this immutable snapshot; never
            // mistake concurrent completion for a future/stale command.
            const auto observed = std::max(now, clock_());
            const bool current = value.generation == generation_;
            if (value.raw_wakes || value.raw_standbys) {
                auto& batch = batches_[batch_count_++];
                batch = {value.generation, value.raw_wakes, value.raw_standbys, value.last_action_sequence, value.action_sequence,
                    !current ? EventReason::stale_generation : value.failed ? EventReason::service_failed : value.raw_wakes && value.raw_standbys ? EventReason::standby_priority : value.raw_wakes + value.raw_standbys > 1 ? EventReason::coalesced : EventReason::none};
            }
            if (current) {
                latest_ = value;
                if (value.ready && !ready_stamp_) ready_stamp_ = value.published;
            }
            if (value.action == Action::none) continue;
            auto& observation = observations_[observation_count_++];
            observation = {value.action, EventReason::none, value.generation, value.action_sequence, value.action_frames, value.action_progress, current ? audio_stamp(value.action_frames) : 0};
            if (!current) { observation.reason = EventReason::stale_generation; continue; }
            if (value.action == Action::standby) {
                if (admitted < observations_.size()) observations_[admitted].reason = action == Action::wake ? EventReason::standby_priority : EventReason::coalesced;
                action = Action::standby; admitted = observation_count_ - 1;
            } else if (action == Action::standby) observation.reason = EventReason::standby_priority;
            else if (!fresh_time(value.action_progress, observed)) observation.reason = EventReason::stale_progress;
            else if (!fresh_audio(value.action_frames, observed)) observation.reason = EventReason::stale_audio;
            else {
                if (admitted < observations_.size()) observations_[admitted].reason = EventReason::coalesced;
                action = Action::wake; admitted = observation_count_ - 1;
            }
        }
        if (failed()) {
            if (admitted < observations_.size()) observations_[admitted].reason = EventReason::service_failed;
            return Action::none;
        }
        return action;
    }
    bool take_observation(Observation& value) noexcept {
        if (observation_read_ == observation_count_) return false;
        value = observations_[observation_read_++]; return true;
    }
    bool take_batch(Batch& value) noexcept {
        if (batch_read_ == batch_count_) return false;
        value = batches_[batch_read_++]; return true;
    }
    std::uint64_t dropped_observations() const noexcept { return state_ ? state_->dropped_observations.load(std::memory_order_relaxed) : 0; }
    std::uint64_t queued_frames() const noexcept { return submitted_ >= frames() ? submitted_ - frames() : 0; }
    std::uint64_t progress_time_ns() const noexcept { return latest_.generation == generation_ ? latest_.progress : 0; }
    DetectorProfile model_profile() const noexcept { return latest_.generation == generation_ ? latest_.model_profile : DetectorProfile::unknown; }
    void feed(const float* samples, std::size_t frames) noexcept {
        if (!ready()) return;
        if (!samples || frames != kFrames || !std::all_of(samples, samples + frames, [](float x) { return std::isfinite(x) && std::abs(x) <= 1; })) {
            local_error_ = "worker_pcm"; return;
        }
        PCM value{}; value.generation = generation_; value.stamp = clock_();
        std::copy_n(samples, kFrames, value.samples.begin());
        if (!state_->pcm.push(value)) { local_error_ = "worker_input_backpressure"; return; }
        submitted_ += kFrames / 3;
        auto& stamp = stamps_[((submitted_ - 1) / (kFrames / 3)) % stamps_.size()];
        stamp = {submitted_, value.stamp};
    }
    bool healthy(std::uint64_t now) const noexcept {
        // latest_ may have been acquired after the scheduler captured `now`.
        // A fresh clock also prevents an old caller timestamp from extending
        // any real progress/PCM freshness deadline; the bounds stay unchanged.
        const auto observed = std::max(now, clock_());
        return ready() && fresh_time(latest_.progress, observed) && fresh_time(latest_.published, observed) &&
            submitted_ >= latest_.frames && submitted_ - latest_.frames <= 8000 && fresh_audio(latest_.frames, observed);
    }
    bool ready() const noexcept { return !failed() && latest_.generation == generation_ && latest_.ready; }
    bool failed() const noexcept { return local_error_ || deadline_error() || (state_ && (state_->service_exception.load(std::memory_order_acquire) || state_->fault_generation.load(std::memory_order_acquire) == generation_)) ||
        (latest_.generation == generation_ && latest_.failed); }
    std::uint64_t frames() const noexcept { return latest_.generation == generation_ ? latest_.frames : 0; }
    std::uint64_t sequence() const noexcept { return latest_.generation == generation_ ? latest_.sequence : 0; }
    std::string error() const { return error_name(); }
    const char* error_name() const noexcept {
        if (local_error_) return local_error_;
        if (const auto deadline = deadline_error()) return deadline;
        if (state_ && state_->service_exception.load(std::memory_order_acquire)) return "worker_service_failure";
        if (state_ && state_->fault_generation.load(std::memory_order_acquire) == generation_)
            return "worker_snapshot_backpressure";
        return latest_.generation == generation_ ? latest_.error.data() : "";
    }
private:
    struct Restart {
        std::uint64_t generation = 0, started = 0;
        std::array<char,257> wake{}, standby{};
    };
    struct PCM { std::uint64_t generation = 0, stamp = 0; std::array<float,kFrames> samples{}; };
    struct Snapshot {
        std::uint64_t generation = 0, published = 0, progress = 0, frames = 0, sequence = 0, action_frames = 0, action_progress = 0, action_sequence = 0;
        std::uint64_t raw_wakes = 0, raw_standbys = 0, last_action_sequence = 0;
        bool ready = false, failed = false;
        DetectorProfile model_profile = DetectorProfile::unknown;
        Action action = Action::none;
        std::array<char,64> error{};
    };
    struct State {
        State(std::string executable_value, std::string model_value, Clock value) : executable(std::move(executable_value)), model(std::move(model_value)), clock(value) {}
        const std::string executable, model;
        Clock clock;
        KeywordQueue<Restart,4> restarts;
        KeywordQueue<PCM,kPCMCapacity> pcm;
        KeywordQueue<Snapshot,16> snapshots;
        std::atomic<std::uint64_t> requested{0}, fault_generation{0};
        std::atomic<std::uint64_t> dropped_observations{0};
        std::atomic<bool> exit{false}, service_exception{false};
        std::mutex done_lock;
        std::condition_variable done_changed;
        bool done = false;
    };
    static bool fresh_time(std::uint64_t stamp, std::uint64_t now) noexcept { return stamp && now >= stamp && now - stamp <= 500000000; }
    const char* deadline_error() const noexcept {
        if (!generation_) return nullptr;
        const auto current = clock_();
        if (!ready_stamp_) return current >= started_ && current - started_ > 15000000000ULL ? "worker_start_timeout" : nullptr;
        const auto progress = latest_.progress ? latest_.progress : ready_stamp_;
        return current >= progress && current - progress > 750000000 ? "worker_progress_timeout" : nullptr;
    }
    bool fresh_audio(std::uint64_t frames, std::uint64_t now) const noexcept {
        return fresh_time(audio_stamp(frames), now);
    }
    std::uint64_t audio_stamp(std::uint64_t frames) const noexcept {
        if (!frames || frames > submitted_) return 0;
        const auto block = (frames - 1) / (kFrames / 3);
        const auto& stamp = stamps_[block % stamps_.size()];
        return stamp.end == (block + 1) * (kFrames / 3) ? stamp.time : 0;
    }
    static void run(const std::shared_ptr<State>& state) noexcept {
        try {
        @autoreleasepool {
            Backend process;
            std::uint64_t generation = 0, next_publish = 0;
            const char* service_error = nullptr;
            while (!state->exit.load(std::memory_order_acquire)) {
                @autoreleasepool {
                    Restart request{}, newest{};
                    for (unsigned i = 0; i < 4 && state->restarts.pop(request); ++i) newest = request;
                    if (newest.generation && newest.generation == state->requested.load(std::memory_order_acquire)) {
                        generation = newest.generation; service_error = nullptr; next_publish = 0;
                        process.start(state->executable, state->model, newest.wake.data(), newest.standby.data(), newest.started);
                    }
                    // A newer restart or shutdown may arrive during OS spawn.
                    // Never poll/feed/publish the old decoder after that point.
                    if (state->exit.load(std::memory_order_acquire)) break;
                    if (generation != state->requested.load(std::memory_order_acquire)) { process.stop(); generation = 0; }
                    if (generation) {
                        const auto now = state->clock();
                        auto action = service_error ? Action::none : process.poll(now);
                        PCM block{};
                        for (unsigned i = 0; i < kPCMCapacity && state->pcm.pop(block); ++i) {
                            if (block.generation != generation || service_error) continue;
                            if (!fresh_time(block.stamp, state->clock())) { service_error = "worker_queue_stale"; process.stop(); continue; }
                            process.feed(block.samples.data(), block.samples.size());
                        }
                        if (now >= next_publish || action != Action::none || (!service_error && (process.raw_wakes() || process.raw_standbys()))) {
                            Snapshot value{}; value.generation = generation; value.published = state->clock();
                            value.progress = process.progress_time_ns(); value.frames = process.frames(); value.sequence = process.sequence();
                            value.ready = process.ready() && !service_error; value.failed = process.failed() || service_error;
                            value.model_profile = process.model_profile();
                            value.action = action; value.action_frames = process.action_frames(); value.action_progress = process.action_progress_ns();
                            value.action_sequence = process.action_sequence();
                            value.raw_wakes = service_error ? 0 : process.raw_wakes(); value.raw_standbys = service_error ? 0 : process.raw_standbys(); value.last_action_sequence = process.last_action_sequence();
                            const std::string problem = service_error ? service_error : process.error();
                            std::copy_n(problem.data(), std::min(problem.size(), value.error.size() - 1), value.error.begin());
                            // Dropping a redundant status sample is safe: its
                            // freshness expires at the reader. Losing a command
                            // must instead fail closed visibly.
                            if (!state->snapshots.push(value)) {
                                state->dropped_observations.fetch_add(value.raw_wakes + value.raw_standbys, std::memory_order_relaxed);
                                if (action != Action::none) {
                                    state->fault_generation.store(generation, std::memory_order_release);
                                    service_error = "worker_snapshot_backpressure"; process.stop();
                                }
                            }
                            next_publish = state->clock() + 10000000;
                        }
                    }
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            process.stop();
        }
        } catch (...) {
            state->service_exception.store(true, std::memory_order_release);
            state->fault_generation.store(state->requested.load(std::memory_order_acquire), std::memory_order_release);
        }
        { std::lock_guard<std::mutex> hold(state->done_lock); state->done = true; }
        state->done_changed.notify_all();
    }
    struct Stamp { std::uint64_t end = 0, time = 0; };
    Clock clock_;
    std::shared_ptr<State> state_;
    std::thread worker_;
    std::array<Stamp,64> stamps_{};
    Snapshot latest_{};
    std::array<Observation,16> observations_{};
    std::size_t observation_count_ = 0, observation_read_ = 0;
    std::array<Batch,16> batches_{};
    std::size_t batch_count_ = 0, batch_read_ = 0;
    std::uint64_t generation_ = 0, submitted_ = 0, started_ = 0, ready_stamp_ = 0;
    const char* local_error_ = nullptr;
    bool closed_ = false;
};
using KeywordService = BasicKeywordService<KeywordProcess>;
} // namespace audio_router::host
