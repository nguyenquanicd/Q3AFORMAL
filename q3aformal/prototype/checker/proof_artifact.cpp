#include "proof_artifact.hpp"
#include "checker_input.hpp"

#include <array>
#include <charconv>
#include <cctype>
#include <cstdint>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>

namespace q3a::checker {
namespace {

bool valid_digest(const std::string& text) {
    if (text.size() != 64) return false;
    for (const auto ch : text) {
        if (!std::isxdigit(static_cast<unsigned char>(ch))) return false;
    }
    return true;
}

bool valid_query_kind(const std::string& text) {
    if (text.empty() || text.size() > 64 ||
        !std::islower(static_cast<unsigned char>(text.front()))) return false;
    for (const auto ch : text) {
        if (!(std::islower(static_cast<unsigned char>(ch)) ||
              std::isdigit(static_cast<unsigned char>(ch)) || ch == '-')) return false;
    }
    return true;
}

bool valid_checker_id(const std::string& text) {
    if (text.empty() || text.size() > 64 ||
        !std::islower(static_cast<unsigned char>(text.front()))) return false;
    for (const auto ch : text) {
        if (!(std::islower(static_cast<unsigned char>(ch)) ||
              std::isdigit(static_cast<unsigned char>(ch)) ||
              ch == '-' || ch == '.')) return false;
    }
    return true;
}

void validate_metadata(const ArtifactMetadata& metadata) {
    if (!valid_query_kind(metadata.query_kind)) {
        throw std::runtime_error("invalid proof query kind");
    }
    if (!valid_checker_id(metadata.checker_id)) {
        throw std::runtime_error("invalid proof checker identity");
    }
    if (!valid_digest(metadata.model_sha256)) {
        throw std::runtime_error("model_sha256 must contain 64 hexadecimal digits");
    }
    if (!valid_digest(metadata.query_sha256)) {
        throw std::runtime_error("query_sha256 must contain 64 hexadecimal digits");
    }
}

std::uint64_t parse_record_count(const std::string& text) {
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    if (text.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != text.data() + text.size()) {
        throw std::runtime_error("malformed proof_records count");
    }
    return value;
}

template <typename WriteRecords>
CheckResult write_artifact(std::uint64_t record_count, const ArtifactMetadata& metadata,
                           std::ostream& output, WriteRecords write_records) {
    try {
        validate_metadata(metadata);
        output << "Q3A_DRAT_ARTIFACT " << kProofArtifactSchema << '\n'
               << "query_kind " << metadata.query_kind << '\n'
               << "checker_id " << metadata.checker_id << '\n'
               << "model_sha256 " << metadata.model_sha256 << '\n'
               << "query_sha256 " << metadata.query_sha256 << '\n'
               << "proof_records " << record_count << '\n'
               << "proof_begin\n";
        write_records(output);
        output << "proof_end\n";
        if (!output) throw std::runtime_error("failed while writing proof artifact");
        return {true, record_count, "proof artifact written"};
    } catch (const std::exception& error) {
        return {false, 0, error.what()};
    }
}

} // namespace

CheckResult write_drat_artifact(
    const ProofResult& proof, const ArtifactMetadata& metadata, std::ostream& output) {
    if (proof.status != ProofStatus::Unsatisfiable || proof.additions.empty() ||
        !proof.additions.back().empty()) {
        return {false, 0, "artifact requires a complete UNSAT refutation"};
    }
    return write_artifact(proof.additions.size(), metadata, output,
        [&](std::ostream& body) { write_rup_proof(proof, body); });
}

CheckResult write_drat_artifact(
    std::istream& records, std::uint64_t record_count,
    const ArtifactMetadata& metadata, std::ostream& output) {
    if (record_count == 0) return {false, 0, "artifact requires at least one proof record"};
    return write_artifact(record_count, metadata, output, [&](std::ostream& body) {
        std::array<char, 64 * 1024> buffer;
        do {
            records.read(buffer.data(), buffer.size());
            body.write(buffer.data(), records.gcount());
            if (!body) throw std::runtime_error("failed while writing staged proof records");
        } while (records);
        if (records.bad() || !records.eof()) {
            throw std::runtime_error("failed while reading staged proof records");
        }
    });
}

CheckResult verify_drat_artifact(
    std::istream& cnf_input,
    std::istream& artifact_input,
    const ArtifactMetadata& expected_metadata,
    const CheckerLimits& limits) {
    try {
        validate_metadata(expected_metadata);
        std::string line;
        const auto read_normalized_line = [&](std::string& target) {
            if (!detail::read_bounded_line(artifact_input, target, limits, "proof artifact")) {
                return false;
            }
            if (!target.empty() && target.back() == '\r') target.pop_back();
            return true;
        };
        const auto expected_schema = std::string("Q3A_DRAT_ARTIFACT ") +
            std::to_string(kProofArtifactSchema);
        if (!read_normalized_line(line) || line != expected_schema) {
            throw std::runtime_error("unsupported or missing Q3A DRAT artifact schema");
        }
        ArtifactMetadata actual_metadata;
        const auto read_field = [&](const std::string& expected_name) {
            std::string field_line;
            if (!read_normalized_line(field_line)) {
                throw std::runtime_error("truncated proof artifact metadata");
            }
            detail::check_memory(limits, field_line.size());
            std::istringstream parser(field_line);
            std::string name;
            std::string value;
            std::string extra;
            if (!(parser >> name >> value) || (parser >> extra) || name != expected_name) {
                throw std::runtime_error("expected proof artifact field '" + expected_name + "'");
            }
            return value;
        };
        actual_metadata.query_kind = read_field("query_kind");
        actual_metadata.checker_id = read_field("checker_id");
        actual_metadata.model_sha256 = read_field("model_sha256");
        actual_metadata.query_sha256 = read_field("query_sha256");
        const auto declared_records = parse_record_count(read_field("proof_records"));
        if (declared_records > limits.maximum_proof_records) {
            return {false, 0, "DRAT checker proof record limit exceeded", true};
        }
        validate_metadata(actual_metadata);
        if (actual_metadata.query_kind != expected_metadata.query_kind) {
            throw std::runtime_error("proof query kind does not match the expected obligation");
        }
        if (actual_metadata.checker_id != expected_metadata.checker_id) {
            throw std::runtime_error("proof checker identity does not match the expected checker");
        }
        if (actual_metadata.model_sha256 != expected_metadata.model_sha256) {
            throw std::runtime_error("proof model hash does not match the expected model");
        }
        if (actual_metadata.query_sha256 != expected_metadata.query_sha256) {
            throw std::runtime_error("proof query hash does not match the exact CNF query");
        }

        if (!read_normalized_line(line) || line != "proof_begin") {
            throw std::runtime_error("proof artifact is missing proof_begin");
        }
        const auto next_proof_line = [&](std::string& record_line) {
            if (!read_normalized_line(record_line)) {
                throw std::runtime_error("proof artifact is missing proof_end");
            }
            if (record_line != "proof_end") return true;
            while (read_normalized_line(record_line)) {
                if (!record_line.empty()) throw std::runtime_error("unexpected data after proof_end");
            }
            if (artifact_input.bad() || !artifact_input.eof()) {
                throw std::runtime_error("failed while reading proof artifact trailer");
            }
            return false;
        };
        const auto proof_result = verify_drat_records(
            cnf_input, next_proof_line, limits, declared_records);
        if (!proof_result.accepted) {
            const auto prefix = proof_result.resource_limited
                ? "DRAT checker resource limit: "
                : "DRAT proof rejected: ";
            return {false, proof_result.proof_records,
                    prefix + proof_result.message,
                    proof_result.resource_limited};
        }
        return {true, proof_result.proof_records,
                "proof artifact identity and DRAT proof accepted"};
    } catch (const detail::ResourceLimitError& error) {
        return {false, 0, error.what(), true};
    } catch (const std::bad_alloc&) {
        return {false, 0, "proof artifact memory allocation failed", true};
    } catch (const std::exception& error) {
        return {false, 0, error.what()};
    }
}

} // namespace q3a::checker
