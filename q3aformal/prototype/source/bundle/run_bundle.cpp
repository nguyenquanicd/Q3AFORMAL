#include "run_bundle.hpp"
#include "windows_file_path.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace q3a::bundle {
namespace {

constexpr const char* kBundleSchema = "Q3A-RUN-BUNDLE-1";
constexpr const char* kSummarySchema = "Q3A-RUN-SUMMARY-1";
constexpr const char* kTraceSchema = "Q3A-TRACE-JSON-1";

struct FileRecord {
    std::string path;
    std::string role;
    std::uintmax_t size_bytes = 0;
    std::string sha256;
};
} // namespace

std::string json_string(const std::string& value) {
    std::ostringstream output;
    output << '"';
    for (const auto byte : value) {
        const auto character = static_cast<unsigned char>(byte);
        switch (character) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (character < 0x20) {
                output << "\\u00" << std::hex << std::setw(2)
                       << std::setfill('0') << static_cast<unsigned int>(character)
                       << std::dec << std::setfill(' ');
            } else {
                output << byte;
            }
        }
    }
    output << '"';
    return output.str();
}

namespace {

std::string digest_file(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open file for bundle fingerprint: " + path.u8string());
    }
    return q3a::sha256_stream(input);
}

std::string normalize_bundle_path(const std::string& path) {
    if (path.empty() || path.find('\\') != std::string::npos) {
        throw std::invalid_argument("bundle artifact paths must be non-empty and use '/' separators");
    }
    const auto parsed = std::filesystem::u8path(path);
    if (parsed.is_absolute() || parsed.has_root_name() || parsed.has_root_directory()) {
        throw std::invalid_argument("bundle artifact path must be relative");
    }
    for (const auto& component : parsed) {
        if (component == ".." || component == ".") {
            throw std::invalid_argument("bundle artifact path may not contain '.' or '..'");
        }
    }
    const auto normalized = parsed.lexically_normal().generic_u8string();
    if (normalized != path) {
        throw std::invalid_argument("bundle artifact path is not normalized: " + path);
    }
    return normalized;
}

std::string safe_property_component(const std::string& property) {
    if (property.empty() || !std::all_of(property.begin(), property.end(),
        [](unsigned char character) {
            return std::isalnum(character) || character == '_' ||
                character == '-' || character == '.' || character == '$' ||
                character == '[' || character == ']';
        })) {
        throw std::invalid_argument("property name is not safe as a bundle path component");
    }
    if (property == "." || property == "..") {
        throw std::invalid_argument("property name is not safe as a bundle path component");
    }
    return property;
}

std::string unique_artifact_path(const std::vector<FileRecord>& files,
                                 const std::string& path) {
    const auto normalized = normalize_bundle_path(path);
    const auto duplicate = std::find_if(files.begin(), files.end(),
        [&](const FileRecord& file) { return file.path == normalized; });
    if (duplicate != files.end()) {
        throw std::invalid_argument("duplicate bundle artifact path: " + normalized);
    }
    return normalized;
}

std::string record_json(const FileRecord& record) {
    return "{\"path\":" + json_string(record.path) +
        ",\"role\":" + json_string(record.role) +
        ",\"size_bytes\":" + std::to_string(record.size_bytes) +
        ",\"sha256\":" + json_string(record.sha256) + "}";
}

