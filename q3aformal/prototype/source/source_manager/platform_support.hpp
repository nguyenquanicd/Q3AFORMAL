#pragma once

#include <cstdint>
#include <functional>
#include <iosfwd>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace q3a {

int run_utf8_command_line(int argc, wchar_t** argv, int (*entry)(int, char**));

std::string sha256_hex(const std::vector<std::uint8_t>& bytes);
std::string sha256_hex(std::string_view bytes);
std::string sha256_stream(std::istream& input);
std::string sha256_stream(std::istream& input, std::uint64_t expected_bytes);
std::string sha256_generated(const std::function<void(std::ostream&)>& write);

bool can_reserve_physical_memory(std::uint64_t reservation_bytes, std::uint64_t reserve_bytes);

class MemoryBudgetExceeded : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class MemoryBudget {
public:
    explicit MemoryBudget(std::function<void()> checkpoint = {},
                          std::uint64_t private_limit_mib = 0);
    void check(std::uint64_t pending_bytes = 0) const;
    std::uint64_t private_limit_bytes() const noexcept { return private_limit_; }
    std::uint64_t physical_reserve_bytes() const noexcept { return available_reserve_; }

private:
    std::function<void()> checkpoint_;
    std::uint64_t private_limit_ = 0;
    std::uint64_t available_reserve_ = 0;
};

} // namespace q3a
