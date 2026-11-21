#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>

namespace audio_router::host {
// Single audio-scheduler owner. Accumulate actual PCM over 50 ms; UI sampling
// cannot miss every short transient by reading just the latest 10 ms block.
struct MeterWindow {
    static constexpr std::size_t kWindowFrames = 2400;
    double rms = 0, peak = 0;
    void push(const float* samples, std::size_t count) noexcept {
        for (std::size_t i = 0; i < count; ++i) {
            const double value = std::isfinite(samples[i]) ? samples[i] : 0;
            energy_ += value * value;
            peak_ = std::max(peak_, std::abs(value));
            if (++frames_ == kWindowFrames) {
                rms = std::sqrt(energy_ / frames_); peak = peak_;
                frames_ = 0; energy_ = peak_ = 0;
            }
        }
    }
private:
    std::size_t frames_ = 0;
    double energy_ = 0, peak_ = 0;
};
} // namespace audio_router::host
