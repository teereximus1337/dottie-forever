#pragma once
#include "event_journal.hpp"
#import <Foundation/Foundation.h>
#include <array>
#include <algorithm>
#include <cmath>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace audio_router::host {
// Serialized service-thread owner, never called by the audio scheduler or a
// Core Audio callback. Only listener PCM enters the bounded child pipes.
class KeywordProcess {
public:
    enum class Action { none, wake, standby };
    ~KeywordProcess() { stop(); reap(); }
    bool start(const std::string& executable, const std::string& model,
               const std::string& wake, const std::string& standby, std::uint64_t now) {
        stop(); reap(); reset();
        wake_ = wake; standby_ = standby; started_ = now;
        int input[2]{-1,-1}, output[2]{-1,-1};
        if (pipe(input) != 0 || pipe(output) != 0) {
            for (int fd : {input[0], input[1], output[0], output[1]}) if (fd >= 0) close(fd);
            fail("worker_pipe"); return false;
        }
        for (int fd : {input[0], input[1], output[0], output[1]}) fcntl(fd, F_SETFD, FD_CLOEXEC);
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
        for (int fd : {input[0], input[1], output[0], output[1]}) posix_spawn_file_actions_addclose(&actions, fd);
        char* args[] = {const_cast<char*>(executable.c_str()), const_cast<char*>("--model-dir"),
            const_cast<char*>(model.c_str()), const_cast<char*>("--wake"), const_cast<char*>(wake.c_str()),
            const_cast<char*>("--standby"), const_cast<char*>(standby.c_str()), nullptr};
        const int result = posix_spawn(&pid_, executable.c_str(), &actions, nullptr, args, environ);
        posix_spawn_file_actions_destroy(&actions);
        close(input[0]); close(output[1]);
        if (result != 0) { close(input[1]); close(output[0]); pid_ = -1; fail("worker_spawn"); return false; }
        input_ = input[1]; output_ = output[0];
        if (fcntl(input_, F_SETFL, O_NONBLOCK) != 0 || fcntl(output_, F_SETFL, O_NONBLOCK) != 0) { fail("worker_pipe"); return false; }
        return true;
    }
    void stop() noexcept {
        if (input_ >= 0) close(input_);
        if (output_ >= 0) close(output_);
        input_ = output_ = -1;
        if (pid_ > 0) {
            kill(pid_, SIGKILL);
            if (waitpid(pid_, nullptr, WNOHANG) == 0) {
                for (auto& retired : retired_) if (retired < 0) { retired = pid_; break; }
            }
        }
        pid_ = -1; ready_ = false;
    }
    Action poll(std::uint64_t now) {
        reap(); Action action = Action::none;
        action_frames_ = action_progress_ns_ = action_sequence_ = 0;
        raw_wakes_ = raw_standbys_ = last_action_sequence_ = 0;
        if (failed_ || pid_ <= 0) return action;
        int state = 0;
        if (waitpid(pid_, &state, WNOHANG) == pid_) { pid_ = -1; fail("worker_exit"); return action; }
        std::array<char,4096> bytes{};
        for (unsigned read_count = 0; read_count < 8; ++read_count) {
            const auto count = read(output_, bytes.data(), bytes.size());
            if (count < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK) fail("worker_read"); break; }
            if (count == 0) { fail("worker_eof"); break; }
            events_.append(bytes.data(), static_cast<std::size_t>(count));
            std::size_t newline;
            while ((newline = events_.find('\n')) != std::string::npos) {
                if (newline > 8192) { fail("worker_protocol"); break; }
                NSData* data = [NSData dataWithBytes:events_.data() length:newline];
                id event = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
                events_.erase(0, newline + 1);
                const auto next = accept(event, now);
                if (next != Action::none) { next == Action::wake ? ++raw_wakes_ : ++raw_standbys_; last_action_sequence_ = sequence_; }
                if (next == Action::standby || (next == Action::wake && action != Action::standby)) {
                    action = next; action_frames_ = consumed_; action_progress_ns_ = progress_ns_; action_sequence_ = sequence_;
                }
                if (failed_) break;
            }
            if (events_.size() > 8192) fail("worker_protocol");
            if (failed_) break;
        }
        if (!failed_ && ((!ready_ && now - started_ > 15000000000ULL) ||
            (ready_ && now - (progress_ns_ ? progress_ns_ : ready_ns_) > 750000000))) fail("worker_timeout");
        return failed_ ? Action::none : action;
    }
    void feed(const float* samples, std::size_t frames) {
        if (!ready_ || failed_) return;
        // 63-tap low-pass before 3:1 decimation. Fixed state avoids aliasing
        // source playback into recognizer speech bands.
        for (std::size_t i = 0; i < frames; ++i) {
            if (!std::isfinite(samples[i])) { fail("worker_pcm"); return; }
            history_[history_index_] = samples[i]; history_index_ = (history_index_ + 1) % history_.size();
            if (++phase_ != 3) continue;
            phase_ = 0;
            if (queued_ == pcm_.size()) { fail("worker_backpressure"); return; }
            float output = 0;
            for (std::size_t j = 0; j < history_.size(); ++j) output += history_[(history_index_ + history_.size() - 1 - j) % history_.size()] * kernel_[j];
            pcm_[(head_ + queued_) % pcm_.size()] = std::clamp(output, -1.0F, 1.0F); ++queued_;
        }
        for (unsigned turn = 0; turn < 16 && queued_; ++turn) {
            const auto frames_to_write = std::min({queued_, pcm_.size() - head_, std::size_t{160}});
            const auto count = write(input_, pcm_.data() + head_, frames_to_write * sizeof(float));
            if (count < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK) fail("worker_write"); return; }
            if (count != static_cast<ssize_t>(frames_to_write * sizeof(float))) { fail("worker_write"); return; }
            head_ = (head_ + frames_to_write) % pcm_.size(); queued_ -= frames_to_write; sent_ += frames_to_write;
        }
    }
    bool healthy(std::uint64_t now) const noexcept { return ready_ && !failed_ && progress_ns_ && now >= progress_ns_ && now - progress_ns_ <= 500000000 && sent_ >= consumed_ && sent_ - consumed_ <= 8000; }
    bool ready() const noexcept { return ready_ && !failed_; }
    bool failed() const noexcept { return failed_; }
    std::uint64_t frames() const noexcept { return consumed_; }
    std::uint64_t sequence() const noexcept { return sequence_; }
    std::uint64_t progress_time_ns() const noexcept { return progress_ns_; }
    std::uint64_t action_frames() const noexcept { return action_frames_; }
    std::uint64_t action_progress_ns() const noexcept { return action_progress_ns_; }
    std::uint64_t action_sequence() const noexcept { return action_sequence_; }
    std::uint64_t raw_wakes() const noexcept { return raw_wakes_; }
    std::uint64_t raw_standbys() const noexcept { return raw_standbys_; }
    std::uint64_t last_action_sequence() const noexcept { return last_action_sequence_; }
    DetectorProfile model_profile() const noexcept { return model_profile_; }
    const std::string& error() const noexcept { return error_; }
    pid_t pid() const noexcept { return pid_; }
