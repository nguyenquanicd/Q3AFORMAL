#pragma once

#include <algorithm>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <utility>

namespace q3a::frontend {

using PackedBounds = std::pair<std::int64_t, std::int64_t>;

struct PackedSelection {
    std::uint64_t offset;
    std::uint64_t width;
};

inline PackedSelection resolve_packed_select(PackedBounds bounds, std::uint64_t vector_width,
                                             std::int64_t first, std::optional<std::int64_t> last) {
    const auto [left, right] = bounds;
    const auto offset = [&](std::int64_t index) {
        if (index < std::min(left, right) || index > std::max(left, right)) {
            throw std::invalid_argument("constant select index is outside the declared packed range");
        }
        const auto end = static_cast<std::uint64_t>(right);
        const auto bit = static_cast<std::uint64_t>(index);
        const auto mapped = left >= right ? bit - end : end - bit;
        if (mapped >= vector_width) {
            throw std::invalid_argument("constant select index does not map inside the declared packed width");
        }
        return mapped;
    };
    const auto first_offset = offset(first);
    if (!last) return {first_offset, 1};
    if ((left >= right && first < *last) || (left < right && first > *last)) {
        throw std::invalid_argument("part-select direction must match the declared packed range");
    }
    const auto last_offset = offset(*last);
    return {last_offset, first_offset - last_offset + 1};
}

} // namespace q3a::frontend
