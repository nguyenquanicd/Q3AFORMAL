#include "platform_support.hpp"

#include <windows.h>
#include <bcrypt.h>
#include <psapi.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <streambuf>
#include <utility>

namespace q3a {
namespace {

struct AlgorithmGuard {
    BCRYPT_ALG_HANDLE value = nullptr;
    ~AlgorithmGuard() {
        if (value != nullptr) {
            BCryptCloseAlgorithmProvider(value, 0);
        }
    }
};

struct HashGuard {
    BCRYPT_HASH_HANDLE value = nullptr;
    ~HashGuard() {
        if (value != nullptr) {
            BCryptDestroyHash(value);
        }
    }
};

std::string ntstatus_hex(NTSTATUS status) {
    std::ostringstream out;
    out << "0x" << std::hex << std::uppercase
        << static_cast<unsigned long>(status);
    return out.str();
}

void require_nt_success(NTSTATUS status, const char* operation) {
    if (status < 0) {
        throw std::runtime_error(std::string(operation) +
                                 " failed with NTSTATUS " +
                                 ntstatus_hex(status));
    }
}

} // namespace

namespace {
constexpr std::uint64_t kMebibyte = 1024 * 1024;

std::uint64_t available_physical_bytes() {
    MEMORYSTATUSEX status{};
    status.dwLength = sizeof(status);
    return GlobalMemoryStatusEx(&status) ? status.ullAvailPhys : 0;
}

bool private_commit_bytes(std::uint64_t& bytes) {
    PROCESS_MEMORY_COUNTERS_EX counters{};
    counters.cb = sizeof(counters);
    if (!K32GetProcessMemoryInfo(GetCurrentProcess(),
            reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof(counters))) {
        return false;
    }
    bytes = counters.PrivateUsage;
    return true;
}

bool exceeds_budget(std::uint64_t used, std::uint64_t pending, std::uint64_t limit) {
    return used > limit || pending > limit - used;
}
} // namespace

int run_utf8_command_line(int argc, wchar_t** argv, int (*entry)(int, char**)) {
    std::vector<std::string> arguments;
    std::vector<char*> pointers;
    try {
        arguments.reserve(static_cast<std::size_t>(argc));
        pointers.reserve(static_cast<std::size_t>(argc) + 1);
        for (int index = 0; index < argc; ++index) {
            const auto size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                argv[index], -1, nullptr, 0, nullptr, nullptr);
            if (size <= 0) throw std::runtime_error("invalid UTF-16 command-line argument");

            std::string argument(static_cast<std::size_t>(size), '\0');
            if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                    argv[index], -1, argument.data(), size, nullptr, nullptr) != size) {
                throw std::runtime_error("could not encode command-line argument as UTF-8");
            }
            argument.pop_back();
            arguments.push_back(std::move(argument));
        }
        for (auto& argument : arguments) pointers.push_back(argument.data());
        pointers.push_back(nullptr);
    } catch (const std::exception& error) {
        std::cerr << "Q3A_COMMAND_LINE_ERROR " << error.what() << '\n';
        return 2;
    }
    return entry(argc, pointers.data());
}

bool can_reserve_physical_memory(std::uint64_t reservation_bytes, std::uint64_t reserve_bytes) {
    const auto available = available_physical_bytes();
    return available != 0 && !exceeds_budget(reserve_bytes, reservation_bytes, available);
}

