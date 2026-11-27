#include "../source/cache/proof_cache.hpp"
#include "../source/source_manager/platform_support.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::string hash(const std::string& text) {
    const std::vector<std::uint8_t> bytes(text.begin(), text.end());
    return q3a::sha256_hex(bytes);
}

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

q3a::cache::ProofIdentity identity() {
    q3a::cache::ProofIdentity result;
    result.profile_id = "Q3A-P0-R0.9.1";
    result.input_sha256 = std::string(64, '1');
    result.model_sha256 = std::string(64, '2');
    result.model_schema = "Q3A-TIR-1";
    result.build_id = std::string(64, '3');
    result.checker_fingerprint = std::string(64, '4');
    result.algorithm = "k-induction-cdcl-rup";
    result.property = "p_invariant";
    result.obligation = "base";
    result.solver_options = "decisions=1000000;proof_records=1000000";
    result.depth = 1;
    return result;
}

q3a::checker::ArtifactMetadata metadata(const std::string& cnf) {
    q3a::checker::ArtifactMetadata result;
    result.query_kind = "induction-base";
    result.checker_id = q3a::checker::kCheckerId;
    result.model_sha256 = std::string(64, '2');
    result.query_sha256 = hash(cnf);
    return result;
}

std::string make_artifact(const std::string& cnf,
                          const q3a::checker::ArtifactMetadata& artifact_metadata) {
    q3a::checker::ProofResult proof;
    proof.status = q3a::checker::ProofStatus::Unsatisfiable;
    proof.additions.push_back({});
    std::ostringstream output;
    const auto written = q3a::checker::write_drat_artifact(
        proof, artifact_metadata, output);
    require(written.accepted, "test DRAT artifact could not be written");
    std::istringstream cnf_input(cnf);
    std::istringstream artifact_input(output.str());
    const auto checked = q3a::checker::verify_drat_artifact(
        cnf_input, artifact_input, artifact_metadata);
    require(checked.accepted, "test DRAT artifact is not valid: " + checked.message);
    return output.str();
}

