#include "drat_checker.hpp"
#include "drat_prover.hpp"
#include "proof_artifact.hpp"
#include "../source/source_manager/source_manager.hpp"
#include "../source/source_manager/write_locked_input.hpp"
#include "../source/bundle/windows_file_path.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <new>
#include <string>
#include <string_view>

namespace {

std::filesystem::path proof_file_path(const char* argument) {
    return q3a::bundle::detail::windows_file_path(
        std::filesystem::absolute(std::filesystem::u8path(argument)));
}

class StagedArtifact {
public:
    explicit StagedArtifact(const std::filesystem::path& destination) {
        const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
        for (unsigned attempt = 0; attempt < 8; ++attempt) {
            directory_ = destination;
            directory_ += ".stage-" + std::to_string(nonce) + "-" + std::to_string(attempt);
            path_ = directory_ / "artifact";
            if (std::filesystem::create_directory(directory_)) return;
        }
        throw std::runtime_error("cannot reserve a directory for staged proof output");
    }

    StagedArtifact(const StagedArtifact&) = delete;
    StagedArtifact& operator=(const StagedArtifact&) = delete;

    ~StagedArtifact() {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
        std::filesystem::remove(directory_, ignored);
    }

    const std::filesystem::path& path() const { return path_; }

private:
    std::filesystem::path directory_;
    std::filesystem::path path_;
};

bool same_existing_file(
    const std::filesystem::path& left,
    const std::filesystem::path& right) {
    std::error_code error;
    if (!std::filesystem::exists(left, error) || error) return false;
    error.clear();
    if (!std::filesystem::exists(right, error) || error) return false;
    error.clear();
    const bool equivalent = std::filesystem::equivalent(left, right, error);
    if (error) throw std::runtime_error("cannot compare proof input/output paths");
    return equivalent;
}

void usage() {
    std::cerr << "usage:\n"
              << "  q3aformal-proofcheck --create-drat <input.cnf> <output.q3adrat> "
                 "--model-sha256 <hash> --query-kind <kind>\n"
              << "  q3aformal-proofcheck --check-drat <input.cnf> <proof.q3adrat> "
                 "--model-sha256 <hash> --query-kind <kind>\n";
}

int create_artifact(int argc, char** argv) {
    if (argc != 8 || std::string(argv[4]) != "--model-sha256" ||
        std::string(argv[6]) != "--query-kind") {
        usage();
        return 2;
    }
    const auto cnf_path = proof_file_path(argv[2]);
    const auto artifact_path = proof_file_path(argv[3]);
    if (same_existing_file(cnf_path, artifact_path)) {
        std::cerr << "Q3A_PROOF_ERROR output path must not overwrite the CNF input\n";
        return 1;
    }
    const q3a::MemoryBudget memory_budget;
    memory_budget.check();
    q3a::WriteLockedInput cnf_file(cnf_path);
    auto& cnf_input = cnf_file.stream();
    const auto query_hash = q3a::sha256_stream(cnf_input);
    cnf_file.rewind();
    q3a::checker::ProofLimits limits;
    limits.input_limits.check_memory = [&](std::uint64_t pending) { memory_budget.check(pending); };
    auto proof = q3a::checker::generate_rup_refutation(cnf_input, limits);
    if (proof.status == q3a::checker::ProofStatus::Satisfiable) {
        std::cout << "Q3A_PROOF_STATUS SAT_NO_REFUTATION\n"
                  << "Q3A_PROOF_SEARCH_NODES " << proof.search_nodes << '\n';
        return 0;
    }
    if (proof.status == q3a::checker::ProofStatus::Unknown) {
        if (proof.message.rfind("invalid CNF:", 0) == 0) {
            std::cerr << "Q3A_PROOF_ERROR " << proof.message << '\n';
            return 1;
        }
        std::cout << "Q3A_PROOF_STATUS UNKNOWN\n"
                  << "Q3A_PROOF_DIAGNOSTIC " << proof.message << '\n';
        return 3;
    }

    const q3a::checker::ArtifactMetadata metadata{
        argv[7], q3a::checker::kCheckerId, argv[5], query_hash};
    const StagedArtifact staging(artifact_path);
    {
        std::ofstream staged_output(staging.path(), std::ios::binary);
        if (!staged_output) throw std::runtime_error("cannot open staged proof output");
        const auto write_result = q3a::checker::write_drat_artifact(
            proof, metadata, staged_output);
        if (!write_result.accepted) throw std::runtime_error(write_result.message);
        staged_output.close();
        if (!staged_output) throw std::runtime_error("cannot finish staged proof output");
    }
    const auto records = proof.additions.size();
    const auto search_nodes = proof.search_nodes;
    proof = {};

    cnf_file.rewind();
    q3a::checker::CheckResult self_check;
    {
        std::ifstream staged_input(staging.path(), std::ios::binary);
        if (!staged_input) throw std::runtime_error("cannot reopen staged proof output");
        self_check = q3a::checker::verify_drat_artifact(
            cnf_input, staged_input, metadata, limits.input_limits);
    }
    if (!self_check.accepted) {
        if (self_check.resource_limited) {
            std::cout << "Q3A_PROOF_STATUS UNKNOWN\n"
                      << "Q3A_PROOF_DIAGNOSTIC " << self_check.message << '\n';
            return 3;
        }
        std::cerr << "Q3A_PROOF_ERROR generated artifact failed independent checking: "
                  << self_check.message << '\n';
        return 1;
    }

    if (same_existing_file(cnf_path, artifact_path)) {
        std::cerr << "Q3A_PROOF_ERROR output path must not overwrite the CNF input\n";
        return 1;
    }
    std::filesystem::rename(staging.path(), artifact_path);
    std::cout << "Q3A_PROOF_STATUS DRAT_WRITTEN_AND_CHECKED\n"
              << "Q3A_PROOF_RECORDS " << records << '\n'
              << "Q3A_PROOF_SEARCH_NODES " << search_nodes << '\n'
              << "Q3A_PROOF_CHECKER_ID " << metadata.checker_id << '\n'
              << "Q3A_PROOF_MODEL_SHA256 " << metadata.model_sha256 << '\n'
              << "Q3A_PROOF_QUERY_SHA256 " << metadata.query_sha256 << '\n';
    return 0;
}

int check_artifact(int argc, char** argv) {
    if (argc != 8 || std::string(argv[4]) != "--model-sha256" ||
        std::string(argv[6]) != "--query-kind") {
        usage();
        return 2;
    }
    const q3a::MemoryBudget memory_budget;
    memory_budget.check();
    // Keep one handle open with writes denied across hashing and verification.
    q3a::WriteLockedInput cnf_file(proof_file_path(argv[2]));
    auto& cnf_input = cnf_file.stream();
    const auto query_hash = q3a::sha256_stream(cnf_input);
    cnf_file.rewind();
    q3a::WriteLockedInput artifact_input(proof_file_path(argv[3]));
    const q3a::checker::ArtifactMetadata expected{
        argv[7], q3a::checker::kCheckerId, argv[5], query_hash};
    q3a::checker::CheckerLimits limits;
    limits.check_memory = [&](std::uint64_t pending) { memory_budget.check(pending); };
    const auto result = q3a::checker::verify_drat_artifact(
        cnf_input, artifact_input.stream(), expected, limits);
    if (!result.accepted) {
        if (result.resource_limited) {
            std::cout << "Q3A_PROOF_CHECK RESOURCE_LIMIT\n"
                      << "Q3A_PROOF_DIAGNOSTIC " << result.message << '\n';
            return 3;
        }
        std::cerr << "Q3A_PROOF_CHECK REJECTED\n"
                  << "Q3A_PROOF_DIAGNOSTIC " << result.message << '\n';
        return 1;
    }
    std::cout << "Q3A_PROOF_CHECK ACCEPTED\n"
              << "Q3A_PROOF_RECORDS " << result.proof_records << '\n'
              << "Q3A_PROOF_CHECKER_ID " << expected.checker_id << '\n'
              << "Q3A_PROOF_MODEL_SHA256 " << expected.model_sha256 << '\n'
              << "Q3A_PROOF_QUERY_SHA256 " << expected.query_sha256 << '\n';
    return 0;
}

} // namespace

