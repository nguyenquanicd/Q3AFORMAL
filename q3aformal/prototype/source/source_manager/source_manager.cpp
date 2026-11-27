#include "source_manager.hpp"
#include "write_locked_input.hpp"
#include "../bundle/windows_file_path.hpp"
#include "../frontend/preprocessor.hpp"
#include "../frontend/parser.hpp"

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#endif

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <fstream>
#include <limits>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <utility>

namespace q3a {
namespace {

constexpr const char* kProfileId = "Q3A-P0-R0.9.1";
constexpr const char* kManifestHeader = "Q3AFORMAL_PROJECT";

bool is_identifier(const std::string& value) {
    if (value.empty()) {
        return false;
    }
    const auto first = static_cast<unsigned char>(value.front());
    if (!(std::isalpha(first) || value.front() == '_')) {
        return false;
    }
    return std::all_of(value.begin() + 1, value.end(), [](char ch) {
        const auto c = static_cast<unsigned char>(ch);
        return std::isalnum(c) || ch == '_' || ch == '$';
    });
}

std::filesystem::path relative_include_path(const std::string& text) {
    const auto path = std::filesystem::u8path(text);
    if (text.empty() || text.find(':') != std::string::npos || text.find('\0') != std::string::npos ||
        path.has_root_path() || std::any_of(path.begin(), path.end(), [](const auto& part) { return part == ".."; })) {
        throw std::invalid_argument("include path must be relative and may not contain '..'");
    }
    auto normalized = path.lexically_normal();
    if (normalized.filename().empty()) normalized = normalized.parent_path();
    return normalized;
}

std::string trim(const std::string& input) {
    const auto first = input.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const auto last = input.find_last_not_of(" \t\r\n");
    return input.substr(first, last - first + 1);
}

[[noreturn]] void manifest_error(const std::filesystem::path& manifest,
                                 std::size_t line,
                                 const std::string& message) {
    throw std::runtime_error(manifest.filename().u8string() + ":" +
                             std::to_string(line) + ": " + message);
}

void ensure_no_extra(std::istringstream& stream,
                     const std::filesystem::path& manifest,
                     std::size_t line) {
    std::string extra;
    if (stream >> extra) {
        manifest_error(manifest, line, "unexpected trailing token: " + extra);
    }
}

std::string canonical_input_text(const ProjectInput& project) {
    std::ostringstream canonical;
    canonical << "Q3A_INPUT_ID 1\n";
    const auto append_field = [&canonical](char tag, const std::string& value) {
        canonical << tag << value.size() << ':' << value << '\n';
    };
    append_field('P', project.profile_id);
    append_field('T', project.top_module);
    for (const auto& parameter : project.parameters) {
        canonical << "A\n";
        append_field('N', parameter.first);
        append_field('V', parameter.second);
    }
    for (const auto& macro : project.macros) {
        canonical << "D\n";
        append_field('N', macro.first);
        append_field('V', macro.second);
    }
    for (const auto& path : project.include_dirs) append_field('I', path);
    for (const auto& source : project.sources) {
        canonical << "S\n";
        append_field('F', source.relative_path);
        append_field('H', source.sha256);
    }
    for (const auto& header : project.headers) {
        canonical << "H\n";
        append_field('F', header.relative_path);
        append_field('H', header.sha256);
    }
    return canonical.str();
}

#ifdef _WIN32
using FileIdentity = std::pair<ULONGLONG, std::array<BYTE, 16>>;

std::optional<FileIdentity> file_identity(const WriteLockedInput& input) {
    FILE_ID_INFO info{};
    if (!GetFileInformationByHandleEx(reinterpret_cast<HANDLE>(input.native_handle()),
            FileIdInfo, &info, sizeof(info))) {
        return std::nullopt;
    }
    FileIdentity identity{info.VolumeSerialNumber, {}};
    std::copy_n(info.FileId.Identifier, identity.second.size(), identity.second.begin());
    return identity;
}
#else
using FileIdentity = std::pair<dev_t, ino_t>;

std::optional<FileIdentity> file_identity(const WriteLockedInput& input) {
    struct stat info {};
    if (fstat(static_cast<int>(input.native_handle()), &info) != 0) return std::nullopt;
    return FileIdentity{info.st_dev, info.st_ino};
}
#endif

std::vector<std::uint8_t> read_binary_file(std::istream& input, const std::string& display_path) {
    input.seekg(0, std::ios::end);
    const auto end_position = input.tellg();
    if (end_position < 0) {
        throw std::runtime_error("cannot determine source file size: " +
                                 display_path);
    }
    const auto length = static_cast<std::streamoff>(end_position);
    if (static_cast<unsigned long long>(length) >
        static_cast<unsigned long long>(
            std::numeric_limits<std::size_t>::max()) ||
        static_cast<unsigned long long>(length) >
        static_cast<unsigned long long>(
            std::numeric_limits<std::streamsize>::max())) {
        throw std::runtime_error("source file is too large: " + display_path);
    }

    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    input.seekg(0, std::ios::beg);
    if (!bytes.empty()) {
        input.read(reinterpret_cast<char*>(bytes.data()),
                   static_cast<std::streamsize>(bytes.size()));
        if (!input) {
            throw std::runtime_error("cannot read source file: " +
                                     display_path);
        }
    }
    return bytes;
}

bool is_within_root(const std::filesystem::path& root,
                    const std::filesystem::path& candidate) {
    const auto relative = candidate.lexically_relative(root);
    if (relative.empty() || relative.is_absolute()) {
        return false;
    }
    return *relative.begin() != std::filesystem::path("..");
}

std::string relative_path_utf8(const std::filesystem::path& root,
                               const std::filesystem::path& candidate) {
    return candidate.lexically_relative(root).generic_u8string();
}

} // namespace

std::string source_set_sha256(const ProjectInput& project) {
    return sha256_hex(canonical_input_text(project));
}

void preprocess_project_includes(ProjectInput& project, const HeaderReader& read_header,
                                 const std::function<void()>& checkpoint,
                                 std::vector<std::vector<frontend::MacroExpansion>>* expansion_map) {
    if (project.manifest_version != 2) {
        if (expansion_map) throw std::invalid_argument("preprocessing diagnostics require manifest version 2");
        return;
    }
    constexpr std::string_view directive = "`include";
    const bool needs_resolution = std::any_of(project.sources.begin(), project.sources.end(), [&](const auto& source) {
        if (checkpoint) checkpoint();
        return std::search(source.contents.begin(), source.contents.end(), directive.begin(), directive.end()) !=
            source.contents.end();
    });
    if (!needs_resolution && !expansion_map) return;
    std::map<std::string, std::size_t> header_indexes;
    const auto resolve = [&](const frontend::SourceLocation& at, const std::string& requested)
        -> std::optional<frontend::Preprocessor::Include> {
        try {
            const auto relative = relative_include_path(requested);
            std::vector<std::filesystem::path> roots{std::filesystem::u8path(at.file).parent_path()};
            for (const auto& configured : project.include_dirs) roots.push_back(relative_include_path(configured));
            for (const auto& root : roots) {
                if (checkpoint) checkpoint();
                const auto key = (root / relative).lexically_normal().generic_u8string();
                auto found = header_indexes.find(key);
                if (found == header_indexes.end()) {
                    const auto listed = std::find_if(project.sources.begin(), project.sources.end(),
                        [&](const auto& file) { return file.relative_path == key; });
                    auto bytes = listed != project.sources.end()
                        ? std::optional<std::vector<std::uint8_t>>(listed->contents) : read_header(key);
                    if (!bytes) continue;
                    const auto digest = sha256_hex(*bytes);
                    found = header_indexes.emplace(key, project.headers.size()).first;
                    project.headers.push_back({key, std::move(*bytes), digest});
                }
                const auto& resolved = project.headers[found->second];
                return frontend::Preprocessor::Include{resolved.relative_path,
                    std::string(resolved.contents.begin(), resolved.contents.end())};
            }
            return std::nullopt;
        } catch (const std::invalid_argument& error) {
            throw frontend::ParseError(at, error.what());
        } catch (const std::runtime_error& error) {
            throw frontend::ParseError(at, error.what());
        }
    };
    frontend::Preprocessor preprocessor(project.macros, resolve);
    for (const auto& source : project.sources) {
        if (checkpoint) checkpoint();
        const std::string contents(source.contents.begin(), source.contents.end());
        if (expansion_map) {
            auto unit = preprocessor.tokenize_unit_with_expansions(contents, source.relative_path);
            project.preprocessed_units.push_back(std::move(unit.tokens));
            expansion_map->push_back(std::move(unit.expansions));
        } else {
            project.preprocessed_units.push_back(preprocessor.tokenize_unit(contents, source.relative_path));
        }
    }
}

ProjectInput SourceManager::load(const std::filesystem::path& manifest_path,
                                 const std::function<void()>& checkpoint,
                                 std::vector<std::vector<frontend::MacroExpansion>>* expansion_map) {
    if (checkpoint) checkpoint();
    std::error_code error;
    const auto canonical_manifest =
        std::filesystem::canonical(manifest_path, error);
    if (error) {
        throw std::runtime_error("cannot resolve manifest: " +
                                 manifest_path.u8string() + " (" +
                                 error.message() + ")");
    }

    const auto project_root = canonical_manifest.parent_path();
    WriteLockedInput manifest_file(bundle::detail::windows_file_path(canonical_manifest));
    auto& manifest = manifest_file.stream();
    ProjectInput project;
    project.manifest_sha256 = sha256_stream(manifest);
    manifest_file.rewind();
    project.profile_id = kProfileId;
    std::vector<std::filesystem::path> canonical_sources;
    std::vector<std::filesystem::path> sources_without_id;
    std::set<FileIdentity> source_ids;
    std::set<std::string> seen_relative_paths;
    std::set<std::string> seen_options;
    bool header_seen = false;
    bool top_seen = false;
    std::size_t line_number = 0;
    std::string line;

    while (std::getline(manifest, line)) {
        if (checkpoint) checkpoint();
        ++line_number;
        const auto cleaned = trim(line);
        if (cleaned.empty() || cleaned.front() == '#') {
            continue;
        }

        std::istringstream row(cleaned);
        std::string directive;
        row >> directive;

        if (!header_seen) {
            unsigned long version = 0;
            if (directive != kManifestHeader || !(row >> version) ||
                (version != 1 && version != 2)) {
                manifest_error(canonical_manifest,
                               line_number,
                               "first non-comment line must be "
                               "Q3AFORMAL_PROJECT 1 or Q3AFORMAL_PROJECT 2");
            }
            ensure_no_extra(row, canonical_manifest, line_number);
            project.manifest_version = static_cast<unsigned>(version);
            header_seen = true;
            continue;
        }

        if (directive == "top") {
            std::string top;
            if (!(row >> top) || !is_identifier(top)) {
                manifest_error(canonical_manifest,
                               line_number,
                               "top requires one valid module identifier");
            }
            ensure_no_extra(row, canonical_manifest, line_number);
            if (top_seen) {
                manifest_error(canonical_manifest,
                               line_number,
                               "top may be declared only once");
            }
            project.top_module = std::move(top);
            top_seen = true;
            continue;
        }

        if (directive == "parameter") {
            std::string name;
            std::string value;
            if (!(row >> name >> value) || !is_identifier(name)) {
                manifest_error(canonical_manifest,
                               line_number,
                               "parameter syntax is: parameter NAME VALUE");
            }
            ensure_no_extra(row, canonical_manifest, line_number);
            if (!project.parameters.emplace(name, value).second) {
                manifest_error(canonical_manifest,
                               line_number,
                               "duplicate parameter: " + name);
            }
            continue;
        }

        if (project.manifest_version == 2 && directive == "include_dir") {
            row >> std::ws;
            std::string path;
            if (row.peek() != '"' || !(row >> std::quoted(path))) {
                manifest_error(canonical_manifest, line_number, "include_dir requires a quoted relative directory");
            }
            ensure_no_extra(row, canonical_manifest, line_number);
            try {
                path = relative_include_path(path).generic_u8string();
            } catch (const std::invalid_argument& error) {
                manifest_error(canonical_manifest, line_number, error.what());
            }
            if (std::find(project.include_dirs.begin(), project.include_dirs.end(), path) != project.include_dirs.end()) {
                manifest_error(canonical_manifest, line_number, "duplicate include_dir: " + path);
            }
            project.include_dirs.push_back(std::move(path));
            continue;
        }

        if (project.manifest_version == 2 && directive == "define") {
            std::string name;
            std::string value;
            if (!(row >> name) || !is_identifier(name)) {
                manifest_error(canonical_manifest, line_number, "define requires a macro identifier");
            }
            std::getline(row, value);
            if (!project.macros.emplace(name, trim(value)).second) {
                manifest_error(canonical_manifest, line_number, "duplicate macro: " + name);
            }
            continue;
        }

        if (project.manifest_version == 2 && directive == "option") {
            std::string key;
            std::string value;
            if (!(row >> key >> value)) {
                manifest_error(canonical_manifest, line_number, "option requires a name and value");
            }
            ensure_no_extra(row, canonical_manifest, line_number);
            if (!seen_options.insert(key).second) {
                manifest_error(canonical_manifest, line_number, "duplicate option: " + key);
            }
            if (key == "profile" && frontend::project_syntax_profile(value)) {
                project.profile_id = value;
            } else if (key == "engine" && (value == "bmc" || value == "induction" || value == "pdr")) {
                project.default_engine = value;
            } else if (key == "property" && std::all_of(value.begin(), value.end(), [](unsigned char ch) {
                return ch >= 0x21 && ch <= 0x7e;
            })) {
                project.default_property = value;
            } else if (key == "depth") {
                std::uint64_t depth = 0;
                const auto parsed = std::from_chars(value.data(), value.data() + value.size(), depth);
                if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size() || depth > 10000) {
                    manifest_error(canonical_manifest, line_number, "depth must be in 0..10000");
                }
                project.default_depth = depth;
            } else {
                manifest_error(canonical_manifest, line_number, "unsupported option or value: " + key + " " + value);
            }
            continue;
        }

        if (directive == "source" || (project.manifest_version == 2 && directive == "property_source")) {
            if (project.manifest_version == 2) {
                std::string language;
                if (!(row >> language) || language != "systemverilog") {
                    manifest_error(canonical_manifest, line_number, "source language must be systemverilog");
                }
                row >> std::ws;
                if (row.peek() != '"') {
                    manifest_error(canonical_manifest, line_number, "expected a quoted source path");
                }
            }
            std::string path_text;
            if (!(row >> std::quoted(path_text)) || path_text.empty()) {
                manifest_error(canonical_manifest,
                               line_number,
                               "source requires a quoted relative path");
            }
            ensure_no_extra(row, canonical_manifest, line_number);

            const auto requested = std::filesystem::u8path(path_text);
            if (requested.has_root_path()) {
                manifest_error(canonical_manifest,
                               line_number,
                               "source paths must be relative to the manifest");
            }
            for (const auto& component : requested) {
                if (component == "..") {
                    manifest_error(canonical_manifest,
                                   line_number,
                                   "source path may not contain '..'");
                }
            }

            const auto resolved =
                std::filesystem::canonical(project_root / requested, error);
            if (error) {
                manifest_error(canonical_manifest,
                               line_number,
                               "cannot resolve source '" + path_text +
                                   "': " + error.message());
            }
            if (!is_within_root(project_root, resolved)) {
                manifest_error(canonical_manifest,
                               line_number,
                               "source resolves outside the project root");
            }
            if (!std::filesystem::is_regular_file(resolved, error) || error) {
                manifest_error(canonical_manifest,
                               line_number,
                               "source is not a regular file: " + path_text);
            }

            const auto relative = relative_path_utf8(project_root, resolved);
            if (!seen_relative_paths.insert(relative).second) {
                manifest_error(canonical_manifest,
                               line_number,
                               "duplicate source path: " + path_text);
            }
            WriteLockedInput input(bundle::detail::windows_file_path(resolved));
            const auto id = file_identity(input);
            // Filesystems without FileIdInfo retain the path-based alias check.
            const auto& compare_paths = id ? sources_without_id : canonical_sources;
            if ((id && !source_ids.insert(*id).second) ||
                std::any_of(compare_paths.begin(), compare_paths.end(), [&](const auto& previous) {
                    if (checkpoint) checkpoint();
                    std::error_code alias_error;
                    return std::filesystem::equivalent(previous, resolved, alias_error) && !alias_error;
                })) {
                manifest_error(canonical_manifest, line_number, "source aliases an already listed file: " + path_text);
            }
            if (!id) sources_without_id.push_back(resolved);

            auto contents = read_binary_file(input.stream(), relative);
            const auto digest = sha256_hex(contents);
            project.sources.push_back(
                SourceFile{relative, std::move(contents), digest});
            canonical_sources.push_back(resolved);
            continue;
        }

        manifest_error(canonical_manifest,
                       line_number,
                       "unsupported manifest directive: " + directive);
    }