MemoryBudget::MemoryBudget(std::function<void()> checkpoint, std::uint64_t private_limit_mib)
    : checkpoint_(std::move(checkpoint)) {
    const auto available = available_physical_bytes();
    std::uint64_t baseline = 0;
    const bool has_private_counter = private_commit_bytes(baseline);
    if (available != 0) {
        available_reserve_ = std::min(512 * kMebibyte, available / 4);
        if (has_private_counter) {
            const auto allowance = available / 2;
            private_limit_ = baseline + std::min(allowance,
                std::numeric_limits<std::uint64_t>::max() - baseline);
        }
    }
    if (const auto* configured = std::getenv("Q3A_MEMORY_LIMIT_MIB")) {
        const std::string setting(configured);
        std::uint64_t limit_mib = 0;
        const auto parsed = std::from_chars(setting.data(), setting.data() + setting.size(), limit_mib);
        if (parsed.ec != std::errc{} || parsed.ptr != setting.data() + setting.size() ||
            limit_mib == 0 || limit_mib > std::numeric_limits<std::uint64_t>::max() / kMebibyte) {
            throw std::invalid_argument("Q3A_MEMORY_LIMIT_MIB must be a positive integer in MiB");
        }
        if (!has_private_counter) {
            throw std::runtime_error("cannot monitor process private memory for Q3A_MEMORY_LIMIT_MIB");
        }
        const auto limit_bytes = limit_mib * kMebibyte;
        private_limit_ = private_limit_ == 0 ? limit_bytes : std::min(private_limit_, limit_bytes);
    }
    if (private_limit_mib != 0) {
        if (private_limit_mib > std::numeric_limits<std::uint64_t>::max() / kMebibyte) {
            throw std::invalid_argument("invalid proof job memory limit");
        }
        if (!has_private_counter) {
            throw std::runtime_error("cannot monitor process private memory for the proof job");
        }
        const auto limit_bytes = private_limit_mib * kMebibyte;
        private_limit_ = private_limit_ == 0 ? limit_bytes : std::min(private_limit_, limit_bytes);
    }
    if (const auto* configured = std::getenv("Q3A_MEMORY_RESERVE_MIB")) {
        const std::string setting(configured);
        std::uint64_t reserve_mib = 0;
        const auto parsed = std::from_chars(
            setting.data(), setting.data() + setting.size(), reserve_mib);
        if (parsed.ec != std::errc{} || parsed.ptr != setting.data() + setting.size() ||
            reserve_mib == 0 || reserve_mib > std::numeric_limits<std::uint64_t>::max() / kMebibyte) {
            throw std::invalid_argument(
                "Q3A_MEMORY_RESERVE_MIB must be a positive integer in MiB");
        }
        if (available == 0) {
            throw std::runtime_error(
                "cannot monitor available physical memory for Q3A_MEMORY_RESERVE_MIB");
        }
        available_reserve_ = reserve_mib * kMebibyte;
    }
}

void MemoryBudget::check(std::uint64_t pending_bytes) const {
    if (checkpoint_) checkpoint_();
    std::uint64_t used = 0;
    if (private_limit_ != 0) {
        if (!private_commit_bytes(used)) {
            throw MemoryBudgetExceeded("process private memory measurement unavailable");
        }
        if (exceeds_budget(used, pending_bytes, private_limit_)) {
            throw MemoryBudgetExceeded("process private memory budget reached (used=" +
                std::to_string(used) + " pending=" + std::to_string(pending_bytes) +
                " limit=" + std::to_string(private_limit_) + " bytes)");
        }
    }
    if (available_reserve_ != 0) {
        const auto available = available_physical_bytes();
        if (exceeds_budget(available_reserve_, pending_bytes, available)) {
            throw MemoryBudgetExceeded("available physical memory reserve reached (available=" +
                std::to_string(available) + " pending=" + std::to_string(pending_bytes) +
                " reserve=" + std::to_string(available_reserve_) + " bytes)");
        }
    }
}

namespace {
template <typename Update>
class HashOutputBuffer final : public std::streambuf {
public:
    explicit HashOutputBuffer(const Update& update) : update_(update) {
        setp(bytes_.data(), bytes_.data() + bytes_.size());
    }

protected:
    int sync() override {
        const auto count = pptr() - pbase();
        if (count != 0) update_(pbase(), static_cast<ULONG>(count));
        setp(bytes_.data(), bytes_.data() + bytes_.size());
        return 0;
    }

