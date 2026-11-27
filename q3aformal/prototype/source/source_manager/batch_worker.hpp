#pragma once

#include <windows.h>

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

    std::optional<DWORD> poll() const;
    void stop(DWORD exit_code) const;
    std::uint64_t peak_commit_bytes() const;

private:
    HANDLE job_ = nullptr;
    HANDLE process_ = nullptr;
};

std::string decode_batch_worker_argument(std::string_view argument);

} // namespace q3a
