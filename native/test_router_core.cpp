#include "router_core.hpp"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace audio_router;

namespace {

void expect(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

struct Fixture {
    explicit Fixture(std::size_t count) : mic(count), discord(count), dot(count),
        discord_out(count, -9), detector_out(count, -9), dot_out(count, -9) {}
    std::vector<float> mic, discord, dot, discord_out, detector_out, dot_out;
    Inputs inputs() const {
        return {{mic.data(), mic.size()}, {discord.data(), discord.size()}, {dot.data(), dot.size()}};
    }
    Outputs outputs() {
        return {{discord_out.data(), discord_out.size()}, {detector_out.data(), detector_out.size()},
                {dot_out.data(), dot_out.size()}};
    }
    void fill_sources(float m, float d, float a) {
        std::fill(mic.begin(), mic.end(), m);
        std::fill(discord.begin(), discord.end(), d);
        std::fill(dot.begin(), dot.end(), a);
    }
};

Command command(const RouterCore& r, std::uint64_t sequence, std::uint64_t progress,
                std::uint64_t now, bool wake = false, bool standby = false) {
    return {r.epoch(), sequence, progress, now, true, wake, standby};
}

void source_matrix() {
    RouterCore r;
    Fixture f(3);
    f.mic = {1, 0, 0}; f.discord = {0, 1, 0}; f.dot = {0, 0, 1};
    expect(r.render(f.inputs(), f.outputs(), 3, 0) == Status::ok, "closed render");
    expect(f.discord_out == std::vector<float>({.5F, 0, .5F}), "Discord excludes Discord playback");
    expect(f.detector_out == std::vector<float>({.5F, .5F, 0}), "detector excludes Dot playback");
    expect(f.dot_out == std::vector<float>(3, 0), "initial gate closed");
    const auto now = r.next_time_ns();
    expect(r.control(command(r, 1, 1, now, true), now) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), 3, now) == Status::ok, "open render");
    expect(f.dot_out == std::vector<float>({.5F, .5F, 0}), "Dot excludes its own playback");
}

void configured_routes_keep_listener_independent() {
    for (unsigned mask = 0; mask < 8; ++mask) {
        RouterCore r;
        Fixture f(3);
        f.mic = {1, 0, 0}; f.discord = {0, 1, 0}; f.dot = {0, 0, 1};
        const Routing routes{bool(mask & 1), bool(mask & 2), bool(mask & 4)};
        expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "configured wake");
        expect(r.render(f.inputs(), f.outputs(), 3, 0, routes) == Status::ok, "configured render");
        expect(f.discord_out == std::vector<float>({routes.mic_to_apps ? .5F : 0, 0, routes.assistant_to_apps ? .5F : 0}),
               "shared apps bus follows selected mic/assistant edges and excludes app playback");
        expect(f.dot_out == std::vector<float>({routes.mic_to_assistant ? .5F : 0, .5F, 0}),
               "assistant bus follows mic edge and never returns assistant playback");
        expect(f.detector_out == std::vector<float>({.5F, .5F, 0}),
               "listener always hears mic and conversation mix, never assistant playback");
        const auto now = r.next_time_ns();
        expect(r.control(command(r, 2, 2, now, false, true), now) == Status::ok, "configured standby");
        expect(r.render(f.inputs(), f.outputs(), 3, now, routes) == Status::ok, "configured standby render");
        expect(f.dot_out == std::vector<float>(3, 0), "all route combinations close assistant in standby");
        expect(f.detector_out == std::vector<float>({.5F, .5F, 0}), "standby does not gate listener");
    }
}

void standby_independence() {
    RouterCore r;
    Fixture f(128); f.fill_sources(.5F, -.25F, .75F);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), 128, 0) == Status::ok, "render");
    const auto discord_before = f.discord_out, detector_before = f.detector_out;
    const auto now = r.next_time_ns();
    expect(r.control(command(r, 2, 2, now, true, true), now) == Status::ok, "standby wins");
    expect(r.render(f.inputs(), f.outputs(), 128, now) == Status::ok, "standby render");
    expect(f.discord_out == discord_before && f.detector_out == detector_before, "standby preserves independent branches");
    expect(std::all_of(f.dot_out.begin(), f.dot_out.end(), [](float x) { return x == 0; }), "standby PCM silence");
}

void expiry_inside_block() {
    RouterCore r;
    Fixture f(kMaximumFrames); f.fill_sources(1, 0, 0);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), kMaximumFrames, 500000000) == Status::ok, "one-second render");
    for (std::size_t i = 0; i < kMaximumFrames; ++i) {
        expect(f.dot_out[i] == (i < 24000 ? .5F : 0.0F), "lease closes at exact sample boundary");
        expect(f.discord_out[i] == .5F && f.detector_out[i] == .5F, "other branches continuous across expiry");
    }
    expect(r.next_time_ns() == 1500000000 && !r.gate_open(), "full block advances timeline");
}