std::string serialize_manifest(
    const ProjectInput& project,
    const RunBundleRequest& request,
    const std::string& run_id,
    const std::string& manifest_sha256,
    const std::string& model_sha256,
    const std::string& executable_sha256,
    const std::vector<std::string>& query_hashes,
    const std::vector<FileRecord>& files) {
    std::ostringstream output;
    output << "{\n  \"schema_version\": " << json_string(kBundleSchema)
           << ",\n  \"run_id\": " << json_string(run_id)
           << ",\n  \"command\": " << json_string(request.command)
           << ",\n  \"profile\": {\"id\": " << json_string(project.profile_id)
           << ", \"source_set_sha256\": " << json_string(project.input_hash) << "}"
           << ",\n  \"project\": {\"top_module\": " << json_string(project.top_module)
           << ", \"manifest_schema\": "
           << json_string("Q3AFORMAL_PROJECT_" + std::to_string(project.manifest_version))
           << ", \"manifest_path\": \"source-snapshot/project.q3a\""
           << ", \"manifest_sha256\": " << json_string(manifest_sha256)
           << ", \"parameters\": {";
    bool first = true;
    for (const auto& parameter : project.parameters) {
        if (!first) output << ',';
        first = false;
        output << json_string(parameter.first) << ':' << json_string(parameter.second);
    }
    output << '}';
    if (!project.macros.empty()) {
        output << ", \"macros\": {";
        bool first_macro = true;
        for (const auto& macro : project.macros) {
            if (!first_macro) output << ',';
            first_macro = false;
            output << json_string(macro.first) << ':' << json_string(macro.second);
        }
        output << '}';
    }
    if (!project.include_dirs.empty()) {
        output << ", \"include_dirs\": [";
        for (std::size_t index = 0; index < project.include_dirs.size(); ++index) {
            if (index) output << ',';
            output << json_string(project.include_dirs[index]);
        }
        output << ']';
    }
    const auto write_roster = [&](const char* field, const std::vector<SourceFile>& files) {
        output << ", \"" << field << "\": [";
        for (std::size_t index = 0; index < files.size(); ++index) {
            if (index) output << ',';
            const auto& source = files[index];
            output << "{\"path\":" << json_string(source.relative_path)
                   << ",\"snapshot_path\":"
                   << json_string("source-snapshot/rtl/" + source.relative_path)
                   << ",\"size_bytes\":" << source.contents.size()
                   << ",\"sha256\":" << json_string(source.sha256) << '}';
        }
        output << ']';
    };
    write_roster("sources", project.sources);
    if (!project.headers.empty()) write_roster("headers", project.headers);
    output << '}'
           << ",\n  \"model\": {\"path\": \"model/model.json\""
           << ", \"schema_version\": " << json_string(request.model_schema)
           << ", \"size_bytes\":" << request.model_json.size()
           << ", \"sha256\":" << json_string(model_sha256) << '}'
           << ",\n  \"result\": {\"status\": " << json_string(request.status)
           << ", \"property\": " << json_string(request.property)
           << ", \"algorithm\": " << json_string(request.algorithm)
           << ", \"detail\": " << json_string(request.detail)
           << ", \"bound\":" << request.bound
           << ", \"vacuity\":" << json_string(request.vacuity)
           << ", \"boundary_obligations\":"
           << json_string(request.boundary_obligations)
           << ", \"duration_ms\":" << request.duration_ms << '}'
           << ",\n  \"assumptions\": [";
    for (std::size_t index = 0; index < request.assumptions.size(); ++index) {
        if (index) output << ',';
        output << json_string(request.assumptions[index]);
    }
    output << "]"
           << ",\n  \"sampling_context\": {\"clock\": " << json_string(request.sampling_clock)
           << ", \"edge\": \"posedge\"}"
           << ",\n  \"reset_initial_policy\": " << json_string(kResetInitialPolicy)
           << ",\n  \"schemas\": {\"bundle\":" << json_string(kBundleSchema)
           << ",\"model\":" << json_string(request.model_schema)
           << ",\"query\":\"DIMACS-CNF-1\",\"trace\":"
           << json_string(kTraceSchema) << "}"
           << ",\n  \"build\": {\"id\":" << json_string(request.build_id)
           << ",\"compiler\":" << json_string(request.compiler)
           << ",\"executable_sha256\":" << json_string(executable_sha256) << '}'
           << ",\n  \"components\": [";
    for (std::size_t index = 0; index < request.components.size(); ++index) {
        if (index) output << ',';
        const auto& component = request.components[index];
        output << "{\"id\":" << json_string(component.id)
               << ",\"source_sha256\":"
               << json_string(component.source_sha256) << '}';
    }
    output << "]"
           << ",\n  \"checker\": {\"id\":" << json_string(request.checker_id)
           << ",\"fingerprint_sha256\":"
           << json_string(request.checker_fingerprint)
           << ",\"proof_artifact_schema\":"
           << json_string(request.checker_artifact_schema) << '}'
           << ",\n  \"resource_limits\": {\"decisions\":"
           << request.decision_limit << ",\"propagations\":"
           << request.propagation_limit
           << ",\"zero_means_unlimited\":true}"
           << ",\n  \"queries\": [";
    for (std::size_t index = 0; index < request.queries.size(); ++index) {
        if (index) output << ',';
        const auto& query = request.queries[index];
        output << "{\"id\":" << json_string(query.id)
               << ",\"kind\":" << json_string(query.kind)
               << ",\"algorithm\":" << json_string(query.algorithm)
               << ",\"property\":" << json_string(query.property)
               << ",\"bound\":" << query.bound
               << ",\"status\":" << json_string(query.status)
               << ",\"cnf_path\":" << json_string(query.cnf_path)
               << ",\"cnf_sha256\":" << json_string(query_hashes[index]) << '}';
    }
    output << "]"
           << ",\n  \"artifacts\": [";
    for (std::size_t index = 0; index < files.size(); ++index) {
        if (index) output << ',';
        output << record_json(files[index]);
    }
    output << "]\n}\n";
    return output.str();
}

