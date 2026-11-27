#include "batch_worker.hpp"

#include <limits>
#ifndef _WIN32
#include <cerrno>
#include <csignal>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <system_error>
#include <unistd.h>
#endif

#include <stdexcept>

namespace q3a {
namespace {
constexpr std::uint64_t kMiB = 1024 * 1024;

#ifdef _WIN32
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

std::optional<std::uint32_t> BatchWorker::poll() const {
    const auto wait = WaitForSingleObject(process_, 0);
    if (wait == WAIT_TIMEOUT) return std::nullopt;
    if (wait != WAIT_OBJECT_0) windows_error("WaitForSingleObject");
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process_, &exit_code)) windows_error("GetExitCodeProcess");
    return exit_code;
}

void BatchWorker::stop(std::uint32_t exit_code) const {
    if (!TerminateJobObject(job_, exit_code) && !poll()) windows_error("TerminateJobObject");
    if (WaitForSingleObject(process_, INFINITE) != WAIT_OBJECT_0) windows_error("WaitForSingleObject");
}

std::uint64_t BatchWorker::peak_memory_bytes() const {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION quota{};
    if (!QueryInformationJobObject(job_, JobObjectExtendedLimitInformation, &quota, sizeof(quota), nullptr)) {
        windows_error("QueryInformationJobObject");
    }
    return quota.PeakJobMemoryUsed;
}

#else
std::string encode_worker_argument(std::string_view argument) {
    constexpr char hex[] = "0123456789abcdef";
    std::string encoded = "x";
    for (unsigned char byte : argument) {
        encoded += hex[byte >> 4];
        encoded += hex[byte & 15];
    }
    return encoded;
}
} // namespace

BatchWorker::BatchWorker(const std::vector<std::string>& arguments, std::uint64_t memory_mib) {
    if (memory_mib == 0 || memory_mib > std::numeric_limits<rlim_t>::max() / kMiB) {
        throw std::invalid_argument("invalid batch worker memory limit");
    }
    std::vector<std::string> encoded{"q3aformal-sourcecheck", "--batch-worker",
                                     encode_worker_argument(std::to_string(memory_mib))};
    for (const auto& argument : arguments) encoded.push_back(encode_worker_argument(argument));
    std::vector<char*> argv;
    for (auto& argument : encoded) argv.push_back(argument.data());
    argv.push_back(nullptr);

    const auto parent = getpid();
    process_ = fork();
    if (process_ < 0) throw std::system_error(errno, std::generic_category(), "fork proof worker");
    if (process_ == 0) {
        // The child must also exit if the coordinator dies before exec.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(3);
        rlimit limit{};
        if (getrlimit(RLIMIT_AS, &limit) != 0) _exit(3);
        const auto bytes = static_cast<rlim_t>(memory_mib * kMiB);
        if (bytes < limit.rlim_cur) limit.rlim_cur = bytes;
        if (setrlimit(RLIMIT_AS, &limit) != 0) _exit(3);
        execv("/proc/self/exe", argv.data());
        _exit(3);
    }
}

BatchWorker::~BatchWorker() {
    if (!result_) {
        kill(process_, SIGKILL);
        try { reap(true); } catch (...) {}
    }
}

void BatchWorker::reap(bool block) const {
    if (result_) return;
    int state = 0;
    struct rusage usage {};
    pid_t pid;
    do { pid = wait4(process_, &state, block ? 0 : WNOHANG, &usage); }
    while (pid < 0 && errno == EINTR);
    if (pid < 0) throw std::system_error(errno, std::generic_category(), "wait for proof worker");
    if (pid == 0) return;
    peak_rss_bytes_ = static_cast<std::uint64_t>(usage.ru_maxrss) * 1024;
    result_ = WIFEXITED(state) ? static_cast<std::uint32_t>(WEXITSTATUS(state)) : 3U;
}

std::optional<std::uint32_t> BatchWorker::poll() const {
    reap(false);
    return result_;
}

void BatchWorker::stop(std::uint32_t exit_code) const {
    if (poll()) return;
    if (kill(process_, SIGKILL) != 0 && errno != ESRCH) {
        throw std::system_error(errno, std::generic_category(), "stop proof worker");
    }
    reap(true);
    result_ = exit_code;
}

std::uint64_t BatchWorker::peak_memory_bytes() const {
    return peak_rss_bytes_;
}
#endif

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