template <typename IdentityMutator, typename MetadataMutator>
void require_key_change(const std::string& label,
                        const q3a::cache::ProofIdentity& original,
                        const std::string& cnf,
                        const q3a::checker::ArtifactMetadata& original_metadata,
                        IdentityMutator mutate_identity,
                        MetadataMutator mutate_metadata) {
    auto changed_identity = original;
    auto changed_metadata = original_metadata;
    mutate_identity(changed_identity);
    mutate_metadata(changed_metadata);
    const auto original_key = q3a::cache::proof_cache_key(
        original, cnf, original_metadata);
    const auto changed_key = q3a::cache::proof_cache_key(
        changed_identity, cnf, changed_metadata);
    require(original_key != changed_key,
            "cache key did not change when " + label + " changed");
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: proof_cache_test <cache-root>");
        const auto cache_root = std::filesystem::u8path(argv[1]);
        std::filesystem::create_directories(cache_root);
        const auto cnf_path = cache_root / "test-query.cnf";
        const auto proof_path = cache_root / "test-proof.q3adrat";
        const auto hit_path = cache_root / "test-hit.q3adrat";
        const std::string cnf = "p cnf 1 2\n1 0\n-1 0\n";
        const auto base_identity = identity();
        const auto base_metadata = metadata(cnf);
        const auto base_key = q3a::cache::proof_cache_key(
            base_identity, cnf, base_metadata);

        require_key_change("profile identity", base_identity, cnf, base_metadata,
            [](auto& value) { value.profile_id += "-changed"; },
            [](auto&) {});
        require_key_change("source-set identity", base_identity, cnf, base_metadata,
            [](auto& value) { value.input_sha256[0] = 'a'; },
            [](auto&) {});
        require_key_change("model identity", base_identity, cnf, base_metadata,
            [](auto& value) { value.model_sha256[0] = 'a'; },
            [](auto& value) { value.model_sha256[0] = 'a'; });
        require_key_change("model schema", base_identity, cnf, base_metadata,
            [](auto& value) { value.model_schema += "-changed"; },
            [](auto&) {});
        require_key_change("build identity", base_identity, cnf, base_metadata,
            [](auto& value) { value.build_id[0] = 'a'; },
            [](auto&) {});
        require_key_change("checker fingerprint", base_identity, cnf, base_metadata,
            [](auto& value) { value.checker_fingerprint[0] = 'a'; },
            [](auto&) {});
        require_key_change("checker identity", base_identity, cnf, base_metadata,
            [](auto&) {},
            [](auto& value) { value.checker_id += "-next"; });
        require_key_change("query kind", base_identity, cnf, base_metadata,
            [](auto&) {},
            [](auto& value) { value.query_kind += "-next"; });
        require_key_change("algorithm", base_identity, cnf, base_metadata,
            [](auto& value) { value.algorithm += "-next"; },
            [](auto&) {});
        require_key_change("property", base_identity, cnf, base_metadata,
            [](auto& value) { value.property += "_next"; },
            [](auto&) {});
        require_key_change("obligation", base_identity, cnf, base_metadata,
            [](auto& value) { value.obligation = "step"; },
            [](auto&) {});
        require_key_change("depth", base_identity, cnf, base_metadata,
            [](auto& value) { ++value.depth; },
            [](auto&) {});
        require_key_change("solver options", base_identity, cnf, base_metadata,
            [](auto& value) { value.solver_options += ";seed=8"; },
            [](auto&) {});
        const std::string other_cnf = "p cnf 1 2\n-1 0\n1 0\n";
        auto other_metadata = metadata(other_cnf);
        require(base_key != q3a::cache::proof_cache_key(
                    base_identity, other_cnf, other_metadata),
                "exact CNF bytes did not affect cache key");

        const auto artifact = make_artifact(cnf, base_metadata);
        std::ofstream(cnf_path, std::ios::binary) << cnf;
        std::ofstream(proof_path, std::ios::binary) << artifact;
        const auto saved = q3a::cache::store_checked_proof(
            cache_root, base_identity, cnf_path, proof_path, base_metadata);
        require(saved.stored, "proof cache store failed: " + saved.message);
        const auto hit = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, cnf_path, base_metadata, {}, hit_path);
        std::ifstream hit_proof(hit_path, std::ios::binary);
        const std::string hit_bytes((std::istreambuf_iterator<char>(hit_proof)), {});
        hit_proof.close();
        require(hit.state == q3a::cache::LookupState::Hit &&
                hit_bytes == artifact && hit.proof_records == 1 &&
                hit.artifact_sha256 == q3a::sha256_hex(artifact),
                "exact cache lookup did not return checked proof");
        {
            const auto occupied_output = q3a::cache::lookup_checked_proof(
                cache_root, base_identity, cnf_path, base_metadata, {}, hit_path);
            std::ifstream existing(hit_path, std::ios::binary);
            require(occupied_output.state == q3a::cache::LookupState::Rejected &&
                    q3a::sha256_stream(existing) == q3a::sha256_hex(artifact),
                    "cache lookup replaced an existing destination");
        }
        std::filesystem::remove(hit_path);
        q3a::checker::CheckerLimits no_memory;
        no_memory.check_memory = [](std::uint64_t) { throw std::runtime_error("test memory stop"); };
        const auto limited = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, cnf_path, base_metadata, no_memory, hit_path);
        require(limited.state == q3a::cache::LookupState::ResourceLimited &&
                !std::filesystem::exists(hit_path), "memory-limited lookup returned proof evidence");
        require(q3a::cache::lookup_checked_proof(cache_root, base_identity, cnf_path, base_metadata)
                    .state == q3a::cache::LookupState::Hit,
                "memory-limited lookup invalidated the existing checked cache entry");

        auto changed_profile = base_identity;
        changed_profile.profile_id += "-new";
        const auto invalidated = q3a::cache::lookup_checked_proof(
            cache_root, changed_profile, cnf_path, base_metadata);
        require(invalidated.state == q3a::cache::LookupState::Miss,
                "different profile identity must be a cache miss");

        {
            std::ofstream tamper(cache_root / base_key / "proof.q3adrat",
                                 std::ios::binary | std::ios::app);
            tamper << "tamper\n";
        }
        const auto rejected = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, cnf_path, base_metadata);
        require(rejected.state == q3a::cache::LookupState::Rejected,
                "tampered cache entry must be rejected");
        const auto refreshed = q3a::cache::store_checked_proof(
            cache_root, base_identity, cnf_path, proof_path, base_metadata);
        require(refreshed.stored, "rejected cache entry could not be replaced: " +
                                  refreshed.message);
        const auto checked_again = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, cnf_path, base_metadata);
        require(checked_again.state == q3a::cache::LookupState::Hit,
                "repaired cache entry did not pass current checker");

        // Each fixture independently exceeds the one-MiB checker allocation cap.
        constexpr int kLargeFixtureCommentLines = 4000;
        const auto large_cnf_path = cache_root / "large-query.cnf";
        {
            std::ofstream output(large_cnf_path, std::ios::binary);
            const std::string comment = "c " + std::string(1000, 'x') + '\n';
            for (int line = 0; line < kLargeFixtureCommentLines; ++line) output << comment;
            output << cnf;
        }
        auto large_metadata = base_metadata;
        {
            std::ifstream input(large_cnf_path, std::ios::binary);
            large_metadata.query_sha256 = q3a::sha256_stream(input);
        }
        {
            const auto large_artifact = make_artifact(cnf, large_metadata);
            const std::string marker = "proof_begin\n";
            const auto marker_position = large_artifact.find(marker);
            require(marker_position != std::string::npos, "missing proof body marker");
            const auto body_start = marker_position + marker.size();
            std::ofstream output(proof_path, std::ios::binary);
            output << large_artifact.substr(0, body_start);
            const std::string comment = "c " + std::string(1000, 'x') + '\n';
            for (int line = 0; line < kLargeFixtureCommentLines; ++line) output << comment;
            output << large_artifact.substr(body_start);
        }
        q3a::checker::CheckerLimits small_memory_request;
        small_memory_request.check_memory = [](std::uint64_t pending) {
            if (pending > 1024 * 1024) throw std::runtime_error("whole-file allocation requested");
        };
        const auto large_store = q3a::cache::store_checked_proof(
            cache_root, base_identity, large_cnf_path, proof_path, large_metadata,
            small_memory_request);
        require(large_store.stored, "streamed large CNF store failed: " + large_store.message);
        const auto large_hit = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, large_cnf_path, large_metadata, small_memory_request, hit_path);
        require(large_hit.state == q3a::cache::LookupState::Hit &&
                std::filesystem::exists(hit_path),
                "streamed large CNF lookup failed: " + large_hit.message);
        std::ifstream large_hit_proof(hit_path, std::ios::binary);
        std::ifstream large_source_proof(proof_path, std::ios::binary);
        require(q3a::sha256_stream(large_hit_proof) == q3a::sha256_stream(large_source_proof),
                "streamed cache hit changed the checked certificate bytes");
        const auto wrong_query = q3a::cache::lookup_checked_proof(
            cache_root, base_identity, cnf_path, large_metadata);
        require(wrong_query.state == q3a::cache::LookupState::Rejected,
                "cache hit accepted different live CNF bytes");

        std::cout << "Q3A_PROOF_CACHE_KEYS_PASS identity_variants=13 exact_cnf_change=1\n"
                  << "Q3A_PROOF_CACHE_CHECKER_PASS stored=1 hit=1 tamper_rejected=1 refreshed=1\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PROOF_CACHE_TEST_ERROR " << error.what() << '\n';
        return 1;
    }
}