template <typename Write>
std::filesystem::path write_file(const std::filesystem::path& root,
                                 const std::string& path, Write write) {
    auto native_path = path;
    std::replace(native_path.begin(), native_path.end(), '/',
                 static_cast<char>(std::filesystem::path::preferred_separator));
    const auto destination = detail::windows_file_path(root / std::filesystem::u8path(native_path));
    std::error_code error;
    std::filesystem::create_directories(destination.parent_path(), error);
    if (error) throw std::runtime_error(
        "cannot create bundle artifact directory for " + path +
        " (root=" + root.u8string() + ", parent=" +
        destination.parent_path().u8string() + "): " + error.message());
    std::ofstream output(destination, std::ios::binary | std::ios::out | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot create bundle artifact: " + path);
    write(output);
    output.close();
    if (!output) throw std::runtime_error("failed while writing bundle artifact: " + path);
    return destination;
}

class BundleStaging {
public:
    explicit BundleStaging(const std::filesystem::path& destination)
        : destination_(detail::windows_file_path(std::filesystem::absolute(destination))) {
        std::error_code error;
        if (std::filesystem::exists(detail::windows_file_path(destination_), error)) {
            throw std::runtime_error("bundle output already exists: " + destination_.u8string());
        }
        if (error) throw std::runtime_error("cannot inspect bundle output path");
        std::filesystem::create_directories(detail::windows_file_path(destination_.parent_path()), error);
        if (error) throw std::runtime_error("cannot create bundle output parent directory");
        const auto parent = detail::canonical_directory(destination_.parent_path(), error);
        if (error) throw std::runtime_error("cannot resolve bundle output parent directory: " +
                                            error.message());
        destination_ = parent / destination_.filename();
        static std::atomic<std::uint64_t> sequence{0};
        const auto nonce = std::chrono::high_resolution_clock::now().time_since_epoch().count();
        temporary_ = parent / (".q3ab-" + std::to_string(nonce) + "-" +
            std::to_string(sequence.fetch_add(1)));
        if (!std::filesystem::create_directory(detail::windows_file_path(temporary_), error) || error) {
            throw std::runtime_error("cannot create temporary bundle directory");
        }
    }

    ~BundleStaging() {
        if (!published_ && temporary_.parent_path() == destination_.parent_path() &&
            temporary_.filename() != destination_.filename()) {
            std::error_code ignored;
            const auto native = detail::windows_file_path(temporary_);
            const auto resolved = detail::canonical_directory(native, ignored);
            if (!ignored && detail::windows_file_path(resolved) == native) {
                std::filesystem::remove_all(native, ignored);
            }
        }
    }

    const std::filesystem::path& path() const noexcept { return temporary_; }

    void publish() {
        std::error_code error;
        std::filesystem::rename(detail::windows_file_path(temporary_),
                                detail::windows_file_path(destination_), error);
        if (error) throw std::runtime_error("cannot publish completed result bundle");
        published_ = true;
    }

private:
    std::filesystem::path destination_;
    std::filesystem::path temporary_;
    bool published_ = false;
};

} // namespace

