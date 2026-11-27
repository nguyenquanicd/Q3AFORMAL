#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace {

BOOL WINAPI ignore_probe_event(DWORD event) {
    return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT;
}

std::wstring quoted(const wchar_t* value) {
    return L"\"" + std::wstring(value) + L"\"";
}

int fail(const char* message) {
    const auto error = GetLastError();
    std::cerr << message << " (Windows error " << error << ")\n";
    return 2;
}

struct OwnedHandle {
    HANDLE value = INVALID_HANDLE_VALUE;
    ~OwnedHandle() {
        if (value != INVALID_HANDLE_VALUE) CloseHandle(value);
    }
};

struct ChildProcess {
    PROCESS_INFORMATION handles{};
    ~ChildProcess() {
        if (!handles.hProcess) return;
        CloseHandle(handles.hThread);
        if (WaitForSingleObject(handles.hProcess, 0) == WAIT_TIMEOUT) {
            TerminateProcess(handles.hProcess, 2);
            WaitForSingleObject(handles.hProcess, 5000);
        }
        CloseHandle(handles.hProcess);
    }
};

} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 5 && argc != 6) return 2;
    const bool batch = argc == 6 && std::wstring(argv[5]) == L"batch";
    if (argc == 6 && !batch) return 2;
    const std::wstring cause = argv[4];
    if (cause != L"ctrl_c" && cause != L"ctrl_break") return 2;
    if (!FreeConsole()) return fail("cannot detach the launcher console");
    if (!AllocConsole()) return fail("cannot allocate the private proof console");
    if (const auto window = GetConsoleWindow()) ShowWindow(window, SW_HIDE);
    if (!SetConsoleCtrlHandler(ignore_probe_event, TRUE)) return fail("cannot register launcher handler");
    std::wstring arguments = quoted(argv[1]) + (batch ? L" prove-batch " : L" prove ") + quoted(argv[2]);
    if (batch) {
        arguments += L" --plan plan.q3b --output-dir batch-result";
    } else {
        if (cause == L"ctrl_c") arguments += L" --run-record console-explicit.json";
        arguments += L" --engine bmc --property p_wraps_to_zero --frames 10000 --bundle-dir witness";
    }
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    const auto directory = std::filesystem::path(argv[3]);
    const auto diagnostics_path = directory / L"proof-stderr.txt";
    SECURITY_ATTRIBUTES inherited{sizeof(inherited), nullptr, TRUE};
    const OwnedHandle input{CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &inherited, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr)};
    const OwnedHandle result{CreateFileW((directory / L"proof-stdout.txt").c_str(),
        GENERIC_WRITE, FILE_SHARE_READ, &inherited, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr)};
    const OwnedHandle diagnostics{CreateFileW(diagnostics_path.c_str(),
        GENERIC_WRITE, FILE_SHARE_READ, &inherited, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr)};
    if (input.value == INVALID_HANDLE_VALUE || result.value == INVALID_HANDLE_VALUE ||
        diagnostics.value == INVALID_HANDLE_VALUE) return fail("cannot open private proof streams");

    startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = input.value;
    startup.hStdOutput = result.value;
    startup.hStdError = diagnostics.value;
    ChildProcess child;
    if (!CreateProcessW(argv[1], arguments.data(), nullptr, nullptr, TRUE, 0,
                        nullptr, argv[3], &startup, &child.handles)) {
        return fail("cannot start isolated console proof");
    }
    bool ready = false;
    for (int poll = 0; poll < 1500; ++poll) {
        std::ifstream log(diagnostics_path);
        std::string line;
        while (std::getline(log, line) && !ready) ready = line == "Q3A_PROVE_STAGE ELABORATION";
        if (ready || WaitForSingleObject(child.handles.hProcess, 10) != WAIT_TIMEOUT) break;
    }
    if (!ready) return fail("proof did not report entry to elaboration before cancellation");
    // Ctrl+C broadcasts to a console. Refuse to send it unless the console
    // contains this launcher and the exact proof process it just created.
    DWORD members[3]{};
    const auto member_count = GetConsoleProcessList(members, 3);
    if (member_count != 2 ||
        !((members[0] == GetCurrentProcessId() && members[1] == child.handles.dwProcessId) ||
          (members[1] == GetCurrentProcessId() && members[0] == child.handles.dwProcessId))) {
        std::cerr << "console member count=" << member_count << " launcher=" << GetCurrentProcessId()
                  << " proof=" << child.handles.dwProcessId << " members=" << members[0]
                  << ',' << members[1] << ',' << members[2] << '\n';
        return fail("private proof console membership changed");
    }
    const DWORD event = cause == L"ctrl_c" ? CTRL_C_EVENT : CTRL_BREAK_EVENT;
    if (!GenerateConsoleCtrlEvent(event, 0)) return fail("cannot send private console interrupt");
    if (WaitForSingleObject(child.handles.hProcess, 15000) != WAIT_OBJECT_0) {
        return fail("proof did not respond to the console interrupt");
    }
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(child.handles.hProcess, &exit_code) || exit_code != 1) {
        std::cerr << "proof exited with " << exit_code << '\n';
        return 2;
    }
    return 0;
}
