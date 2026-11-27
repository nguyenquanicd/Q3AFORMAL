#pragma once

#include "lowering.hpp"

#include <string_view>

namespace q3a::lowering {

// Compiles the finite sequence into initialized transition state and a
// same-sample check. If supplied, the one-bit sample input gates monitor
// progress and property decisions independently of global steps.
std::uint64_t lower_sequence_monitor(TIRModule& model, TIRProperty& property,
    std::size_t& generated_signals, std::uint64_t maximum_offset, std::string_view sample_enable = {},
    std::string* boundary_pending = nullptr);

} // namespace q3a::lowering