void write_result_bundle(const ProjectInput& project,
                         const RunBundleRequest& request) {
    if (request.output_directory.empty() || request.command.empty() ||
        request.status.empty() || request.property.empty() ||
        request.model_schema.empty() || request.model_json.empty() ||
        request.project_manifest_content.empty() || request.queries.empty()) {
        throw std::invalid_argument("run bundle is missing required identity or evidence fields");
    }
    if (request.components.empty()) {
        throw std::invalid_argument("run bundle requires build component fingerprints");
    }
    if (request.output_directory.filename().empty()) {
        throw std::invalid_argument("bundle output directory must have a run-id name");
    }
    std::set<std::string> component_ids;
    for (const auto& component : request.components) {
        if (component.id.empty() || component.source_sha256.size() != 64 ||
            !std::all_of(component.source_sha256.begin(), component.source_sha256.end(),
                [](unsigned char character) { return std::isxdigit(character) != 0; }) ||
            !component_ids.insert(component.id).second) {
            throw std::invalid_argument("run bundle has an invalid or duplicate component fingerprint");
        }
    }
    const auto run_id = request.output_directory.filename().u8string();
    const auto manifest_hash = q3a::sha256_hex(request.project_manifest_content);
    if (manifest_hash != project.manifest_sha256) {
        throw std::runtime_error("project manifest changed after loading");
    }
    const auto model_hash = q3a::sha256_hex(request.model_json);
    const auto executable_hash = digest_file(request.executable_path);

    BundleStaging staging(request.output_directory);
    std::vector<FileRecord> files;
    const auto append_bytes = [&](const std::string& path, const std::string& role,
                                  std::string_view bytes, const std::string& hash) {
        const auto normalized = unique_artifact_path(files, path);
        write_file(staging.path(), normalized, [&](std::ostream& output) {
            if (!bytes.empty()) output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        });
        files.push_back({normalized, role, bytes.size(), hash});
    };
    const auto append_stream = [&](const std::string& path, const std::string& role,
                                   const std::function<void(std::ostream&)>& write) {
        const auto normalized = unique_artifact_path(files, path);
        const auto saved = write_file(staging.path(), normalized, write);
        files.push_back({normalized, role, std::filesystem::file_size(saved), digest_file(saved)});
    };
    append_bytes("source-snapshot/project.q3a", "project_manifest",
                 request.project_manifest_content, manifest_hash);
    std::set<std::string> archived_sources;
    const auto append_source = [&](const SourceFile& source) {
        const auto source_path = normalize_bundle_path(source.relative_path);
        if (q3a::sha256_hex(source.contents) != source.sha256) {
            throw std::invalid_argument("project source hash changed before bundle capture: " + source.relative_path);
        }
        const auto bytes = source.contents.empty() ? std::string_view{} : std::string_view(
            reinterpret_cast<const char*>(source.contents.data()), source.contents.size());
        if (archived_sources.insert(source_path).second) {
            append_bytes("source-snapshot/rtl/" + source_path, "rtl_source", bytes, source.sha256);
        }
    };
    for (const auto& source : project.sources) append_source(source);
    for (const auto& header : project.headers) append_source(header);
    append_bytes("model/model.json", "canonical_tir", request.model_json, model_hash);
    if (!request.run_configuration.empty()) {
        append_bytes(kRunConfigurationPath, "run_configuration", request.run_configuration,
            q3a::sha256_hex(request.run_configuration));
    }

    std::vector<std::string> query_hashes;
    query_hashes.reserve(request.queries.size());
    std::set<std::string> query_ids;
    for (const auto& query : request.queries) {
        const bool has_content = !query.cnf_content.empty();
        if (query.id.empty() || has_content == static_cast<bool>(query.write_cnf) ||
            !query_ids.insert(query.id).second) {
            throw std::invalid_argument("run bundle requires distinct query IDs and one CNF source per query");
        }
        if (query.write_cnf) {
            append_stream(query.cnf_path, "query_cnf", query.write_cnf);
            if (files.back().size_bytes == 0) {
                throw std::runtime_error("bundle query writer produced an empty CNF");
            }
        } else {
            append_bytes(query.cnf_path, "query_cnf", query.cnf_content,
                         q3a::sha256_hex(query.cnf_content));
        }
        query_hashes.push_back(files.back().sha256);
    }
    for (const auto& artifact : request.artifacts) {
        append_stream(artifact.path, artifact.role, artifact.write);
    }

    std::ostringstream property_report;
    property_report << "{\"schema_version\":\"Q3A-PROPERTY-RESULT-2\",\"property\":"
                    << json_string(request.property)
                    << ",\"algorithm\":" << json_string(request.algorithm)
                    << ",\"status\":" << json_string(request.status)
                    << ",\"assumptions\":[";
    for (std::size_t index = 0; index < request.assumptions.size(); ++index) {
        if (index) property_report << ',';
        property_report << json_string(request.assumptions[index]);
    }
    property_report << "],\"signals\":";
    trace::write_property_signals(property_report, request.property_signals);
    property_report << ",\"queries\":[";
    for (std::size_t index = 0; index < request.queries.size(); ++index) {
        if (index) property_report << ',';
        const auto& query = request.queries[index];
        property_report << "{\"id\":" << json_string(query.id)
                        << ",\"kind\":" << json_string(query.kind)
                        << ",\"status\":" << json_string(query.status)
                        << ",\"cnf_path\":" << json_string(query.cnf_path)
                        << ",\"cnf_sha256\":" << json_string(query_hashes[index]) << '}';
    }
    property_report << "]}\n";
    const auto property_content = property_report.str();
    append_bytes(
        "properties/" + safe_property_component(request.property) + "/property.json",
        "property_result", property_content, q3a::sha256_hex(property_content));

    std::ostringstream summary;
    summary << "{\"schema_version\":" << json_string(kSummarySchema)
            << ",\"run_id\":" << json_string(run_id)
            << ",\"status\":" << json_string(request.status)
            << ",\"property\":" << json_string(request.property)
            << ",\"algorithm\":" << json_string(request.algorithm)
            << ",\"detail\":" << json_string(request.detail)
            << ",\"vacuity\":" << json_string(request.vacuity)
            << ",\"boundary_obligations\":"
            << json_string(request.boundary_obligations)
            << ",\"model_sha256\":" << json_string(model_hash)
            << ",\"queries\":[";
    for (std::size_t index = 0; index < request.queries.size(); ++index) {
        if (index) summary << ',';
        summary << "{\"id\":" << json_string(request.queries[index].id)
                << ",\"kind\":" << json_string(request.queries[index].kind)
                << ",\"status\":" << json_string(request.queries[index].status)
                << ",\"cnf_sha256\":" << json_string(query_hashes[index]) << '}';
    }
    summary << "]}\n";
    const auto summary_content = summary.str();
    append_bytes("summary.json", "run_summary", summary_content, q3a::sha256_hex(summary_content));

    const auto manifest = serialize_manifest(
        project, request, run_id, manifest_hash, model_hash, executable_hash,
        query_hashes, files);
    const auto manifest_digest = q3a::sha256_hex(manifest);
    write_file(staging.path(), "manifest.json", [&](std::ostream& output) {
        output << manifest;
    });
    write_file(staging.path(), "manifest.sha256", [&](std::ostream& output) {
        output << manifest_digest << '\n';
    });
    staging.publish();
}

