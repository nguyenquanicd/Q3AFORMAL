#pragma once

#include "lowering.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>

namespace q3a {

inline std::uint64_t induction_feasibility_bound(const lowering::TIRModule& model,
    const lowering::TIRProperty& target, std::uint64_t depth) {
    constexpr std::uint64_t maximum_transitions = 10000;
    const auto target_horizon = lowering::bounded_induction_property_horizon(target);
    if (!target_horizon || depth == 0 || *target_horizon > maximum_transitions ||
        depth > maximum_transitions - *target_horizon) {
        throw std::invalid_argument("induction depth plus the target horizon exceeds the supported profile");
    }
    auto bound = depth + *target_horizon;
    for (const auto& property : model.properties) {
        if (property.kind != "assume") continue;
        const auto horizon = lowering::bounded_induction_property_horizon(property);
        if (!horizon) {
            throw std::invalid_argument("k-induction assumptions require supported finite sequences or implications");
        }
        bound = std::max(bound, *horizon);
    }
    return bound;
}

} // namespace q3a