private:
    static bool unsigned_value(id value, std::uint64_t& result) {
        if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
        const double numeric = [value doubleValue];
        if (!std::isfinite(numeric) || numeric < 0 || numeric > 9007199254740991.0 || std::floor(numeric) != numeric) return false;
        result = [value unsignedLongLongValue]; return true;
    }
    Action accept(id value, std::uint64_t now) {
        if (![value isKindOfClass:[NSDictionary class]] || ![value[@"event"] isKindOfClass:[NSString class]]) { fail("worker_protocol"); return Action::none; }
        NSString* event = value[@"event"];
        if ([event isEqualToString:@"ready"]) {
            std::uint64_t protocol = 0, rate = 0;
            if (ready_ || !unsigned_value(value[@"protocol"], protocol) || protocol != 1 ||
                !unsigned_value(value[@"sample_rate"], rate) || rate != 16000 ||
                ![value[@"wake"] isKindOfClass:[NSString class]] || ![value[@"standby"] isKindOfClass:[NSString class]] ||
                wake_ != [value[@"wake"] UTF8String] || standby_ != [value[@"standby"] UTF8String]) fail("worker_protocol");
            else {
                ready_ = true; ready_ns_ = now;
                std::uint64_t paths = 0;
                if ([value[@"model_profile"] isKindOfClass:[NSString class]] && [value[@"model_profile"] isEqualToString:@"gigaspeech3.3m-fp32-paths8-v1"] &&
                    [value[@"model_name"] isKindOfClass:[NSString class]] && [value[@"model_name"] isEqualToString:@"sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"] &&
                    [value[@"precision"] isKindOfClass:[NSString class]] && [value[@"precision"] isEqualToString:@"fp32"] && unsigned_value(value[@"max_active_paths"], paths) && paths == 8)
                    model_profile_ = DetectorProfile::gigaspeech_fp32_paths8;
            }
            return Action::none;
        }
        if ([event isEqualToString:@"error"] || [event isEqualToString:@"eof"]) { fail([event isEqualToString:@"error"] ? "worker_error" : "worker_eof"); return Action::none; }
        const bool progress = [event isEqualToString:@"progress"], wake = [event isEqualToString:@"wake"], standby = [event isEqualToString:@"standby"];
        std::uint64_t sequence = 0, frames = 0;
        if (!ready_ || (!progress && !wake && !standby) || !unsigned_value(value[@"sequence"], sequence) ||
            !unsigned_value(value[@"frames"], frames) || sequence <= sequence_ || frames < consumed_ || frames > sent_ ||
            (progress && frames == consumed_) || (!progress && (frames != consumed_ || !progress_ns_))) { fail("worker_protocol"); return Action::none; }
        if ((wake || standby) && (![value[@"phrase"] isKindOfClass:[NSString class]] ||
            (wake ? wake_ : standby_) != [value[@"phrase"] UTF8String])) { fail("worker_protocol"); return Action::none; }
        sequence_ = sequence;
        if (frames > consumed_) { consumed_ = frames; progress_ns_ = now; }
        return standby ? Action::standby : wake ? Action::wake : Action::none;
    }
    void fail(const char* message) { failed_ = true; error_ = message; stop(); }
    void reap() noexcept { for (auto& child : retired_) if (child > 0 && waitpid(child, nullptr, WNOHANG) != 0) child = -1; }
    void reset() {
        failed_ = false; ready_ = false; events_.clear(); error_.clear();
        model_profile_ = DetectorProfile::unknown;
        head_ = queued_ = history_index_ = phase_ = 0; sent_ = consumed_ = sequence_ = progress_ns_ = ready_ns_ = 0;
        action_frames_ = action_progress_ns_ = action_sequence_ = 0;
        raw_wakes_ = raw_standbys_ = last_action_sequence_ = 0;
        history_.fill(0); pcm_.fill(0);
        constexpr double pi = 3.14159265358979323846, cutoff = 7000.0 / 48000.0;
        double sum = 0;
        for (std::size_t i = 0; i < kernel_.size(); ++i) {
            const double x = static_cast<double>(i) - 31;
            const double sinc = x == 0 ? 2 * cutoff : std::sin(2 * pi * cutoff * x) / (pi * x);
            kernel_[i] = static_cast<float>(sinc * (.54 - .46 * std::cos(2 * pi * i / 62))); sum += kernel_[i];
        }
        for (auto& coefficient : kernel_) coefficient /= static_cast<float>(sum);
    }
    int input_ = -1, output_ = -1;
    pid_t pid_ = -1;
    std::array<pid_t,16> retired_{{-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1}};
    std::array<float,3200> pcm_{};
    std::array<float,63> history_{}, kernel_{};
    std::size_t head_ = 0, queued_ = 0, history_index_ = 0, phase_ = 0;
    std::uint64_t started_ = 0, ready_ns_ = 0, progress_ns_ = 0, sent_ = 0, consumed_ = 0, sequence_ = 0;
    std::uint64_t action_frames_ = 0, action_progress_ns_ = 0, action_sequence_ = 0;
    std::uint64_t raw_wakes_ = 0, raw_standbys_ = 0, last_action_sequence_ = 0;
    bool ready_ = false, failed_ = false;
    DetectorProfile model_profile_ = DetectorProfile::unknown;
    std::string events_, error_, wake_, standby_;
};
} // namespace audio_router::host