void write_trace_json(
    std::ostream& output,
    const replay::FrameView& trace,
    const std::string& property,
    std::size_t candidate_frame) {
    output << "{\"schema_version\":" << json_string(kTraceSchema)
           << ",\"property\":" << json_string(property)
           << ",\"candidate_frame\":" << candidate_frame
           << ",\"validated\":true,\"frames\":[";
    for (std::size_t frame = 0; frame < trace.size(); ++frame) {
        if (frame) output << ',';
        output << "{\"index\":" << frame << ",\"signals\":{";
        bool first = true;
        for (const auto& signal : trace[frame]) {
            if (!first) output << ',';
            first = false;
            output << json_string(signal.first) << ':'
                   << json_string("0x" + [&]() {
                       std::ostringstream value;
                       value << std::hex << signal.second;
                       return value.str();
                   }());
        }
        output << "}}";
    }
    output << "]}\n";
}

void write_induction_witness_text(
    std::ostream& output, const lowering::TIRModule& model, const replay::FrameView& frames,
    const std::string& property, replay::InductionObligation obligation, std::uint64_t depth,
    std::size_t failure_frame, const std::string& model_hash, const std::string& query_hash) {
    const bool base = obligation == replay::InductionObligation::Base;
    output << "Q3A_INDUCTION_WITNESS 1\n"
           << "obligation " << (base ? "base" : "step") << '\n'
           << "depth " << depth << '\n'
           << "model_sha256 " << model_hash << '\n'
           << "query_sha256 " << query_hash << '\n';
    if (!base) {
        for (std::uint64_t frame = 0; frame < depth; ++frame) {
            output << "property " << property << " frame=" << frame << " value=TRUE\n";
        }
    }
    output << "property " << property << " frame=" << failure_frame << " value=FALSE\n";
    std::map<std::string, std::uint64_t> widths;
    for (const auto& signal : model.signals) widths.emplace(signal.name, signal.width);
    for (std::size_t frame = 0; frame < frames.size(); ++frame) {
        output << "frame " << frame << '\n';
        for (const auto& entry : frames[frame]) {
            output << "signal " << entry.first << " width=" << widths.at(entry.first)
                   << " value=0x" << std::hex << entry.second << std::dec << '\n';
        }
    }
    output << "replay VALIDATED frame=" << failure_frame << '\n';
    if (!output) throw std::runtime_error("cannot write induction witness");
}

} // namespace q3a::bundle
