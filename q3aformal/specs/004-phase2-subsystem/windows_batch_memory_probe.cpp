#include <windows.h>

#include <cstdint>
#include <iostream>
#include <string>

namespace {
constexpr std::uint64_t mib = 1024 * 1024;
constexpr SIZE_T limit = 64 * mib;

struct Handle {
    HANDLE value = nullptr;
    Handle() = default;
    explicit Handle(HANDLE handle) : value(handle) {}
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    ~Handle() { if (value) CloseHandle(value); }
};

int allocate_under_limit() {
    // Keep all allocations committed until the worker reaches its quota.
    for (unsigned n = 0; n != 12; ++n) {
        auto* const memory = VirtualAlloc(nullptr, 8 * mib, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!memory) return 77;
        *static_cast<volatile unsigned char*>(memory) = 1;
    }
    return 78;
}

int run_parent() {
    wchar_t executable[32768];
    const auto size = GetModuleFileNameW(nullptr, executable, 32768);
    if (size == 0 || size == 32768) return 2;
    Handle job(CreateJobObjectW(nullptr, nullptr));
    if (!job.value) return 3;

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION quota{};
    quota.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    quota.ProcessMemoryLimit = limit;
    quota.JobMemoryLimit = limit;
    if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &quota, sizeof(quota))) return 4;

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION worker{};
    auto command = std::wstring(L"\"") + executable + L"\" --worker";
    if (!CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
                        CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &worker)) return 5;
    Handle process(worker.hProcess), thread(worker.hThread);
    if (!AssignProcessToJobObject(job.value, process.value)) {
        const auto error = GetLastError();
        TerminateProcess(process.value, 6);
        WaitForSingleObject(process.value, 5000);
        std::cerr << "job assignment error: " << error << '\n';
        return 6;
    }
    if (ResumeThread(thread.value) == static_cast<DWORD>(-1)) return 7;
    if (WaitForSingleObject(process.value, 5000) != WAIT_OBJECT_0) return 8;
    DWORD result = 0;
    if (!GetExitCodeProcess(process.value, &result) ||
        !QueryInformationJobObject(job.value, JobObjectExtendedLimitInformation, &quota, sizeof(quota), nullptr)) return 9;
    std::cout << "{\"worker_exit\":" << result << ",\"limit_bytes\":" << limit
              << ",\"process_peak_commit_bytes\":" << quota.PeakProcessMemoryUsed
              << ",\"job_peak_commit_bytes\":" << quota.PeakJobMemoryUsed << "}\n";
    return result == 77 && quota.PeakProcessMemoryUsed > 0 && quota.PeakProcessMemoryUsed <= limit &&
        quota.PeakJobMemoryUsed > 0 && quota.PeakJobMemoryUsed <= limit ? 0 : 10;
}
} // namespace

int main(int argc, char**) {
    return argc == 2 ? allocate_under_limit() : run_parent();
}