    int_type overflow(int_type character) override {
        sync();
        if (!traits_type::eq_int_type(character, traits_type::eof())) {
            *pptr() = traits_type::to_char_type(character);
            pbump(1);
        }
        return traits_type::not_eof(character);
    }

private:
    const Update& update_;
    std::array<char, 64 * 1024> bytes_;
};

template <typename Feed>
std::string compute_sha256(Feed feed) {
    AlgorithmGuard algorithm;
    require_nt_success(
        BCryptOpenAlgorithmProvider(&algorithm.value,
                                    BCRYPT_SHA256_ALGORITHM,
                                    nullptr,
                                    0),
        "BCryptOpenAlgorithmProvider(SHA-256)");

    ULONG object_length = 0;
    ULONG result_length = 0;
    require_nt_success(
        BCryptGetProperty(algorithm.value,
                          BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_length),
                          sizeof(object_length),
                          &result_length,
                          0),
        "BCryptGetProperty(BCRYPT_OBJECT_LENGTH)");

    ULONG digest_length = 0;
    require_nt_success(
        BCryptGetProperty(algorithm.value,
                          BCRYPT_HASH_LENGTH,
                          reinterpret_cast<PUCHAR>(&digest_length),
                          sizeof(digest_length),
                          &result_length,
                          0),
        "BCryptGetProperty(BCRYPT_HASH_LENGTH)");

    std::vector<UCHAR> hash_object(object_length);
    std::vector<UCHAR> digest(digest_length);
    HashGuard hash;
    require_nt_success(
        BCryptCreateHash(algorithm.value,
                         &hash.value,
                         hash_object.data(),
                         object_length,
                         nullptr,
                         0,
                         0),
        "BCryptCreateHash");

    feed([&](const char* data, ULONG count) {
        require_nt_success(
            BCryptHashData(hash.value,
                           reinterpret_cast<PUCHAR>(const_cast<char*>(data)),
                           count,
                           0),
            "BCryptHashData");
    });

    require_nt_success(
        BCryptFinishHash(hash.value, digest.data(), digest_length, 0),
        "BCryptFinishHash");

    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::nouppercase;
    for (const auto byte : digest) {
        out << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return out.str();
}
} // namespace

std::string sha256_hex(std::string_view bytes) {
    return compute_sha256([&](const auto& update) {
        constexpr auto max_chunk = std::numeric_limits<ULONG>::max();
        while (!bytes.empty()) {
            const auto count = std::min<std::size_t>(bytes.size(), max_chunk);
            update(bytes.data(), static_cast<ULONG>(count));
            bytes.remove_prefix(count);
        }
    });
}

std::string sha256_hex(const std::vector<std::uint8_t>& bytes) {
    return sha256_hex(bytes.empty() ? std::string_view{} : std::string_view(
        reinterpret_cast<const char*>(bytes.data()), bytes.size()));
}

std::string sha256_generated(const std::function<void(std::ostream&)>& write) {
    return compute_sha256([&](const auto& update) {
        HashOutputBuffer buffer(update);
        std::ostream output(&buffer);
        output.exceptions(std::ios::failbit | std::ios::badbit);
        write(output);
        output.flush();
    });
}

std::string sha256_stream(std::istream& input) {
    return compute_sha256([&](const auto& update) {
        std::array<char, 64 * 1024> buffer;
        do {
            input.read(buffer.data(), buffer.size());
            if (input.gcount() > 0) update(buffer.data(), static_cast<ULONG>(input.gcount()));
        } while (input);
        if (input.bad() || !input.eof()) {
            throw std::runtime_error("failed while reading SHA-256 input stream");
        }
    });
}

std::string sha256_stream(std::istream& input, std::uint64_t expected_bytes) {
    return compute_sha256([&](const auto& update) {
        std::array<char, 64 * 1024> buffer;
        while (expected_bytes != 0) {
            const auto count = std::min<std::uint64_t>(expected_bytes, buffer.size());
            if (!input.read(buffer.data(), static_cast<std::streamsize>(count))) {
                throw std::runtime_error("SHA-256 input ended before the declared size");
            }
            update(buffer.data(), static_cast<ULONG>(count));
            expected_bytes -= count;
        }
        if (input.peek() != std::char_traits<char>::eof() || input.bad()) {
            throw std::runtime_error("SHA-256 input does not match the declared size");
        }
    });
}

} // namespace q3a
