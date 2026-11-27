#pragma once

#include "debug_view.hpp"
#include "../source_manager/source_manager.hpp"

namespace q3a::bundle {

VerifiedDebugSession open_memory_range_debug_session(const std::filesystem::path& trace_path,
    const lowering::TIRModule& model, const ProjectInput& project, const std::string& property,
    const MemoryBudget& memory);

} // namespace q3a::bundle
