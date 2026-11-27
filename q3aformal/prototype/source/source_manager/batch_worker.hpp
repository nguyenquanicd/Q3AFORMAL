#pragma once

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/types.h>
#endif

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace q3a {

class BatchWorker {
public:
    BatchWorker(const std::vector<std::string>& proof_arguments, std::uint64_t memory_mib);
    BatchWorker(const BatchWorker&) = delete;
    BatchWorker& operator=(const BatchWorker&) = delete;
    ~BatchWorker();

    std::optional<std::uint32_t> poll() const;
    void stop(std::uint32_t exit_code) const;
    std::uint64_t peak_memory_bytes() const;

private:
#ifdef _WIN32
    HANDLE job_ = nullptr;
    HANDLE process_ = nullptr;
#else
    pid_t process_ = -1;
    mutable std::optional<std::uint32_t> result_;
    mutable std::uint64_t peak_rss_bytes_ = 0;
    void reap(bool block) const;
#endif
};

std::string decode_batch_worker_argument(std::string_view argument);

} // namespace q3a