void sub_sample_lease() {
    RouterCore r(1);
    Fixture f(2); f.fill_sources(1, 1, 0);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "one-nanosecond lease");
    expect(r.render(f.inputs(), f.outputs(), 2, 0) == Status::ok, "render");
    expect(f.dot_out == std::vector<float>({1, 0}), "first sample at/after expiry is zero");
    expect(r.next_time_ns() == 41667 && !r.gate_open(), "conservative fractional duration");
}

void heartbeat_and_fresh_wake() {
    RouterCore r;
    Fixture f(1); f.fill_sources(1, 0, 0);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    expect(r.control(command(r, 2, 2, 800000000), 800000000) == Status::ok, "progress extends active lease");
    expect(r.render(f.inputs(), f.outputs(), 1, 1700000000) == Status::ok && f.dot_out[0] == .5F, "refreshed lease open");
    expect(r.control(command(r, 3, 3, 1800000000), 1800000000) == Status::ok, "heartbeat at expired deadline");
    expect(!r.gate_open(), "heartbeat cannot reopen expired lease");
    expect(r.control(command(r, 4, 4, 1800000000, true), 1800000000) == Status::ok && r.gate_open(), "fresh wake recovers");
}

void invalid_controls_close_only_dot() {
    // Replay, nonadvancing/zero counters, wrong epoch, stale/future timestamps,
    // and unhealthy capture/detector all close only the final Dot branch.
    for (int scenario = 0; scenario < 9; ++scenario) {
        RouterCore r;
        Fixture f(1); f.fill_sources(.5F, .25F, .75F);
        expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
        expect(r.render(f.inputs(), f.outputs(), 1, 0) == Status::ok, "initial render");
        auto c = command(r, 2, 2, 1000000, true);
        switch (scenario) {
            case 0: c.sequence = 1; break;
            case 1: c.progress = 1; break;
            case 2: c.sequence = 0; break;
            case 3: c.progress = 0; break;
            case 4: ++c.epoch; break;
            case 5: c.timestamp_ns = 0; break;
            case 6: ++c.timestamp_ns; break;
            case 7: c.healthy = false; break;
            case 8: c.epoch = 0; break;
        }
        expect(r.control(c, 1000000) == Status::invalid_control, "invalid control rejected");
        expect(r.render(f.inputs(), f.outputs(), 1, 1000000) == Status::ok, "fault render");
        expect(f.dot_out[0] == 0 && f.discord_out[0] == .625F && f.detector_out[0] == .375F,
               "control fault cannot gate Discord or detector");
        auto now = r.next_time_ns();
        expect(r.control(command(r, 3, 3, now), now) == Status::ok && !r.gate_open(), "heartbeat cannot recover fault");
        expect(r.control(command(r, 4, 4, now, true), now) == Status::ok && r.gate_open(), "fresh wake recovers fault");
    }
}

void command_age_and_rejected_replay() {
    RouterCore r;
    auto c = command(r, 1, 1, 0, true);
    expect(r.control(c, kMaximumCommandAgeNs + 1) == Status::invalid_control, "too-old first command rejected");
    c.timestamp_ns = kMaximumCommandAgeNs + 1;
    expect(r.control(c, c.timestamp_ns) == Status::invalid_control, "rejected sequence cannot be repackaged and replayed");
    expect(!r.gate_open(), "replayed wake remains closed");
}

void render_timeline_rejects_backdated_control() {
    RouterCore r;
    Fixture f(480); f.fill_sources(1, 0, 0);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), 480, 0) == Status::ok, "10ms render");
    expect(r.next_time_ns() == 10000000, "timeline reaches end, not last sample");
    expect(r.control(command(r, 2, 2, 5000000, true), 5000000) == Status::invalid_timeline, "control within prior block rejected");
    expect(!r.gate_open() && r.next_time_ns() == 10000000, "backdated control closes without rewinding");
}

void restart_epoch() {
    RouterCore r;
    expect(r.control(command(r, 1, 1, 100, true), 100) == Status::ok, "wake");
    const auto old = command(r, 2, 2, 100, true);
    expect(r.restart() == Status::ok && r.epoch() == 2 && !r.gate_open(), "restart closed with new epoch");
    expect(r.control(old, 100) == Status::invalid_control, "old epoch wake rejected");
    expect(r.control(command(r, 1, 1, 100), 100) == Status::ok && !r.gate_open(), "new epoch heartbeat does not reopen");
    expect(r.control(command(r, 2, 2, 100, true), 100) == Status::ok && r.gate_open(), "new epoch fresh wake");
}

