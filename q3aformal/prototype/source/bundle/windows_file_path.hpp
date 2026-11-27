#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <system_error>

#ifdef _WIN32
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
#else
#include <cerrno>
#include <fcntl.h>
#ifndef __APPLE__
#include <linux/fs.h>
#endif
#include <unistd.h>

namespace q3a::bundle::detail {

inline std::filesystem::path windows_file_path(const std::filesystem::path& path) {
    return path;
}

inline std::filesystem::path absolute_windows_file_path(const std::filesystem::path& path) {
    return std::filesystem::absolute(path).lexically_normal();
}

inline std::filesystem::path canonical_directory(const std::filesystem::path& path,
                                                 std::error_code& error) {
    const auto result = std::filesystem::canonical(path, error);
    if (!error && !std::filesystem::is_directory(result, error) && !error) {
        error = std::make_error_code(std::errc::not_a_directory);
    }
    return error ? std::filesystem::path{} : result;
}

} // namespace q3a::bundle::detail
#endif

namespace q3a {

inline bool same_native_path(const std::filesystem::path& left,
                             const std::filesystem::path& right) {
#ifdef _WIN32
    return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
#else
    return left == right;
#endif
}

inline std::uint64_t process_id() noexcept {
#ifdef _WIN32
    return GetCurrentProcessId();
#else
    return static_cast<std::uint64_t>(getpid());
#endif
}

inline std::error_code publish_no_replace(const std::filesystem::path& stage,
                                          const std::filesystem::path& target) noexcept {
#ifdef _WIN32
    if (!MoveFileW(stage.c_str(), target.c_str())) {
        return {static_cast<int>(GetLastError()), std::system_category()};
    }
#elif defined(__APPLE__)
    if (renamex_np(stage.c_str(), target.c_str(), RENAME_EXCL) != 0) {
        return {errno, std::generic_category()};
    }
#else
    if (renameat2(AT_FDCWD, stage.c_str(), AT_FDCWD, target.c_str(), RENAME_NOREPLACE) != 0) {
        return {errno, std::generic_category()};
    }
#endif
    return {};
}

} // namespace q3a
