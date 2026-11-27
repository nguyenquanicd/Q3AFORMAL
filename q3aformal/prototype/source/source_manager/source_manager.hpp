#pragma once

#include "../frontend/preprocessor.hpp"
#include "platform_support.hpp"

#include <cstdint>
#include <filesystem>
#include <functional>
#include <iosfwd>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace q3a {

struct SourceFile {
    std::string relative_path;
    std::vector<std::uint8_t> contents;
    std::string sha256;
};

struct ProjectInput {
    std::string profile_id;
    std::string top_module;
    std::vector<SourceFile> sources;
    std::map<std::string, std::string> parameters;
    std::map<std::string, std::string> macros;
    std::vector<std::string> include_dirs;
    std::vector<SourceFile> headers;
    std::vector<std::vector<frontend::Token>> preprocessed_units;
    std::string input_hash;
    std::string manifest_sha256;
    unsigned manifest_version = 1;
    std::string default_engine;
    std::string default_property;
    std::optional<std::uint64_t> default_depth;
};

// Hash the resolved project identity in manifest source order.
std::string source_set_sha256(const ProjectInput& project);

using HeaderReader = std::function<std::optional<std::vector<std::uint8_t>>(const std::string&)>;
// Resolve and capture active includes in first-use order. The same routine
// consumes either original project files or a verified bundle snapshot.
void preprocess_project_includes(ProjectInput& project, const HeaderReader& read_header,
                                 const std::function<void()>& checkpoint = {},
                                 std::vector<std::vector<frontend::MacroExpansion>>* expansion_map = nullptr);

class SourceManager {
public:
    static ProjectInput load(const std::filesystem::path& manifest_path,
                             const std::function<void()>& checkpoint = {},
                             std::vector<std::vector<frontend::MacroExpansion>>* expansion_map = nullptr);
    static void apply_parameter_overrides(
        ProjectInput& project, const std::map<std::string, std::string>& overrides);
};

} // namespace q3a
