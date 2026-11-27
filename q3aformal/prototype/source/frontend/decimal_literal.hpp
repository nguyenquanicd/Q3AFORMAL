#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace q3a::frontend {

struct UnsizedDecimal {
    std::uint64_t value;
    std::uint64_t width;
};

// The minus sign is a separate unary operator. A positive signed decimal
// token needs one sign bit in addition to its magnitude bits.
inline std::optional<UnsizedDecimal> decode_unsized_decimal(std::string_view text) {
    constexpr auto max_value =
        static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    if (text.empty() || text.front() < '0' || text.front() > '9') return std::nullopt;
    std::uint64_t value = 0;
    for (const char character : text) {
        if (character == '_') continue;
        if (character < '0' || character > '9') return std::nullopt;
        const auto digit = static_cast<std::uint64_t>(character - '0');
        if (value > (max_value - digit) / 10) return std::nullopt;
        value = 10 * value + digit;
    }
    std::uint64_t signed_width = 1;
    for (auto magnitude = value; magnitude != 0; magnitude >>= 1) ++signed_width;
    return UnsizedDecimal{value, std::max<std::uint64_t>(32, signed_width)};
}

} // namespace q3a::frontend
