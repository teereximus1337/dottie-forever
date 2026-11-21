// Test helper: reads aggregate levels from an explicitly supplied synthetic file.
#include "../transport/pcm_transport.hpp"
#include <mach/mach_time.h>
#include <unistd.h>
#include <array>
#include <cmath>
#include <charconv>
#include <cstring>
#include <iostream>
std::uint64_t now_ns() {
    mach_timebase_info_data_t scale{}; mach_timebase_info(&scale);
    const auto ticks = mach_absolute_time();
    return ticks / scale.denom * scale.numer + ticks % scale.denom * scale.numer / scale.denom;
}
int main(int argc, char** argv) {
    if (argc != 2 && argc != 4) return 2;
    std::uint64_t requested_start = 0;
    if (argc == 4) {
        if (std::strcmp(argv[2], "--first-sample-ns") != 0) return 2;
        const auto end = argv[3] + std::strlen(argv[3]);
        const auto parsed = std::from_chars(argv[3], end, requested_start);
        if (parsed.ec != std::errc{} || parsed.ptr != end) return 2;
    }
    using namespace audio_router::transport;
    Reader reader;
    if (!reader.open(argv[1], getuid()).ok()) return 1;
    const auto now = now_ns();
    const auto first = argc == 4 ? requested_start : now - kReaderDelayNs;
    std::array<float, kPacketFrames> discord{}, alexa{};
    const auto d = reader.read(Route::discord, discord.data(), discord.size(), first, now);
    const auto a = reader.read(Route::alexa, alexa.data(), alexa.size(), first, now);
    auto rms = [](const auto& samples) { double energy=0; for(float x:samples) energy+=x*x; return std::sqrt(energy/samples.size()); };
    std::cout << "{\"discord\":" << rms(discord) << ",\"alexa\":" << rms(alexa)
        << ",\"copied\":" << d.copied_frames << ",\"stale\":" << (d.producer_stale ? "true":"false")
        << ",\"gate_closed\":" << (a.gate_closed ? "true":"false")
        << ",\"assistant_copied\":" << a.copied_frames << ",\"assistant_stale\":" << (a.producer_stale ? "true":"false")
        << ",\"first_sample_ns\":" << first << "}\n";
}
