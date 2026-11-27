#pragma once

#include "lowering.hpp"

#include <map>

namespace q3a::lowering {

struct EventMaskModel {
    TIRModule transition;
    std::map<std::string, std::string> edge_inputs;
    std::map<std::string, std::string> state_domains;
    std::map<std::string, std::string> property_domains;
    std::map<std::string, std::string> pending_at_boundary;
};

inline constexpr const char* kFreeEventMaskProfile = "Q3A-FREE-EVENT-MASK-DEVELOPMENT";
inline constexpr const char* kGlobalEventStep = "__q3a_global_event_step";

// Development source path for flat positive-edge RTL. A global step executes
// each domain whose independent event input is high, with a common pre-state.
EventMaskModel lower_free_event_mask(const std::vector<frontend::SyntaxUnit>& units,
                                    const elaboration::ElaborationResult& design);

// Internal extraction used by the event-mask adapter. Each state equation gets
// its owning source clock from the normal always_ff compiler.
TIRModule lower_event_domain_equations(const std::vector<frontend::SyntaxUnit>& units,
    const elaboration::ElaborationResult& design, std::map<std::string, std::string>& owners);

} // namespace q3a::lowering
