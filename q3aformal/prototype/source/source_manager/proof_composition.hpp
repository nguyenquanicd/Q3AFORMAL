#pragma once

#include <filesystem>
#include <iosfwd>
#include <string_view>

namespace q3a {
class MemoryBudget;
namespace lowering { struct TIRModule; }
namespace composition {

int check(const lowering::TIRModule& model, const std::filesystem::path& plan,
          const std::filesystem::path& evidence, std::string_view manifest_sha256, bool reopen,
          const MemoryBudget& memory, std::ostream& output);

} // namespace composition
} // namespace q3a