    if (manifest.bad() || !manifest.eof()) {
        throw std::runtime_error("failed while reading project manifest");
    }
    if (!header_seen) {
        throw std::runtime_error(canonical_manifest.filename().u8string() +
                                 ": missing Q3AFORMAL_PROJECT header");
    }
    if (!top_seen) {
        throw std::runtime_error(canonical_manifest.filename().u8string() +
                                 ": missing top declaration");
    }
    if (project.sources.empty()) {
        throw std::runtime_error(canonical_manifest.filename().u8string() +
                                 ": project must list at least one source");
    }

    preprocess_project_includes(project, [&](const std::string& path)
        -> std::optional<std::vector<std::uint8_t>> {
        const auto candidate = project_root / relative_include_path(path);
        std::error_code header_error;
        const auto resolved = std::filesystem::canonical(candidate, header_error);
        if (header_error == std::errc::no_such_file_or_directory) return std::nullopt;
        if (header_error) throw std::runtime_error("cannot resolve include '" + path + "': " + header_error.message());
        if (!is_within_root(project_root, resolved)) {
            throw std::invalid_argument("include resolves outside the project root: " + path);
        }
        if (!std::filesystem::is_regular_file(resolved, header_error) || header_error) {
            throw std::runtime_error("include is not a regular file: " + path);
        }
        WriteLockedInput input(bundle::detail::windows_file_path(resolved));
        return read_binary_file(input.stream(), path);
    }, checkpoint, expansion_map);
    if (checkpoint) checkpoint();
    project.input_hash = source_set_sha256(project);
    if (checkpoint) checkpoint();
    return project;
}

void SourceManager::apply_parameter_overrides(
    ProjectInput& project, const std::map<std::string, std::string>& overrides) {
    for (const auto& entry : overrides) {
        if (!is_identifier(entry.first) || entry.second.empty() ||
            entry.second.find_first_of(" \r\n\t") != std::string::npos) {
            throw std::invalid_argument("invalid command-line parameter override: " + entry.first);
        }
    }
    for (const auto& entry : overrides) project.parameters.insert_or_assign(entry.first, entry.second);
    if (!overrides.empty()) project.input_hash = source_set_sha256(project);
}

} // namespace q3a
