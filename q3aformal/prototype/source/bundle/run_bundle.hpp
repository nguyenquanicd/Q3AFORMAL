#pragma once

#include "../source_manager/source_manager.hpp"
#include "../replay/property_replay.hpp"
#include "trace_capture.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <iosfwd>
#include <map>
#include <string>
#include <vector>

namespace q3a::bundle {

std::string json_string(const std::string& value);
inline constexpr const char* kRunConfigurationPath = "reports/run-configuration.json";
inline constexpr const char* kResetInitialPolicy =
    "Q3A-P0-R0.9.1: synchronous reset is modeled in each transition; RTL initial state is unconstrained; "
    "generated $past history-valid state is false in base/BMC frame zero and arbitrary in the induction step";

struct ComponentFingerprint {
    std::string id;
    std::string source_sha256;
};

struct QueryEvidence {
    std::string id;
    std::string kind;
    std::string algorithm;
    std::string property;
    std::uint64_t bound = 0;
    std::string status;
    std::string cnf_path;
    std::string cnf_content;
    std::function<void(std::ostream&)> write_cnf = {};
};

struct ArtifactInput {
    std::string path;
    std::string role;
    // Invoked synchronously while the bundle is staged.
    std::function<void(std::ostream&)> write;
};

struct RunBundleRequest {
    std::filesystem::path output_directory;
    std::filesystem::path executable_path;
    std::string compiler;
    std::string build_id;
    std::vector<ComponentFingerprint> components;
    std::string command;
    std::string status;
    std::string property;
    std::string algorithm;
    std::string detail;
    std::string vacuity = "NOT_APPLICABLE";
    std::string boundary_obligations = "COMPLETE";
    std::string model_schema;
    std::string model_json;
    std::string project_manifest_content;
    std::string run_configuration;
    std::string sampling_clock;
    trace::PropertySignals property_signals;
    std::string checker_id;
    std::string checker_fingerprint;
    std::string checker_artifact_schema;
    std::uint64_t bound = 0;
    std::uint64_t duration_ms = 0;
    std::uint64_t decision_limit = 0;
    std::uint64_t propagation_limit = 0;
    std::vector<std::string> assumptions;
    std::vector<QueryEvidence> queries;
    std::vector<ArtifactInput> artifacts;
};

// Creates a new portable bundle directory and refuses to overwrite existing data.
void write_result_bundle(const ProjectInput& project,
                        const RunBundleRequest& request);

void write_trace_json(
    std::ostream& output,
    const replay::FrameView& trace,
    const std::string& property,
    std::size_t candidate_frame);

void write_induction_witness_text(
    std::ostream& output, const lowering::TIRModule& model, const replay::FrameView& frames,
    const std::string& property, replay::InductionObligation obligation, std::uint64_t depth,
    std::size_t failure_frame, const std::string& model_hash, const std::string& query_hash);

} // namespace q3a::bundle