static int cli_main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--version") {
        std::cout << "Q3A_PROOF_CHECKER_ID " << q3a::checker::kCheckerId << '\n'
                  << "Q3A_PROOF_ARTIFACT_SCHEMA "
                  << q3a::checker::kProofArtifactSchema << '\n';
        return 0;
    }
    const bool creating = argc >= 2 && std::string_view(argv[1]) == "--create-drat";
    try {
        if (creating) {
            return create_artifact(argc, argv);
        }
        if (argc >= 2 && std::string(argv[1]) == "--check-drat") {
            return check_artifact(argc, argv);
        }
        usage();
        return 2;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cout << (creating ? "Q3A_PROOF_STATUS UNKNOWN\n" :
                                  "Q3A_PROOF_CHECK RESOURCE_LIMIT\n")
                  << "Q3A_PROOF_DIAGNOSTIC " << error.what() << '\n';
        return 3;
    } catch (const std::bad_alloc&) {
        std::cout << (creating ? "Q3A_PROOF_STATUS UNKNOWN\n" :
                                  "Q3A_PROOF_CHECK RESOURCE_LIMIT\n")
                  << "Q3A_PROOF_DIAGNOSTIC memory allocation failed\n";
        return 3;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PROOF_ERROR " << error.what() << '\n';
        return 1;
    }
}

int wmain(int argc, wchar_t** argv) {
    return q3a::run_utf8_command_line(argc, argv, cli_main);
}