void malformed_buffers_close_without_overrun() {
    RouterCore r;
    Fixture f(4); f.fill_sources(1, 0, 0);
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    auto out = f.outputs(); out.dot.size = 3;
    expect(r.render(f.inputs(), out, 4, 0) == Status::invalid_buffers, "short output buffer rejected");
    expect(f.dot_out == std::vector<float>({0, 0, 0, -9}), "only declared output capacity touched");
    expect(!r.gate_open() && r.next_time_ns() == 0, "malformed block closes without advancing timeline");
    out.dot = {nullptr, 4};
    expect(r.render(f.inputs(), out, 4, 0) == Status::invalid_buffers, "null buffer rejected");
    expect(r.render(f.inputs(), f.outputs(), kMaximumFrames + 1, 0) == Status::invalid_buffers, "oversized block rejected");
    expect(r.render(f.inputs(), f.outputs(), 0, 0) == Status::invalid_buffers, "empty block rejected");
}

void render_clock_fault_keeps_independent_mixes() {
    RouterCore r;
    Fixture f(1); f.fill_sources(1, .5F, .5F);
    expect(r.control(command(r, 1, 1, 1000000, true), 1000000) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), 1, 0) == Status::invalid_timeline, "backward render rejected");
    expect(f.discord_out[0] == .75F && f.detector_out[0] == .75F && f.dot_out[0] == 0, "clock fault preserves mixes");
    expect(r.next_time_ns() == 1000000, "clock does not rewind");
}

void overflow_is_closed() {
    const auto max = std::numeric_limits<std::uint64_t>::max();
    RouterCore r;
    expect(r.control(command(r, 1, 1, max - 100, true), max - 100) == Status::time_overflow, "deadline overflow rejected");
    Fixture f(1); f.fill_sources(1, 0, 0);
    expect(r.render(f.inputs(), f.outputs(), 1, max - 100) == Status::time_overflow, "block-end overflow rejected");
    expect(!r.gate_open() && f.dot_out[0] == 0 && f.discord_out[0] == .5F, "overflow preserves valid independent mix");
    RouterCore sequence_router;
    expect(sequence_router.control(command(sequence_router, max, max, 0, true), 0) == Status::ok, "unsigned max counters accepted once");
    expect(sequence_router.control(command(sequence_router, 0, 0, 0, true), 0) == Status::invalid_control,
           "counter wrap cannot reopen");
}

void invalid_samples_fail_closed() {
    RouterCore r;
    Fixture f(3); f.fill_sources(.5F, .25F, .75F);
    f.discord[2] = std::numeric_limits<float>::quiet_NaN();
    expect(r.control(command(r, 1, 1, 0, true), 0) == Status::ok, "wake");
    expect(r.render(f.inputs(), f.outputs(), 3, 0) == Status::invalid_samples, "NaN source rejected");
    expect(f.dot_out == std::vector<float>(3, 0), "entire Dot block closed before any prefix emission");
    expect(f.discord_out == std::vector<float>(3, .625F), "invalid Discord capture does not erase valid mic to Discord");
    expect(f.detector_out[2] == .25F, "invalid source sanitized independently");
    f.discord[2] = 1.01F;
    expect(r.render(f.inputs(), f.outputs(), 3, r.next_time_ns()) == Status::invalid_samples, "out-of-range source rejected");
}

void invalid_lease_configuration() {
    for (const auto lease : {std::uint64_t{0}, kMaximumLeaseNs + 1}) {
        RouterCore r(lease);
        expect(r.control(command(r, 1, 1, 0, true), 0) == Status::invalid_configuration && !r.gate_open(), "invalid lease cannot open");
    }
}

} // namespace

int main() {
    struct Test { const char* name; void (*run)(); };
    const Test tests[] = {
        {"source matrix", source_matrix},
        {"configured routes and independent listener", configured_routes_keep_listener_independent},
        {"standby independence and priority", standby_independence},
        {"expiry inside block", expiry_inside_block},
        {"sub-sample lease", sub_sample_lease},
        {"heartbeat and fresh wake", heartbeat_and_fresh_wake},
        {"invalid controls close only Dot", invalid_controls_close_only_dot},
        {"command age and rejected replay", command_age_and_rejected_replay},
        {"render timeline rejects backdated control", render_timeline_rejects_backdated_control},
        {"restart epoch", restart_epoch},
        {"malformed buffers", malformed_buffers_close_without_overrun},
        {"render clock fault preserves mixes", render_clock_fault_keeps_independent_mixes},
        {"overflow", overflow_is_closed},
        {"invalid samples", invalid_samples_fail_closed},
        {"invalid lease configuration", invalid_lease_configuration},
    };
    std::size_t passed = 0;
    for (const auto& test : tests) {
        try { test.run(); ++passed; std::cout << "PASS " << test.name << '\n'; }
        catch (const std::exception& e) {
            std::cerr << "FAIL " << test.name << ": " << e.what() << '\n';
            return 1;
        }
    }
    std::cout << passed << " native offline tests passed\n";
    return 0;
}
