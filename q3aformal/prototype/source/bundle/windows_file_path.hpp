#pragma once

#include <algorithm>
#include <filesystem>
#include <memory>
#include <system_error>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace q3a::bundle::detail {

inline std::filesystem::path windows_file_path(const std::filesystem::path& absolute) {
    auto path = absolute.native();
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.rfind(LR"(\\?\)", 0) == 0 || path.rfind(LR"(\\.\)", 0) == 0) {
        return path;
    }
    if (path.rfind(LR"(\\)", 0) == 0) {
        return LR"(\\?\UNC\)" +
            std::filesystem::path(path.substr(2)).lexically_normal().make_preferred().native();
    }
    return LR"(\\?\)" +
        std::filesystem::path(path).lexically_normal().make_preferred().native();
}

inline std::filesystem::path absolute_windows_file_path(std::filesystem::path path) {
    path.make_preferred();
    const auto& native = path.native();
    if (native.rfind(LR"(\\?\)", 0) == 0 || native.rfind(LR"(\\.\)", 0) == 0) {
        return path;
    }
    return windows_file_path(std::filesystem::absolute(path));
}

inline std::filesystem::path canonical_directory(const std::filesystem::path& absolute,
                                                 std::error_code& error) {
    const auto path = windows_file_path(absolute);
    const auto directory = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (directory == INVALID_HANDLE_VALUE) {
        error = {static_cast<int>(GetLastError()), std::system_category()};
        return {};
    }
    const std::unique_ptr<void, decltype(&CloseHandle)> handle(directory, &CloseHandle);
    std::wstring resolved(32768, L'\0');
    const auto length = GetFinalPathNameByHandleW(
        handle.get(), resolved.data(), static_cast<DWORD>(resolved.size()), VOLUME_NAME_DOS);
    if (length == 0) {
        error = {static_cast<int>(GetLastError()), std::system_category()};
        return {};
    }
    if (length >= resolved.size()) {
        error = std::make_error_code(std::errc::filename_too_long);
        return {};
    }
    resolved.resize(length);
    error.clear();
    return resolved;
}

} // namespace q3a::bundle::detail
