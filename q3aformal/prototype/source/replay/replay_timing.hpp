#pragma once

#include <chrono>
#include <cstdlib>
#include <ostream>

namespace q3a::replay {

// Exploratory diagnostics are opt-in and are emitted separately from proof results.
class ReplayTiming {
public:
    using Clock = std::chrono::steady_clock;
    using Duration = std::chrono::nanoseconds;

    explicit ReplayTiming(bool replay_command) {
        const auto* value = replay_command ? std::getenv("Q3A_REPLAY_TIMING") : nullptr;
        enabled_ = value && value[0] == '1' && value[1] == '\0';
    }

    Clock::time_point start() const {
        return enabled_ ? Clock::now() : Clock::time_point{};
    }

    Duration elapsed(Clock::time_point start) const {
        return enabled_ ? std::chrono::duration_cast<Duration>(Clock::now() - start) : Duration{};
    }

    void write(std::ostream& out, const char* stage, Duration elapsed) const {
        if (enabled_) out << "Q3A_REPLAY_TIMING " << stage << ' ' << elapsed.count() << '\n';
    }

private:
    bool enabled_ = false;
};

} // namespace q3a::replay
