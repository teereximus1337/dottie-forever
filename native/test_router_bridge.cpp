#include "router_bridge.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void expect(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

struct Handle {
    void* value;
    explicit Handle(uint64_t lease = 1000000000) : value(ar_create(lease)) {
        expect(value != nullptr, "handle allocation");
    }
    ~Handle() { ar_destroy(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};

void null_handles() {
    expect(ar_abi_version() == 1, "ABI version");
    ar_destroy(nullptr);
    expect(ar_restart(nullptr) == AR_ERROR_INVALID_HANDLE, "null restart");
    expect(ar_control(nullptr, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_ERROR_INVALID_HANDLE, "null control");
    float untouched = -9;
    expect(ar_render(nullptr, nullptr, nullptr, nullptr, &untouched, nullptr, nullptr, 1, 0) == AR_ERROR_INVALID_HANDLE,
           "null render");
    expect(untouched == -9, "null handle leaves caller buffers untouched");
    expect(ar_epoch(nullptr) == 0 && ar_next_time_ns(nullptr) == 0 && ar_gate_open(nullptr) == 0, "null queries");
}

void source_matrix_through_abi() {
    Handle h;
    const std::array<float, 3> mic{1, 0, 0}, discord{0, 1, 0}, dot{0, 0, 1};
    std::array<float, 3> discord_out{}, detector_out{}, dot_out{};
    expect(ar_epoch(h.value) == 1 && ar_gate_open(h.value) == 0, "initial state");
    expect(ar_control(h.value, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_OK, "wake ABI");
    expect(ar_render(h.value, mic.data(), discord.data(), dot.data(), discord_out.data(), detector_out.data(),
                     dot_out.data(), 3, 0) == AR_OK, "render ABI");
    expect(discord_out == std::array<float, 3>{.5F, 0, .5F}, "Discord source isolation");
    expect(detector_out == std::array<float, 3>{.5F, .5F, 0}, "listener source isolation");
    expect(dot_out == detector_out, "open Dot source isolation");
    expect(ar_next_time_ns(h.value) == 62500, "render advances exact three-frame timeline");
    expect(ar_control(h.value, 1, 2, 2, 62500, 62500, AR_HEALTHY | AR_WAKE | AR_STANDBY) == AR_OK, "standby priority ABI");
    expect(ar_render(h.value, mic.data(), discord.data(), dot.data(), discord_out.data(), detector_out.data(),
                     dot_out.data(), 3, 62500) == AR_OK, "standby render ABI");
    expect(dot_out == std::array<float, 3>{0, 0, 0}, "standby silence ABI");
    expect(discord_out == std::array<float, 3>{.5F, 0, .5F} && detector_out == std::array<float, 3>{.5F, .5F, 0},
           "standby preserves independent branches ABI");
}

void unknown_flags_close_and_consume() {
    Handle h;
    expect(ar_control(h.value, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_OK && ar_gate_open(h.value) == 1, "wake");
    expect(ar_control(h.value, 1, 2, 2, 1, 1, uint32_t{0x80000000} | AR_HEALTHY | AR_WAKE) == AR_ERROR_INVALID_FLAGS,
           "unknown high flag rejected");
    expect(ar_gate_open(h.value) == 0, "unknown flags close existing gate");
    expect(ar_control(h.value, 1, 2, 2, 1, 1, AR_HEALTHY | AR_WAKE) == AR_INVALID_CONTROL,
           "invalid flag command cannot be replayed with corrected flags");
    const float mic = 1, discord = .25F, dot = .5F;
    float discord_out = -9, detector_out = -9, dot_out = -9;
    expect(ar_render(h.value, &mic, &discord, &dot, &discord_out, &detector_out, &dot_out, 1, 1) == AR_OK,
           "render after invalid flags");
    expect(discord_out == .75F && detector_out == .625F && dot_out == 0, "flag error affects only Dot");
    const auto now = ar_next_time_ns(h.value);
    expect(ar_control(h.value, 1, 3, 3, now, now, AR_HEALTHY) == AR_OK && ar_gate_open(h.value) == 0,
           "heartbeat cannot recover flag error");
    expect(ar_control(h.value, 1, 4, 4, now, now, AR_HEALTHY | AR_WAKE) == AR_OK && ar_gate_open(h.value) == 1,
           "fresh wake recovers flag error");
    expect(ar_control(h.value, 9, 5, 5, 0, 0, 8) == AR_ERROR_INVALID_FLAGS && ar_gate_open(h.value) == 0,
           "unknown flags close even with invalid epoch and clock");
}

void exact_uint64_and_restart() {
    Handle h;
    constexpr uint64_t start = (uint64_t{1} << 53) + 123;
    constexpr uint64_t sequence = (uint64_t{1} << 53) + 11;
    constexpr uint64_t progress = (uint64_t{1} << 53) + 17;
    expect(ar_control(h.value, 1, sequence, progress, start, start, AR_HEALTHY | AR_WAKE) == AR_OK, "64-bit control values");
    const float mic = 1, discord = 0, dot = 0;
    float discord_out = 0, detector_out = 0, dot_out = 0;
    expect(ar_render(h.value, &mic, &discord, &dot, &discord_out, &detector_out, &dot_out, 1, start) == AR_OK,
           "64-bit render time");
    const auto now = start + 20834;
    expect(ar_next_time_ns(h.value) == now && dot_out == .5F, "integer time survives ABI above binary64 exact range");
    expect(ar_control(h.value, 1, sequence, progress + 1, now, now, AR_HEALTHY | AR_WAKE) == AR_INVALID_CONTROL,
           "64-bit sequence replay rejected");
    expect(ar_restart(h.value) == AR_OK && ar_epoch(h.value) == 2 && ar_gate_open(h.value) == 0, "restart ABI");
    expect(ar_next_time_ns(h.value) == now, "restart preserves exact clock");
    expect(ar_control(h.value, 1, sequence + 1, progress + 2, now, now, AR_HEALTHY | AR_WAKE) == AR_INVALID_CONTROL,
           "old epoch rejected across ABI");
    expect(ar_control(h.value, 2, 1, 1, now, now, AR_HEALTHY) == AR_OK && ar_gate_open(h.value) == 0,
           "new epoch heartbeat remains closed");
    expect(ar_control(h.value, 2, 2, 2, now, now, AR_HEALTHY | AR_WAKE) == AR_OK && ar_gate_open(h.value) == 1,
           "new epoch fresh wake");
}

void sample_expiry_through_abi() {
    Handle h;
    std::vector<float> mic(48000, 1), discord(48000, 0), dot(48000, 0);
    std::vector<float> discord_out(48000), detector_out(48000), dot_out(48000);
    expect(ar_control(h.value, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_OK, "wake");
    expect(ar_render(h.value, mic.data(), discord.data(), dot.data(), discord_out.data(), detector_out.data(),
                     dot_out.data(), 48000, 500000000) == AR_OK, "48k frames through ABI");
    for (size_t i = 0; i < dot_out.size(); ++i) {
        expect(dot_out[i] == (i < 24000 ? .5F : 0.0F), "sample boundary survives ABI");
        expect(discord_out[i] == .5F && detector_out[i] == .5F, "independent continuous mixes ABI");
    }
    expect(ar_next_time_ns(h.value) == 1500000000 && ar_gate_open(h.value) == 0, "end-of-block ABI state");
}

void null_buffer_status_and_configuration() {
    Handle h;
    expect(ar_control(h.value, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_OK, "wake");
    const float discord = 0, dot = 0;
    float discord_out = -9, detector_out = -9, dot_out = -9;
    expect(ar_render(h.value, nullptr, &discord, &dot, &discord_out, &detector_out, &dot_out, 1, 0) == AR_INVALID_BUFFERS,
           "null source returns core buffer status");
    expect(ar_gate_open(h.value) == 0 && discord_out == 0 && detector_out == 0 && dot_out == 0,
           "malformed source closes gate and clears bounded outputs");
    Handle invalid(0);
    expect(ar_control(invalid.value, 1, 1, 1, 0, 0, AR_HEALTHY | AR_WAKE) == AR_INVALID_CONFIGURATION,
           "invalid lease retains core status semantics");
    expect(ar_gate_open(invalid.value) == 0, "invalid configuration stays closed");
}

} // namespace

int main() {
    struct Test { const char* name; void (*run)(); };
    const Test tests[] = {
        {"null handles and ABI version", null_handles},
        {"source matrix and standby through ABI", source_matrix_through_abi},
        {"unknown flags fail closed", unknown_flags_close_and_consume},
        {"exact uint64 values and restart", exact_uint64_and_restart},
        {"sample expiry through ABI", sample_expiry_through_abi},
        {"null buffers and invalid configuration", null_buffer_status_and_configuration},
    };
    size_t passed = 0;
    for (const auto& test : tests) {
        try { test.run(); ++passed; std::cout << "PASS " << test.name << '\n'; }
        catch (const std::exception& error) {
            std::cerr << "FAIL " << test.name << ": " << error.what() << '\n';
            return 1;
        }
    }
    std::cout << passed << " native C ABI tests passed\n";
    return 0;
}
