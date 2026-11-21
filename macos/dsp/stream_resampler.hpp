#pragma once
#include "../capture/capture_adapter.hpp"
#include <array>
#include <cstddef>
#include <cstdint>

namespace audio_router::dsp {
constexpr std::size_t kMaxConvertedFrames = 25000;
struct ConvertedBlock {
    std::uint64_t first_sample_ns = 0;
    std::uint32_t frames = 0;
    bool discontinuity = false;
    float samples[kMaxConvertedFrames]{};
};
enum class ConvertResult { ok, invalid_input, capacity, timestamp_overflow };

// One serialized non-callback owner. All storage is fixed; tables are rebuilt
// only on initial input or a rate change, outside the Core Audio callback.
class StreamingResampler {
public:
    ConvertResult convert(const macos::CaptureBlock& input, std::uint64_t first_sample_ns, ConvertedBlock& output) noexcept;
    void reset() noexcept;
    double estimated_source_rate() const noexcept { return effective_rate_; }
private:
    static constexpr std::size_t kHistory = 8192, kPhases = 1024, kTaps = 32;
    std::array<float, kHistory> samples_{};
    std::array<std::array<float, kTaps>, kPhases> kernels_{};
    std::uint32_t rate_ = 0, previous_frames_ = 0;
    std::uint64_t anchor_ns_ = 0, last_ns_ = 0, total_ = 0, base_ = 0, output_count_ = 0;
    double position_ = 0, effective_rate_ = 48000;
    void begin(std::uint32_t rate, std::uint64_t ns) noexcept;
};
}
