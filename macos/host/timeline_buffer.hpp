#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace audio_router::host {
constexpr std::uint64_t kRate = 48000;
constexpr std::size_t kFrames = 480;
constexpr std::uint64_t kBlockNs = 10000000;

inline std::uint64_t ns_to_frame(std::uint64_t ns) noexcept {
    return (ns / 1000000000) * kRate + ((ns % 1000000000) * kRate + 500000000) / 1000000000;
}

inline bool source_healthy(bool physical, bool active, bool failed, bool fresh,
                           std::size_t missing, std::size_t frames = kFrames) noexcept {
    // A selected, alive app can legitimately emit no buffers while idle.
    // A physical mic and an actively-outputting app must demonstrate progress.
    return !failed && ((!physical && !active) || (fresh && missing <= frames / 20));
}

// Bounded timestamp placement for already-48kHz capture. Missing samples are
// zeros; no unbounded FIFO drift or replay. This is not adaptive resampling.
class TimelineBuffer {
public:
    static constexpr std::size_t capacity = 32768;
    TimelineBuffer() noexcept { clear(); }
    void clear() noexcept {
        tags_.fill(std::numeric_limits<std::uint64_t>::max());
        last_receipt_ns_ = 0;
    }
    bool push(const float* data, std::size_t frames, std::uint64_t first_ns,
              std::uint64_t receipt_ns) noexcept {
        if (!data || !frames || frames > 25000 ||
            first_ns > receipt_ns + 100000000 ||
            (receipt_ns > first_ns && receipt_ns - first_ns > 500000000)) return false;
        const auto first = ns_to_frame(first_ns);
        for (std::size_t i = 0; i < frames; ++i) {
            const auto frame = first + i;
            tags_[frame % capacity] = frame;
            samples_[frame % capacity] = data[i];
        }
        last_receipt_ns_ = receipt_ns;
        return true;
    }
    std::size_t read(float* out, std::size_t frames, std::uint64_t first_ns) const noexcept {
        const auto first = ns_to_frame(first_ns);
        std::size_t missing = 0;
        for (std::size_t i = 0; i < frames; ++i) {
            const auto frame = first + i;
            const bool present = tags_[frame % capacity] == frame;
            out[i] = present ? samples_[frame % capacity] : 0.0F;
            missing += !present;
        }
        return missing;
    }
    bool fresh(std::uint64_t now) const noexcept {
        return last_receipt_ns_ && now >= last_receipt_ns_ && now - last_receipt_ns_ <= 150000000;
    }
private:
    std::array<float, capacity> samples_{};
    std::array<std::uint64_t, capacity> tags_{};
    std::uint64_t last_receipt_ns_ = 0;
};
} // namespace audio_router::host
