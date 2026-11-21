#pragma once
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <thread>

namespace audio_router::host {
// One owner serializes potentially blocking HAL checks away from PCM draining.
// Only scalar atomics cross the boundary. Join before stopping capture engines.
class HealthMonitor {
public:
    using Clock = std::uint64_t (*)();
    using Poll = std::function<void(std::size_t)>;
    static constexpr std::uint64_t kFreshNs = 500000000;
    ~HealthMonitor() { stop(); }
    static constexpr std::size_t kMaximumSources = 10;
    void start(Clock clock, Poll poll, std::size_t sources = 3) {
        sources_ = std::min(sources, kMaximumSources);
        clock_ = clock; poll_ = std::move(poll);
        thread_ = std::thread([this] { run(); });
    }
    void arm(std::uint64_t now) noexcept {
        for (auto& stamp : completed_) stamp.store(now, std::memory_order_relaxed);
        armed_.store(true, std::memory_order_release);
    }
    void stop() noexcept {
        exit_.store(true, std::memory_order_release);
        if (thread_.joinable()) thread_.join();
    }
    bool fresh(std::size_t source, std::uint64_t now) const noexcept {
        const auto stamp = completed_[source].load(std::memory_order_acquire);
        // A monitor completion can race ahead of the scheduler's sampled now.
        // Both use the same monotonic clock: that check has age zero, not stale.
        return stamp && (stamp >= now || now - stamp < kFreshNs);
    }
    std::uint64_t completed(std::size_t source) const noexcept { return completed_[source].load(std::memory_order_acquire); }
    std::uint64_t max_ns(std::size_t source) const noexcept { return max_ns_[source].load(std::memory_order_relaxed); }
    std::uint64_t calls(std::size_t source) const noexcept { return calls_[source].load(std::memory_order_relaxed); }
private:
    void run() {
        while (!exit_.load(std::memory_order_acquire) && !armed_.load(std::memory_order_acquire))
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        auto next = clock_() + 100000000;
        while (!exit_.load(std::memory_order_acquire)) {
            if (clock_() >= next) {
                for (std::size_t i = 0; i < sources_ && !exit_.load(std::memory_order_acquire); ++i) {
                    const auto start = clock_();
                    poll_(i);
                    const auto end = clock_();
                    const auto duration = end >= start ? end - start : 0;
                    if (duration > max_ns_[i].load(std::memory_order_relaxed)) max_ns_[i].store(duration, std::memory_order_relaxed);
                    calls_[i].fetch_add(1, std::memory_order_relaxed);
                    completed_[i].store(end, std::memory_order_release);
                }
                next = clock_() + 100000000;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    std::size_t sources_ = 3;
    Clock clock_ = nullptr;
    Poll poll_;
    std::thread thread_;
    std::atomic<bool> armed_{false}, exit_{false};
    std::array<std::atomic<std::uint64_t>,kMaximumSources> completed_{}, max_ns_{}, calls_{};
};
} // namespace audio_router::host
