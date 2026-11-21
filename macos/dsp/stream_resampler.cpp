#include "stream_resampler.hpp"
#include <algorithm>
#include <cmath>
#include <limits>

namespace audio_router::dsp {
namespace { constexpr double pi = 3.14159265358979323846; constexpr std::uint64_t billion = 1000000000; }
void StreamingResampler::reset() noexcept { rate_ = 0; }
void StreamingResampler::begin(std::uint32_t rate, std::uint64_t ns) noexcept {
    rate_ = rate; effective_rate_ = rate; anchor_ns_ = last_ns_ = ns;
    total_ = base_ = output_count_ = previous_frames_ = 0; position_ = 0;
    const double cutoff = std::min(1.0, 48000.0 / rate) * .94;
    for (std::size_t phase = 0; phase < kPhases; ++phase) {
        double sum = 0;
        for (std::size_t tap = 0; tap < kTaps; ++tap) {
            const double x = static_cast<double>(tap) - 15 - static_cast<double>(phase) / kPhases;
            const double window = .42 + .5 * std::cos(pi * x / 16) + .08 * std::cos(2 * pi * x / 16);
            const double sinc = std::abs(x) < 1e-10 ? cutoff : std::sin(pi * cutoff * x) / (pi * x);
            kernels_[phase][tap] = static_cast<float>(sinc * window);
            sum += sinc * window;
        }
        for (auto& value : kernels_[phase]) value = static_cast<float>(value / sum);
    }
}
ConvertResult StreamingResampler::convert(const macos::CaptureBlock& input, std::uint64_t ns, ConvertedBlock& out) noexcept {
    out.frames = 0; out.discontinuity = false; out.first_sample_ns = ns;
    if (!input.frames || input.frames > macos::kMaxCaptureFrames || input.sample_rate < 8000 || input.sample_rate > 192000)
        return ConvertResult::invalid_input;
    for (std::size_t i = 0; i < input.frames; ++i)
        if (!std::isfinite(input.samples[i]) || std::abs(input.samples[i]) > 1) return ConvertResult::invalid_input;
    bool restart = rate_ != input.sample_rate;
    if (rate_ && !restart && previous_frames_) {
        const double expected = previous_frames_ * 1e9 / rate_;
        const double elapsed = ns >= last_ns_ ? static_cast<double>(ns - last_ns_) : -1;
        // Buffer discontinuity resets history, never bridges missing speech.
        if (elapsed <= 0 || std::abs(elapsed - expected) > std::max(2000000.0, expected * .02)) restart = true;
        else {
            const double measured = previous_frames_ * 1e9 / elapsed;
            const double bounded = std::clamp(measured, rate_ * .995, rate_ * 1.005);
            effective_rate_ = .95 * effective_rate_ + .05 * bounded;
        }
    }
    if (restart || !rate_) { out.discontinuity = rate_ != 0; begin(input.sample_rate, ns); }
    last_ns_ = ns; previous_frames_ = input.frames;
    if (total_ - base_ + input.frames > kHistory) return ConvertResult::capacity;
    for (std::size_t i = 0; i < input.frames; ++i) samples_[(total_ + i) % kHistory] = input.samples[i];
    total_ += input.frames;
    const auto max = std::numeric_limits<std::uint64_t>::max();
    const auto seconds = output_count_ / 48000, remainder = output_count_ % 48000;
    if (seconds > (max - anchor_ns_) / billion) return ConvertResult::timestamp_overflow;
    const auto whole = seconds * billion, fraction = remainder * billion / 48000;
    if (fraction > max - anchor_ns_ - whole) return ConvertResult::timestamp_overflow;
    const auto offset = whole + fraction;
    out.first_sample_ns = anchor_ns_ + offset;
    while (position_ + 16 < static_cast<double>(total_)) {
        if (out.frames == kMaxConvertedFrames) return ConvertResult::capacity;
        const auto center = static_cast<std::uint64_t>(position_);
        const auto phase = std::min(kPhases - 1, static_cast<std::size_t>((position_ - center) * kPhases));
        double value = 0;
        for (std::size_t tap = 0; tap < kTaps; ++tap) {
            const auto index = static_cast<std::int64_t>(center) + static_cast<std::int64_t>(tap) - 15;
            if (index >= 0 && static_cast<std::uint64_t>(index) >= base_)
                value += kernels_[phase][tap] * samples_[static_cast<std::uint64_t>(index) % kHistory];
        }
        out.samples[out.frames++] = static_cast<float>(std::clamp(value, -1.0, 1.0));
        ++output_count_;
        position_ += effective_rate_ / 48000.0;
    }
    const auto next_center = static_cast<std::uint64_t>(position_);
    base_ = next_center > 16 ? next_center - 16 : 0;
    return ConvertResult::ok;
}
}
