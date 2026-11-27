#pragma once

#include "debug_view.hpp"

#include <filesystem>
#include <iosfwd>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace q3a { class MemoryBudget; struct ProjectInput; }
namespace q3a::lowering { struct TIRModule; }
namespace q3a::pdr { struct CheckedCertificate; }

namespace q3a::debug { struct WaveViewport; }
namespace q3a::bundle {

std::optional<std::string> verify_pdr_run_configuration(const std::filesystem::path& directory,
    const ProjectInput& project, const lowering::TIRModule& original, const std::string& property,
    bool activation, const pdr::CheckedCertificate& certificate, const MemoryBudget& memory,
    bool require_exact_project_identity = false);

class VerificationResourceLimit : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

// Verifies bundle integrity and rechecks compatible checked-DRAT artifacts.
// It never extracts files or modifies the bundle.
void verify_result_bundle(const std::filesystem::path& bundle_directory,
                          std::ostream& output);

// Opens a formal bundle directory or validates a saved interruption record.
// Source-required mode accepts only bundles that reproduce the saved model from
// their archived sources and whose evidence can be revalidated.
void reopen_saved_run(const std::filesystem::path& path, std::ostream& output,
                      bool require_source_model = false);

// Recheck a completed batch result against its exact job and source-backed evidence.
void verify_batch_checkpoint(const std::filesystem::path& directory, const ProjectInput& project,
    std::string_view payload, std::string_view engine, std::string_view property, std::uint64_t depth,
    std::uint64_t timeout_ms, std::uint64_t memory_mib, std::uint64_t maximum_queries,
    std::uint64_t feasibility_frames, const lowering::TIRModule* pdr_model,
    const MemoryBudget& memory);

struct DebugOptions {
    std::string obligation;
    std::map<std::string, std::string> resets;
    std::map<std::string, std::vector<std::string>> groups;
};

VerifiedDebugSession open_verified_debug_session(const std::filesystem::path& bundle_directory,
                                                 const DebugOptions& options, bool require_source_model = true);

q3a::debug::WaveViewport read_native_wave_viewport(const VerifiedDebugSession& session,
    std::uint64_t first, std::uint64_t last, std::uint64_t cursor,
    const std::vector<std::string>& selected);

void write_verified_debug_page(const std::filesystem::path& bundle_directory,
                               const DebugOptions& options, std::ostream& output);

} // namespace q3a::bundle
