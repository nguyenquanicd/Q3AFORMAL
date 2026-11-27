#pragma once

#include "debug_view.hpp"
#include "../lowering/event_mask_source.hpp"
#include "../source_manager/source_manager.hpp"

namespace q3a::bundle {

VerifiedDebugSession open_event_debug_session(const std::filesystem::path& directory,
    const lowering::EventMaskModel& model, const ProjectInput& project,
    const std::string& name, const MemoryBudget& memory);

} // namespace q3a::bundle
