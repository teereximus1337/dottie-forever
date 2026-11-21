#include "capture_adapter.hpp"

#include <cmath>
#include <cstring>

namespace audio_router::macos {

static_assert(std::atomic<std::uint32_t>::is_always_lock_free, "Capture indices must be lock-free");
static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "Capture counters must be lock-free");

BoundedSink::BoundedSink(CaptureBlock* slots, std::uint32_t count) noexcept : slots_(slots), capacity_(count) {}

bool BoundedSink::valid() const noexcept {
    return slots_ != nullptr && capacity_ >= 2 && capacity_ <= 32 && (capacity_ & (capacity_ - 1)) == 0;
}

bool BoundedSink::claim() noexcept {
    std::uint32_t expected = 0;
    if (!valid() || !claimed_.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) return false;
    // No consumer may be active when a new producer claims/reset this sink.
    write_.store(0, std::memory_order_relaxed);
    read_.store(0, std::memory_order_relaxed);
    return true;
}

void BoundedSink::release() noexcept { claimed_.store(0, std::memory_order_release); }

bool BoundedSink::try_push(const float* mono, std::uint32_t frames, std::uint64_t host_time, std::uint32_t sample_rate) noexcept {
    if (!valid() || mono == nullptr || frames == 0 || frames > kMaxCaptureFrames || sample_rate < 8000 || sample_rate > 192000) return false;
    const auto write = write_.load(std::memory_order_relaxed);
    if (write - read_.load(std::memory_order_acquire) >= capacity_) return false;
    auto& slot = slots_[write % capacity_];
    slot.host_time = host_time;
    slot.frames = frames;
    slot.sample_rate = sample_rate;
    std::memcpy(slot.samples, mono, frames * sizeof(float));
    write_.store(write + 1, std::memory_order_release);
    return true;
}

bool BoundedSink::try_pop(CaptureBlock& output) noexcept {
    if (!valid()) return false;
    const auto read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire)) return false;
    const auto& slot = slots_[read % capacity_];
    output.host_time = slot.host_time;
    output.frames = slot.frames;
    output.sample_rate = slot.sample_rate;
    std::memcpy(output.samples, slot.samples, slot.frames * sizeof(float));
    read_.store(read + 1, std::memory_order_release);
    return true;
}

Result validate_process_selection(const pid_t* pids, std::size_t count) noexcept {
    if (pids == nullptr || count == 0 || count > kMaxProcesses) return {Error::invalid_selection, noErr};
    for (std::size_t i = 0; i < count; ++i) {
        if (pids[i] <= 0) return {Error::invalid_selection, noErr};
        for (std::size_t j = 0; j < i; ++j) {
            if (pids[j] == pids[i]) return {Error::invalid_selection, noErr};
        }
    }
    return {};
}

Result validate_format(const AudioStreamBasicDescription& a, Format& out) noexcept {
    const auto allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    const bool noninterleaved = (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const auto bytes = static_cast<UInt32>(sizeof(float)) * (noninterleaved ? 1 : a.mChannelsPerFrame);
    if (!std::isfinite(a.mSampleRate) || a.mSampleRate < 8000 || a.mSampleRate > 192000 ||
        std::floor(a.mSampleRate) != a.mSampleRate || a.mFormatID != kAudioFormatLinearPCM ||
        (a.mFormatFlags & ~allowed) != 0 ||
        (a.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)) !=
            (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ||
        (a.mChannelsPerFrame != 1 && a.mChannelsPerFrame != 2) ||
        a.mBitsPerChannel != 32 || a.mFramesPerPacket != 1 ||
        a.mBytesPerFrame != bytes || a.mBytesPerPacket != bytes) {
        return {Error::unsupported_format, noErr};
    }
    out = {a.mChannelsPerFrame, noninterleaved, static_cast<std::uint32_t>(a.mSampleRate)};
    return {};
}

Result downmix(const Format& f, const AudioBufferList* input, float* mono,
               std::size_t capacity, std::uint32_t& frames) noexcept {
    frames = 0;
    if ((f.channels != 1 && f.channels != 2) || input == nullptr || mono == nullptr)
        return {Error::invalid_buffer, noErr};
    const auto count = f.noninterleaved ? f.channels : 1;
    const auto channels_per_buffer = f.noninterleaved ? 1 : f.channels;
    const auto stride_bytes = channels_per_buffer * sizeof(float);
    if (input->mNumberBuffers != count) return {Error::invalid_buffer, noErr};
    const auto first_bytes = input->mBuffers[0].mDataByteSize;
    if (first_bytes == 0 || first_bytes % stride_bytes != 0) return {Error::invalid_buffer, noErr};
    const auto sample_frames = first_bytes / stride_bytes;
    if (sample_frames > capacity || sample_frames > kMaxCaptureFrames) return {Error::invalid_buffer, noErr};
    for (std::uint32_t b = 0; b < count; ++b) {
        if (input->mBuffers[b].mData == nullptr || input->mBuffers[b].mNumberChannels != channels_per_buffer ||
            input->mBuffers[b].mDataByteSize != first_bytes) return {Error::invalid_buffer, noErr};
    }
    const auto* left = static_cast<const float*>(input->mBuffers[0].mData);
    const auto* right = f.noninterleaved && f.channels == 2 ? static_cast<const float*>(input->mBuffers[1].mData) : left;
    for (std::size_t i = 0; i < sample_frames; ++i) {
        const float l = left[i * (f.noninterleaved ? 1 : f.channels)];
        const float r = f.channels == 1 ? l : right[f.noninterleaved ? i : i * 2 + 1];
        if (!std::isfinite(l) || !std::isfinite(r) || l < -1 || l > 1 || r < -1 || r > 1)
            return {Error::invalid_pcm, noErr};
        mono[i] = f.channels == 1 ? l : .5F * l + .5F * r;
    }
    frames = static_cast<std::uint32_t>(sample_frames);
    return {};
}

} // namespace audio_router::macos
