#include "batch_worker.hpp"

#include <limits>
#include <stdexcept>

namespace q3a {
namespace {
constexpr std::uint64_t kMiB = 1024 * 1024;

[[noreturn]] void windows_error(const char* operation, DWORD error = GetLastError()) {
    throw std::runtime_error(std::string(operation) + " failed with Windows error " + std::to_string(error));
}

void append_encoded(std::wstring& command, const std::string& argument) {
    constexpr wchar_t hex[] = L"0123456789abcdef";
    if (argument.size() > (32766 - command.size()) / 2 || command.size() + argument.size() * 2 + 2 > 32766) {
        throw std::invalid_argument("batch worker command exceeds the Windows command-line limit");
    }
    command += L" x";
    for (unsigned char byte : argument) {
        command += hex[byte >> 4];
        command += hex[byte & 15];
    }
}
} // namespace

BatchWorker::BatchWorker(const std::vector<std::string>& proof_arguments, std::uint64_t memory_mib) {
    if (memory_mib == 0 || memory_mib > std::numeric_limits<SIZE_T>::max() / kMiB) {
        throw std::invalid_argument("invalid batch worker memory limit");
    }
    wchar_t executable[32768];
    const auto length = GetModuleFileNameW(nullptr, executable, 32768);
    if (length == 0 || length >= 32768) windows_error("GetModuleFileNameW");
    // CreateProcess gets the executable separately. The first token is only argv[0].
    std::wstring command = L"q3aformal --batch-worker";
    append_encoded(command, std::to_string(memory_mib));
    for (const auto& argument : proof_arguments) append_encoded(command, argument);

    job_ = CreateJobObjectW(nullptr, nullptr);
    if (!job_) windows_error("CreateJobObjectW");
    try {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION quota{};
        quota.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY |
            JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        quota.ProcessMemoryLimit = static_cast<SIZE_T>(memory_mib * kMiB);
        quota.JobMemoryLimit = quota.ProcessMemoryLimit;
        if (!SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &quota, sizeof(quota))) {
            windows_error("SetInformationJobObject");
        }
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION worker{};
        if (!CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
                            CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &worker)) {
            windows_error("CreateProcessW");
        }
        process_ = worker.hProcess;
        if (!AssignProcessToJobObject(job_, process_)) {
            const auto error = GetLastError();
            TerminateProcess(process_, 3);
            WaitForSingleObject(process_, INFINITE);
            CloseHandle(worker.hThread);
            windows_error("AssignProcessToJobObject", error);
        }
        const auto resumed = ResumeThread(worker.hThread);
        const auto error = GetLastError();
        CloseHandle(worker.hThread);
        if (resumed == static_cast<DWORD>(-1)) windows_error("ResumeThread", error);
    } catch (...) {
        CloseHandle(job_);
        if (process_) CloseHandle(process_);
        throw;
    }
}

BatchWorker::~BatchWorker() {
    CloseHandle(job_);
    CloseHandle(process_);
}

std::optional<DWORD> BatchWorker::poll() const {
    const auto wait = WaitForSingleObject(process_, 0);
    if (wait == WAIT_TIMEOUT) return std::nullopt;
    if (wait != WAIT_OBJECT_0) windows_error("WaitForSingleObject");
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process_, &exit_code)) windows_error("GetExitCodeProcess");
    return exit_code;
}

void BatchWorker::stop(DWORD exit_code) const {
    if (!TerminateJobObject(job_, exit_code) && !poll()) windows_error("TerminateJobObject");
    if (WaitForSingleObject(process_, INFINITE) != WAIT_OBJECT_0) windows_error("WaitForSingleObject");
}

std::uint64_t BatchWorker::peak_commit_bytes() const {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION quota{};
    if (!QueryInformationJobObject(job_, JobObjectExtendedLimitInformation, &quota, sizeof(quota), nullptr)) {
        windows_error("QueryInformationJobObject");
    }
    return quota.PeakJobMemoryUsed;
}

std::string decode_batch_worker_argument(std::string_view argument) {
    if (argument.empty() || argument.front() != 'x' || argument.size() % 2 == 0) {
        throw std::invalid_argument("invalid batch worker argument");
    }
    const auto digit = [](char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        throw std::invalid_argument("invalid batch worker argument");
    };
    std::string value;
    value.reserve(argument.size() / 2);
    for (std::size_t i = 1; i < argument.size(); i += 2) {
        value.push_back(static_cast<char>(digit(argument[i]) * 16 + digit(argument[i + 1])));
    }
    if (value.find('\0') != std::string::npos) throw std::invalid_argument("nul byte in batch worker argument");
    return value;
}

} // namespace q3a
