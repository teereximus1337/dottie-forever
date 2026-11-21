#include "router_core.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace audio_router {
namespace {

constexpr std::uint64_t kNsPerSecond = 1000000000;

bool valid(InputBuffer buffer, std::size_t frames) noexcept {
    return buffer.data != nullptr && buffer.size >= frames;
}

bool valid(OutputBuffer buffer, std::size_t frames) noexcept {
    return buffer.data != nullptr && buffer.size >= frames;
}

bool normalized(float sample) noexcept {
    return std::isfinite(sample) && sample >= -1.0F && sample <= 1.0F;
}

float sanitized(float sample) noexcept {
    return normalized(sample) ? sample : 0.0F;
}

void clear_bounded(OutputBuffer buffer, std::size_t frames) noexcept {
    if (buffer.data == nullptr) return;
    const auto count = std::min({frames, buffer.size, kMaximumFrames});
    for (std::size_t i = 0; i < count; ++i) buffer.data[i] = 0.0F;
}

} // namespace

RouterCore::RouterCore(std::uint64_t lease_ns) noexcept : lease_ns_(lease_ns) {}

void RouterCore::close() noexcept {
    open_ = false;
    deadline_ns_ = 0;
}

Status RouterCore::restart() noexcept {
    close();
    sequence_ = progress_ = 0;
    // Preserve the monotonic time watermark across in-process restarts.
    if (epoch_ == std::numeric_limits<std::uint64_t>::max()) {
        exhausted_ = true;
        return Status::epoch_exhausted;
    }
    ++epoch_;
    return Status::ok;
}

Status RouterCore::control(const Command& c, std::uint64_t now_ns) noexcept {
    if (exhausted_) { close(); return Status::epoch_exhausted; }
    if (lease_ns_ == 0 || lease_ns_ > kMaximumLeaseNs) {
        close();
        return Status::invalid_configuration;
    }

    const bool correct_epoch = c.epoch == epoch_;
    const bool fresh_sequence = c.sequence != 0 && c.sequence > sequence_;
    const bool advancing = c.progress != 0 && c.progress > progress_;
    // Consume observed counters for this epoch even when a command is rejected.
    // A rejected/unhealthy wake cannot later be replayed with changed flags.
    if (correct_epoch) {
        sequence_ = std::max(sequence_, c.sequence);
        progress_ = std::max(progress_, c.progress);
    }

    const bool clock_ok = !has_timeline_ || now_ns >= timeline_ns_;
    const bool timestamp_ok = c.timestamp_ns <= now_ns &&
        now_ns - c.timestamp_ns <= kMaximumCommandAgeNs &&
        (!has_timeline_ || c.timestamp_ns >= timeline_ns_);
    if (!clock_ok) { close(); return Status::invalid_timeline; }
    timeline_ns_ = now_ns;
    has_timeline_ = true;
    if (!correct_epoch || !fresh_sequence || !advancing || !timestamp_ok || !c.healthy) {
        close();
        return Status::invalid_control;
    }

    if (c.standby) { close(); return Status::ok; }
    if (open_ && now_ns >= deadline_ns_) close();
    // Progress alone cannot reopen after expiry, standby, restart, or a fault.
    if (c.wake || open_) {
        if (now_ns > std::numeric_limits<std::uint64_t>::max() - lease_ns_) {
            close();
            return Status::time_overflow;
        }
        deadline_ns_ = now_ns + lease_ns_;
        open_ = true;
    }
    return Status::ok;
}

Status RouterCore::render(const Inputs& in, const Outputs& out,
                          std::size_t frames, std::uint64_t start_ns) noexcept {
    return render(in, out, frames, start_ns, Routing{});
}

Status RouterCore::render(const Inputs& in, const Outputs& out,
                          std::size_t frames, std::uint64_t start_ns, const Routing& routing) noexcept {
    // All six buffers must refer to distinct, non-overlapping storage; sizes
    // describe actual allocated capacity. The caller owns their lifetime.
    if (frames == 0 || frames > kMaximumFrames ||
        !valid(in.mic, frames) || !valid(in.discord, frames) || !valid(in.dot, frames) ||
        !valid(out.discord, frames) || !valid(out.detector, frames) || !valid(out.dot, frames)) {
        close();
        clear_bounded(out.discord, frames);
        clear_bounded(out.detector, frames);
        clear_bounded(out.dot, frames);
        return Status::invalid_buffers;
    }

    Status status = Status::ok;
    // frames <= 48000 bounds this multiplication well below UINT64_MAX.
    const auto scaled_duration = static_cast<std::uint64_t>(frames) * kNsPerSecond;
    const auto duration_ns = (scaled_duration + kSampleRate - 1) / kSampleRate;
    const bool timeline_ok = !has_timeline_ || start_ns >= timeline_ns_;
    const bool fits = start_ns <= std::numeric_limits<std::uint64_t>::max() - duration_ns;
    if (!timeline_ok) { close(); status = Status::invalid_timeline; }
    else if (!fits) { close(); status = Status::time_overflow; }

    // Validate the whole block before writing Dot, so a bad later sample cannot
    // leave an already-emitted prefix open. Independent mixes sanitize only the
    // invalid source samples, preserving valid mic/other-source contributions.
    for (std::size_t i = 0; i < frames; ++i) {
        if (!normalized(in.mic.data[i]) || !normalized(in.discord.data[i]) ||
            !normalized(in.dot.data[i])) {
            close();
            if (status == Status::ok) status = Status::invalid_samples;
        }
    }

    for (std::size_t i = 0; i < frames; ++i) {
        const float mic = sanitized(in.mic.data[i]);
        const float discord = sanitized(in.discord.data[i]);
        const float dot = sanitized(in.dot.data[i]);
        out.discord.data[i] = (routing.mic_to_apps ? 0.5F * mic : 0.0F) +
                              (routing.assistant_to_apps ? 0.5F * dot : 0.0F);
        out.detector.data[i] = 0.5F * mic + 0.5F * discord;
        if (open_) {
            const auto offset_ns = static_cast<std::uint64_t>(i) * kNsPerSecond / kSampleRate;
            // open_ is false on a timestamp overflow/error before this loop.
            if (start_ns + offset_ns >= deadline_ns_) close();
        }
        out.dot.data[i] = open_ ? (routing.mic_to_assistant ? 0.5F * mic : 0.0F) + 0.5F * discord : 0.0F;
    }

    if (timeline_ok && fits) {
        timeline_ns_ = start_ns + duration_ns;
        has_timeline_ = true;
        if (open_ && timeline_ns_ >= deadline_ns_) close();
    }
    return status;
}

} // namespace audio_router
