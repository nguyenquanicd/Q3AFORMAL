#pragma once

#include <array>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <istream>
#ifdef _WIN32
#include <io.h>
#include <share.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <memory>
#include <stdexcept>
#include <streambuf>

namespace q3a {

// Hash and parse through the same Windows handle. Sharing permits readers
// while denying writers until verification finishes.
class WriteLockedInput final : private std::streambuf {
public:
    explicit WriteLockedInput(const std::filesystem::path& path)
        #ifdef _WIN32
        : file_(_wfsopen(path.c_str(), L"rb", _SH_DENYWR)),
#else
        : file_(open_shared_input(path)),
#endif
          input_(this) {
        if (!file_) {
            throw std::runtime_error("cannot open input for reading with writes denied: " +
                                     path.u8string());
        }
    }

    std::istream& stream() noexcept { return input_; }
    std::intptr_t native_handle() const noexcept {
#ifdef _WIN32
        return _get_osfhandle(_fileno(file_.get()));
#else
        return fileno(file_.get());
#endif
    }

    void rewind() {
        if (std::fseek(file_.get(), 0, SEEK_SET) != 0) {
            throw std::runtime_error("cannot rewind input");
        }
        setg(nullptr, nullptr, nullptr);
        input_.clear();
    }

private:
#ifndef _WIN32
    static std::FILE* open_shared_input(const std::filesystem::path& path) {
        const auto fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) return nullptr;
        struct stat info {};
        if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
            flock(fd, LOCK_SH | LOCK_NB) == 0) {
            if (auto* file = fdopen(fd, "rb")) return file;
        }
        close(fd);
        return nullptr;
    }
#endif

    auto file_offset() const {
#ifdef _WIN32
        return _ftelli64(file_.get());
#else
        return ftello(file_.get());
#endif
    }

    int seek_file(off_type offset, int origin) {
#ifdef _WIN32
        return _fseeki64(file_.get(), offset, origin);
#else
        return fseeko(file_.get(), offset, origin);
#endif
    }

    pos_type seekoff(off_type offset, std::ios_base::seekdir direction,
                     std::ios_base::openmode mode) override {
        if (!(mode & std::ios_base::in)) return pos_type(off_type(-1));
        if (direction == std::ios_base::cur && offset == 0) {
            const auto physical = file_offset();
            if (physical < 0) return pos_type(off_type(-1));
            return pos_type(physical - unread_bytes());
        }
        if (direction != std::ios_base::beg && direction != std::ios_base::end) {
            return pos_type(off_type(-1));
        }
        const int origin = direction == std::ios_base::beg ? SEEK_SET : SEEK_END;
        if (seek_file(offset, origin) != 0) return pos_type(off_type(-1));
        setg(nullptr, nullptr, nullptr);
        return pos_type(file_offset());
    }

    pos_type seekpos(pos_type position, std::ios_base::openmode mode) override {
        return seekoff(static_cast<off_type>(position), std::ios_base::beg, mode);
    }

    std::ptrdiff_t unread_bytes() const {
        return gptr() == nullptr ? 0 : egptr() - gptr();
    }

    int_type underflow() override {
        if (gptr() != egptr()) return traits_type::to_int_type(*gptr());
        const auto count = std::fread(buffer_.data(), 1, buffer_.size(), file_.get());
        if (std::ferror(file_.get())) {
            throw std::runtime_error("failed while reading locked input");
        }
        if (count == 0) return traits_type::eof();
        setg(buffer_.data(), buffer_.data(), buffer_.data() + count);
        return traits_type::to_int_type(*gptr());
    }

    struct CloseFile {
        void operator()(std::FILE* file) const noexcept { std::fclose(file); }
    };
    std::unique_ptr<std::FILE, CloseFile> file_;
    std::array<char, 64 * 1024> buffer_;
    std::istream input_;
};

} // namespace q3a
