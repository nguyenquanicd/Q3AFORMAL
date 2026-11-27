#include "proof_cache.hpp"

#include "../bundle/windows_file_path.hpp"
#include "../source_manager/platform_support.hpp"
#include "../source_manager/write_locked_input.hpp"

#include <atomic>
#include <chrono>
#include <fstream>
#include <iterator>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <utility>
#include <vector>

namespace q3a::cache {
namespace {

constexpr const char* kCacheSchema = "Q3A-PROOF-CACHE 1";
constexpr std::uint64_t kMaximumCacheFileBytes = 512ULL * 1024ULL * 1024ULL;
std::atomic<std::uint64_t> gTemporarySequence{0};

std::filesystem::path cache_file_path(const std::filesystem::path& path) {
    return bundle::detail::absolute_windows_file_path(path);
}

std::string digest(const std::string& content) {
    return q3a::sha256_hex(content);
}

class CacheMemoryStop final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

void check_memory(const checker::CheckerLimits& limits, std::uint64_t pending) {
    if (!limits.check_memory) return;
    try {
        limits.check_memory(pending);
    } catch (const std::exception& error) {
        throw CacheMemoryStop(error.what());
    }
}

void append_field(std::string& output,
                  const std::string& name,
                  const std::string& value) {
    output += std::to_string(name.size());
    output += ':';
    output += name;
    output += std::to_string(value.size());
    output += ':';
    output += value;
    output += '\n';
}

std::string identity_bytes(const ProofIdentity& identity,
                           const checker::ArtifactMetadata& metadata) {
    std::string result = "Q3A_PROOF_CACHE_IDENTITY 2\n";
    append_field(result, "profile_id", identity.profile_id);
    append_field(result, "input_sha256", identity.input_sha256);
    append_field(result, "manifest_sha256", identity.manifest_sha256);
    append_field(result, "model_sha256", identity.model_sha256);
    append_field(result, "model_schema", identity.model_schema);
    append_field(result, "query_sha256", metadata.query_sha256);
    append_field(result, "build_id", identity.build_id);
    append_field(result, "checker_id", metadata.checker_id);
    append_field(result, "checker_fingerprint", identity.checker_fingerprint);
    append_field(result, "checker_schema", std::to_string(checker::kProofArtifactSchema));
    append_field(result, "query_kind", metadata.query_kind);
    append_field(result, "algorithm", identity.algorithm);
    append_field(result, "property", identity.property);
    append_field(result, "obligation", identity.obligation);
    append_field(result, "depth", std::to_string(identity.depth));
    append_field(result, "solver_options", identity.solver_options);
    return result;
}

std::string key_for(const std::string& identity, const std::string& query_hash) {
    std::string key_material = "Q3A_PROOF_CACHE_KEY 1\n";
    append_field(key_material, "identity_sha256", digest(identity));
    append_field(key_material, "query_sha256", query_hash);
    return digest(key_material);
}

std::string read_file(const std::filesystem::path& path,
                      std::uint64_t maximum_bytes,
                      const checker::CheckerLimits& limits = {}) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open cache file " + path.u8string());
    input.seekg(0, std::ios::end);
    const auto end = input.tellg();
    if (end < 0 || static_cast<std::uint64_t>(end) > maximum_bytes ||
        static_cast<std::uint64_t>(end) >
            static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
        throw std::runtime_error("cache file exceeds the supported size limit");
    }
    check_memory(limits, static_cast<std::uint64_t>(end));
    std::string content(static_cast<std::size_t>(end), '\0');
    input.seekg(0, std::ios::beg);
    if (!content.empty()) {
        input.read(&content[0], static_cast<std::streamsize>(content.size()));
        if (!input) throw std::runtime_error("cannot read cache file " + path.u8string());
    }
    return content;
}

void write_file(const std::filesystem::path& path,
                const std::string& content) {
    std::ofstream output(path, std::ios::binary | std::ios::out | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot create cache file " + path.u8string());
    output.write(content.data(), static_cast<std::streamsize>(content.size()));
    if (!output) throw std::runtime_error("cannot write cache file " + path.u8string());
}

struct Manifest {
    std::string key;
    std::string identity_sha256;
    std::string query_sha256;
    std::string artifact_sha256;
    std::uint64_t proof_records = 0;
};

std::uint64_t parse_count(const std::string& text) {
    std::uint64_t value = 0;
    std::istringstream parser(text);
    parser >> value;
    if (!parser || !parser.eof()) {
        throw std::runtime_error("malformed proof-cache record count");
    }
    return value;
}

Manifest parse_manifest(const std::string& content) {
    std::istringstream parser(content);
    std::string line;
    if (!std::getline(parser, line) || line != kCacheSchema) {
        throw std::runtime_error("unsupported proof-cache schema");
    }
    const auto field = [&](const char* expected) {
        std::string value_line;
        if (!std::getline(parser, value_line)) {
            throw std::runtime_error("truncated proof-cache manifest");
        }
        std::istringstream value_parser(value_line);
        std::string name;
        std::string value;
        std::string extra;
        if (!(value_parser >> name >> value) || (value_parser >> extra) || name != expected) {
            throw std::runtime_error(std::string("invalid proof-cache field '") + expected + "'");
        }
        return value;
    };
    Manifest result;
    result.key = field("key");
    result.identity_sha256 = field("identity_sha256");
    result.query_sha256 = field("query_sha256");
    result.artifact_sha256 = field("artifact_sha256");
    result.proof_records = parse_count(field("proof_records"));
    if (std::getline(parser, line)) {
        throw std::runtime_error("unexpected data after proof-cache manifest");
    }
    return result;
}

std::string hash_cache_file(q3a::WriteLockedInput& input,
                            const std::filesystem::path& path,
                            const checker::CheckerLimits& limits) {
    check_memory(limits, 0);
    const auto size = std::filesystem::file_size(path);
    if (size > kMaximumCacheFileBytes) {
        throw std::runtime_error("cache file exceeds the supported size limit");
    }
    const auto hash = q3a::sha256_stream(input.stream(), size);
    input.rewind();
    return hash;
}

std::string manifest_text(const std::string& key,
                          const std::string& identity,
                          const std::string& query_hash,
                          const std::string& artifact_hash,
                          std::uint64_t proof_records) {
    std::ostringstream output;
    output << kCacheSchema << '\n'
           << "key " << key << '\n'
           << "identity_sha256 " << digest(identity) << '\n'
           << "query_sha256 " << query_hash << '\n'
           << "artifact_sha256 " << artifact_hash << '\n'
           << "proof_records " << proof_records << '\n';
    return output.str();
}

std::string temporary_suffix() {
    const auto ticks = std::chrono::high_resolution_clock::now()
        .time_since_epoch().count();
    return std::to_string(ticks) + "-" +
        std::to_string(gTemporarySequence.fetch_add(1));
}

void publish_checked_proof(const std::filesystem::path& saved_proof,
                           const std::filesystem::path& destination,
                           const std::string& expected_digest,
                           const checker::CheckerLimits& limits) {
    const auto output = cache_file_path(destination);
    const auto staging = output.parent_path() / (".q3a-cache-copy-" + temporary_suffix());
    if (!std::filesystem::create_directory(staging)) {
        throw std::runtime_error("cannot create checked proof copy staging directory");
    }
    const auto copy = staging / "proof.q3adrat";
    try {
        std::filesystem::copy_file(saved_proof, copy);
        {
            q3a::WriteLockedInput copied_proof(copy);
            if (hash_cache_file(copied_proof, copy, limits) != expected_digest) {
                throw std::runtime_error("checked proof copy is incomplete or differs from the cache entry");
            }
        }
        if (const auto error = q3a::publish_no_replace(copy, output)) {
            throw std::system_error(error, "cannot publish checked proof copy");
        }
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove(copy, ignored);
        std::filesystem::remove(staging, ignored);
        throw;
    }
    std::error_code ignored;
    std::filesystem::remove(staging, ignored);
}

} // namespace

std::string proof_cache_key(
    const ProofIdentity& identity,
    const std::string& cnf,
    const checker::ArtifactMetadata& metadata) {
    if (metadata.model_sha256 != identity.model_sha256 ||
        metadata.query_sha256 != digest(cnf)) {
        throw std::invalid_argument("proof-cache checker metadata does not match model/CNF identity");
    }
    return key_for(identity_bytes(identity, metadata), metadata.query_sha256);
}

LookupResult lookup_checked_proof(
    const std::filesystem::path& cache_directory,
    const ProofIdentity& identity,
    const std::filesystem::path& cnf_path,
    const checker::ArtifactMetadata& metadata,
    const checker::CheckerLimits& limits,
    const std::filesystem::path& checked_proof_output) {
    LookupResult result;
    try {
        const auto canonical_identity = identity_bytes(identity, metadata);
        result.key = key_for(canonical_identity, metadata.query_sha256);
        if (metadata.model_sha256 != identity.model_sha256) {
            throw std::invalid_argument("proof-cache checker metadata does not match model/CNF identity");
        }
        const auto entry = cache_file_path(cache_directory) / result.key;
        std::error_code error;
        const bool exists = std::filesystem::exists(entry, error);
        if (error) throw std::runtime_error("cannot inspect proof-cache entry");
        if (!exists) {
            result.state = LookupState::Miss;
            result.message = "no entry for this exact identity";
            return result;
        }
        if (!std::filesystem::is_directory(entry, error) || error) {
            throw std::runtime_error("proof-cache entry is not a directory");
        }

        const auto manifest = parse_manifest(read_file(entry / "manifest.txt", 4096));
        const auto saved_identity = read_file(entry / "identity.bin", 1024 * 1024);
        const auto saved_cnf_path = entry / "query.cnf";
        const auto saved_proof_path = entry / "proof.q3adrat";
        const auto current_cnf_path = cache_file_path(cnf_path);
        q3a::WriteLockedInput current_cnf(current_cnf_path);
        q3a::WriteLockedInput saved_cnf(saved_cnf_path);
        q3a::WriteLockedInput saved_proof(saved_proof_path);
        if (manifest.key != result.key || saved_identity != canonical_identity ||
            manifest.identity_sha256 != digest(saved_identity) ||
            manifest.query_sha256 != metadata.query_sha256 ||
            hash_cache_file(current_cnf, current_cnf_path, limits) != metadata.query_sha256 ||
            hash_cache_file(saved_cnf, saved_cnf_path, limits) != metadata.query_sha256 ||
            hash_cache_file(saved_proof, saved_proof_path, limits) != manifest.artifact_sha256) {
            throw std::runtime_error("proof-cache identity or artifact digest mismatch");
        }
        const auto checked = checker::verify_drat_artifact(
            saved_cnf.stream(), saved_proof.stream(), metadata, limits);
        if (checked.resource_limited) {
            result.state = LookupState::ResourceLimited;
            result.message = checked.message;
            return result;
        }
        if (!checked.accepted || checked.proof_records != manifest.proof_records) {
            throw std::runtime_error("cached DRAT proof was rejected: " + checked.message);
        }
        if (!checked_proof_output.empty()) {
            publish_checked_proof(saved_proof_path, checked_proof_output, manifest.artifact_sha256, limits);
        }
        result.state = LookupState::Hit;
        result.proof_records = checked.proof_records;
        result.message = "exact identity matched and current DRAT checker accepted the proof";
        result.artifact_sha256 = manifest.artifact_sha256;
    } catch (const CacheMemoryStop& error) {
        result.state = LookupState::ResourceLimited;
        result.message = error.what();
    } catch (const std::bad_alloc&) {
        result.state = LookupState::ResourceLimited;
        result.message = "proof-cache memory allocation failed";
    } catch (const std::exception& error) {
        result.state = LookupState::Rejected;
        result.message = error.what();
    }
    return result;
}

StoreResult store_checked_proof(
    const std::filesystem::path& cache_directory,
    const ProofIdentity& identity,
    const std::filesystem::path& cnf_path,
    const std::filesystem::path& artifact_path,
    const checker::ArtifactMetadata& metadata,
    const checker::CheckerLimits& limits) {
    try {
        if (metadata.model_sha256 != identity.model_sha256) {
            return {false, "proof-cache checker metadata does not match model identity"};
        }
        const auto canonical_identity = identity_bytes(identity, metadata);
        const auto key = key_for(canonical_identity, metadata.query_sha256);
        const auto root = cache_file_path(cache_directory);
        std::error_code error;
        std::filesystem::create_directories(root, error);
        if (error) throw std::runtime_error("cannot create proof-cache root: " + error.message());

        const auto target = root / key;

        std::filesystem::path temporary;
        bool created = false;
        for (unsigned attempt = 0; attempt < 8 && !created; ++attempt) {
            temporary = root / ("tmp-" + temporary_suffix());
            created = std::filesystem::create_directory(temporary, error);
            if (error && error != std::errc::file_exists) {
                throw std::runtime_error("cannot create temporary proof-cache entry: " +
                                         error.message() + " (" + temporary.u8string() + ")");
            }
            error.clear();
        }
        if (!created) throw std::runtime_error(
            "cannot allocate temporary proof-cache entry under " + cache_directory.u8string());

        try {
            const auto staged_cnf = temporary / "query.cnf";
            const auto staged_proof = temporary / "proof.q3adrat";
            std::filesystem::copy_file(cache_file_path(cnf_path), staged_cnf);
            std::filesystem::copy_file(cache_file_path(artifact_path), staged_proof);
            std::string artifact_hash;
            std::uint64_t proof_records = 0;
            {
                q3a::WriteLockedInput cnf(staged_cnf);
                q3a::WriteLockedInput proof(staged_proof);
                if (hash_cache_file(cnf, staged_cnf, limits) != metadata.query_sha256) {
                    throw std::runtime_error("proof-cache checker metadata does not match CNF identity");
                }
                artifact_hash = hash_cache_file(proof, staged_proof, limits);
                const auto checked = checker::verify_drat_artifact(
                    cnf.stream(), proof.stream(), metadata, limits);
                if (!checked.accepted) {
                    throw std::runtime_error("refusing to cache a proof not accepted by the current checker: " +
                                             checked.message);
                }
                proof_records = checked.proof_records;
            }
            write_file(temporary / "identity.bin", canonical_identity);
            write_file(temporary / "manifest.txt", manifest_text(
                key, canonical_identity, metadata.query_sha256, artifact_hash, proof_records));
            const auto existing = lookup_checked_proof(
                cache_directory, identity, cnf_path, metadata, limits);
            if (existing.state == LookupState::Hit) {
                std::filesystem::remove_all(temporary, error);
                return {true, "valid entry already exists"};
            }
            if (existing.state == LookupState::ResourceLimited) {
                throw std::runtime_error("could not recheck the existing cache entry: " + existing.message);
            }
            if (existing.state == LookupState::Rejected) {
                const auto stale = root / (key + ".invalid-" + temporary_suffix());
                std::filesystem::rename(target, stale);
            }
            std::filesystem::rename(temporary, target, error);
            if (error) {
                const auto concurrent = lookup_checked_proof(
                    cache_directory, identity, cnf_path, metadata, limits);
                if (concurrent.state != LookupState::Hit) {
                    throw std::runtime_error("cannot publish proof-cache entry: " +
                                             error.message());
                }
                std::filesystem::remove_all(temporary, error);
                return {true, "concurrent writer published the same checked proof"};
            }
        } catch (...) {
            std::error_code cleanup_error;
            std::filesystem::remove_all(temporary, cleanup_error);
            throw;
        }
        return {true, "checked proof stored atomically"};
    } catch (const std::exception& error) {
        return {false, error.what()};
    }
}

} // namespace q3a::cache
