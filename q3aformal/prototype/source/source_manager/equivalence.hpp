#pragma once

#include "lowering.hpp"

#include <filesystem>
#include <iosfwd>
#include <string>
#include <vector>

namespace q3a {
class MemoryBudget;
namespace equivalence {

struct Design {
    lowering::TIRModule model;
    std::vector<elaboration::TypedSignal> ports;
    std::string manifest_sha256;
};

int check(const Design& reference, const Design& implementation, const std::filesystem::path& plan,
          const std::filesystem::path& evidence, bool reopen, std::size_t depth, const MemoryBudget& memory,
          std::ostream& output);

} // namespace equivalence
} // namespace q3a
