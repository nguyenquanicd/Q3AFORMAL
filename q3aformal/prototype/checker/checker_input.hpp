#pragma once

#include "drat_checker.hpp"

#include <algorithm>
#include <array>
#include <istream>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace q3a::checker::detail {

class ResourceLimitError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

inline void check_memory(const CheckerLimits& limits, std::uint64_t pending_bytes) {
    if (!limits.check_memory) return;
    try {
        limits.check_memory(pending_bytes);
    } catch (const std::exception& error) {
        throw ResourceLimitError(std::string("DRAT checker memory budget: ") + error.what());
    }
}

class MemoryPoller {
public:
    explicit MemoryPoller(const CheckerLimits& limits) : limits_(limits) {}

    void check(std::uint64_t pending_bytes = 0) const {
        check_memory(limits_, pending_bytes);
    }

    void poll(std::uint64_t pending_bytes = 0) {
        if (limits_.check_memory && (++operations_ % 1024 == 0 || pending_bytes >= 1024 * 1024)) {
            check(pending_bytes);
        }
    }

private:
    const CheckerLimits& limits_;
    std::uint32_t operations_ = 0;
};

template <typename Element>
std::uint64_t append_allocation(const std::vector<Element>& values) {
    return values.size() == values.capacity()
        ? std::uint64_t{sizeof(Element)} * (2 * values.capacity() + 1) : 0;
}

inline bool read_bounded_line(std::istream& input, std::string& line,
                              const CheckerLimits& limits, std::string_view source) {
    line.clear();
    std::array<char, 4096> buffer;
    for (;;) {
        input.getline(buffer.data(), buffer.size());
        const auto extracted = input.gcount();
        const bool full = input.fail() && !input.eof() &&
            extracted == static_cast<std::streamsize>(buffer.size() - 1);
        if (input.bad() || (input.fail() && !input.eof() && !full)) {
            throw std::runtime_error("failed while reading " + std::string(source));
        }
        const bool newline = !input.fail() && !input.eof();
        const auto bytes = static_cast<std::size_t>(extracted - (newline ? 1 : 0));
        if (bytes > limits.maximum_line_bytes - line.size()) {
            throw ResourceLimitError("DRAT checker line byte limit exceeded in " +
                                     std::string(source));
        }
        const auto required = line.size() + bytes;
        if (required > line.capacity()) {
            const auto capacity = std::min<std::uint64_t>(limits.maximum_line_bytes,
                std::max(required, line.capacity() * 2));
            check_memory(limits, capacity);
            line.reserve(static_cast<std::size_t>(capacity));
        }
        line.append(buffer.data(), bytes);
        if (!full) return newline || !line.empty();
        input.clear(input.rdstate() & ~std::ios::failbit);
    }
}

} // namespace q3a::checker::detail
